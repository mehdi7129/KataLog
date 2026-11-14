#!/usr/bin/env python3
"""Read-only PX4 ULog collection over MAVLink serial, JSONL output.

LOG_* identifiers are scoped to the immutable hardware UID, never to a GCS UUID
or a serial path. A restarted download revalidates the inventory and starts at
zero. No erase, parameter writes, reboot or flight-control commands are sent.
"""
from __future__ import annotations

import argparse
from collections import deque
import contextlib
import hashlib
import json
import os
from pathlib import Path
import re
import signal
import stat
import sys
import time
import uuid

import serial
from serial.tools import list_ports
from pymavlink.dialects.v20 import common as mavlink

from gcs_collect import (CollectionError, Cancelled, MAGIC, cache_record, hash_file,
                         recover_pending_commit, same_file_identity, sync_directory,
                         validate_destination, require_download_space, emit)

HEARTBEAT_TIMEOUT = 5.0
RESPONSE_TIMEOUT = 2.0
INVENTORY_TIMEOUT = 5.0
MAX_ATTEMPTS = 4
BLOCK_SIZE = 90
WINDOW_BLOCKS = 512
MAX_LOG_BYTES = 0xffffffff


def hardware_identity(message):
    extended = bytes(message.uid2)
    if any(extended):
        return 'uid2:' + extended.hex().upper()
    if message.uid:
        return 'uid:' + format(message.uid, '016X')
    raise CollectionError('Le contrôleur ne fournit pas d’identité matérielle stable ; collecte USB indisponible.')


def valid_identity(value):
    if not re.fullmatch(r'(?:uid2:[0-9A-F]{36}|uid:[0-9A-F]{16})', value or '') or not any(c != '0' for c in value.split(':')[1]):
        raise CollectionError('Identité matérielle USB invalide.')
    return value


def ports():
    # Enumeration only: listing ports never opens them or changes a vehicle.
    found = [{'path': p.device, 'label': f'{p.description or "USB serial"} · {p.device}'}
            for p in sorted(list_ports.comports(), key=lambda p: p.device)
            if p.device.startswith('/dev/cu.') and (p.vid is not None or 'usb' in p.device.lower())]
    bench = bench_port()
    if bench:
        found.append({'path': bench, 'label': 'Banc serial simulé (PTY)'})
    return found


def bench_port():
    """Explicit local bench only; normal discovery never includes pseudo-TTYs.

    The packaged helper takes the exact same serial/MAVLink path for a bench.
    No network endpoint, regular file, symlink or identity check is substituted.
    """
    value = os.environ.get('KATALOG_USB_BENCH_PORT', '')
    if not re.fullmatch(r'/dev/ttys[0-9]+', value) or os.path.realpath(value) != value:
        return None
    try:
        return value if stat.S_ISCHR(os.stat(value).st_mode) else None
    except OSError:
        return None


def open_serial(device, baud):
    if not re.fullmatch(r'/dev/cu\.[A-Za-z0-9_.-]+', device or '') and (not device or device != bench_port()):
        raise CollectionError('Choisir un port USB serial /dev/cu.* valide.')
    if baud not in (57600, 115200, 230400, 460800, 921600):
        raise CollectionError('Débit serial non pris en charge.')
    try:
        port = serial.Serial(device, baudrate=baud, timeout=0.1, write_timeout=1,
                             exclusive=True, rtscts=False, dsrdtr=False)
        try:
            # flock (pyserial exclusive) covers cooperative clients; TIOCEXCL
            # additionally prevents another ordinary macOS process opening it.
            import fcntl
            import termios
            fcntl.ioctl(port.fileno(), termios.TIOCEXCL)
        except BaseException:
            port.close()
            raise
        return port
    except (OSError, serial.SerialException) as error:
        raise CollectionError('Port USB indisponible. Fermer QGroundControl ou toute app utilisant ce port, puis reconnecter le câble.', retryable=True) from error


class USBSession:
    def __init__(self, port):
        self.port = port
        self.mav = mavlink.MAVLink(port, srcSystem=255, srcComponent=190)
        self.mav.robust_parsing = True
        self.messages = deque()
        self.system = self.component = None
        self.last_heartbeat = None
        self.last_sent_heartbeat = -float('inf')
        self.identity = None
        self.armed = None
        self.log_requested = False
        # A v1 heartbeat/request reaches old PX4 builds too. Negotiate transmit
        # framing from the first autopilot heartbeat; the parser accepts both.
        self.force_mavlink1 = True

    def __enter__(self):
        try:
            self.handshake()
            return self
        except BaseException:
            self.close()
            raise

    def __exit__(self, *args):
        self.close()

    def close(self):
        try:
            if self.log_requested and self.system is not None:
                with contextlib.suppress(OSError, serial.SerialException):
                    self.mav.log_request_end_send(self.system, self.component, force_mavlink1=self.force_mavlink1)
                    # Drain the transmitted END before the serial descriptor
                    # closes; otherwise the final frame can be discarded.
                    self.port.flush()
        finally:
            self.port.close()

    def receive(self, deadline, *, require_fresh=True):
        while time.monotonic() < deadline:
            now = time.monotonic()
            if now - self.last_sent_heartbeat >= 1:
                self.mav.heartbeat_send(mavlink.MAV_TYPE_GCS, mavlink.MAV_AUTOPILOT_INVALID, 0, 0, 0, force_mavlink1=self.force_mavlink1)
                self.last_sent_heartbeat = now
            if require_fresh and self.system is not None and (self.last_heartbeat is None or now - self.last_heartbeat > HEARTBEAT_TIMEOUT):
                raise CollectionError('Le heartbeat USB du contrôleur a disparu ; reconnecter avant de reprendre.', retryable=True)
            if not self.messages:
                data = self.port.read(min(max(self.port.in_waiting, 1), 4096))
                if not data:
                    continue
                self.messages.extend(self.mav.parse_buffer(data) or [])
            while self.messages:
                message = self.messages.popleft()
                if message.get_type() == 'BAD_DATA':
                    continue
                if self.system is not None and (message.get_srcSystem(), message.get_srcComponent()) != (self.system, self.component):
                    continue
                if message.get_type() == 'HEARTBEAT':
                    if message.autopilot == mavlink.MAV_AUTOPILOT_INVALID or message.type == mavlink.MAV_TYPE_GCS:
                        continue
                    if self.system is None:
                        self.system, self.component = message.get_srcSystem(), message.get_srcComponent()
                        self.force_mavlink1 = message.get_msgbuf()[0] == 0xfe
                        if not self.system or not self.component:
                            raise CollectionError('Identifiants MAVLink USB invalides.')
                    self.armed = bool(message.base_mode & mavlink.MAV_MODE_FLAG_SAFETY_ARMED)
                    self.last_heartbeat = time.monotonic()
                    if self.armed:
                        raise CollectionError('Le contrôleur est armé. Désarmer avant de collecter les logs USB.')
                    if message.autopilot != mavlink.MAV_AUTOPILOT_PX4:
                        raise CollectionError('La collecte USB de KataLog prend en charge les ULog PX4 uniquement.')
                return message
        return None

    def assert_disarmed(self):
        if self.armed is not False or self.last_heartbeat is None or time.monotonic() - self.last_heartbeat > HEARTBEAT_TIMEOUT:
            raise CollectionError('État désarmé récent indisponible ; reconnecter le contrôleur.', retryable=True)

    def handshake(self):
        deadline = time.monotonic() + HEARTBEAT_TIMEOUT
        while self.system is None:
            if self.receive(deadline, require_fresh=False) is None:
                raise CollectionError('Aucun heartbeat PX4 sur ce port USB. Vérifier le câble et le débit serial.', retryable=True)
        version = self.request_version()
        if version.capabilities & mavlink.MAV_PROTOCOL_CAPABILITY_MAVLINK2:
            # PX4 AUTO initially sends v1, then upgrades after receiving v2.
            # v1 omits uid2: freezing the first response would give the same
            # board different queue identities before/after QGroundControl.
            self.force_mavlink1 = False
            if version.get_msgbuf()[0] != 0xfd:
                upgraded = self.request_version(require_v2=True)
                if version.uid and upgraded.uid and version.uid != upgraded.uid:
                    raise CollectionError('L’identité USB a changé pendant la connexion ; reconnecter le contrôleur.')
                version = upgraded
        self.identity = hardware_identity(version)

    def request_version(self, *, require_v2=False):
        for attempt in range(MAX_ATTEMPTS):
            self.assert_disarmed()
            command = mavlink.MAV_CMD_REQUEST_MESSAGE if attempt < 2 else mavlink.MAV_CMD_REQUEST_AUTOPILOT_CAPABILITIES
            param = 148 if attempt < 2 else 1
            self.mav.command_long_send(self.system, self.component, command, 0, param, 0, 0, 0, 0, 0, 0, force_mavlink1=self.force_mavlink1)
            deadline = time.monotonic() + RESPONSE_TIMEOUT
            while (message := self.receive(deadline)) is not None:
                if message.get_type() == 'AUTOPILOT_VERSION' and (not require_v2 or message.get_msgbuf()[0] == 0xfd):
                    return message
        if require_v2:
            raise CollectionError('Le contrôleur annonce MAVLink 2 mais son identité complète ne répond pas en MAVLink 2. Vérifier la configuration du lien USB avant de reprendre.', retryable=True)
        raise CollectionError('Identité matérielle du contrôleur non reçue (AUTOPILOT_VERSION).', retryable=True)

    def device_info(self):
        return {'identity': self.identity, 'systemID': self.system, 'componentID': self.component,
                'label': 'PX4 USB · ' + self.identity}

    def revalidate_identity(self):
        version = self.request_version(require_v2=not self.force_mavlink1)
        if hardware_identity(version) != self.identity:
            raise CollectionError('L’identité USB a changé pendant la collecte ; reconnecter le contrôleur attendu.')

    def inventory(self):
        entries = {}
        shape = None
        self.assert_disarmed()
        self.log_requested = True
        for _ in range(MAX_ATTEMPTS):
            self.mav.log_request_list_send(self.system, self.component, 0, 65535, force_mavlink1=self.force_mavlink1)
            deadline = time.monotonic() + INVENTORY_TIMEOUT
            while (message := self.receive(deadline)) is not None:
                if message.get_type() != 'LOG_ENTRY':
                    continue
                if message.num_logs == 0:
                    if entries:
                        raise CollectionError('L’inventaire USB a changé ; actualiser les logs.')
                    return []
                current_shape = (message.num_logs, message.last_log_num)
                if shape is not None and current_shape != shape:
                    raise CollectionError('L’inventaire USB a changé pendant sa lecture ; réessayer.')
                shape = current_shape
                item = {'id': message.id, 'timeUTC': message.time_utc, 'size': message.size}
                if item['id'] in entries and entries[item['id']] != item:
                    raise CollectionError('Un log USB a changé pendant l’inventaire ; réessayer.')
                entries[item['id']] = item
                if len(entries) == message.num_logs:
                    return sorted(entries.values(), key=lambda item: item['id'])
                if len(entries) > message.num_logs:
                    raise CollectionError('Inventaire USB incohérent.')
        raise CollectionError('Inventaire USB incomplet après plusieurs tentatives.', retryable=True)

    def transfer(self, entry, stream, report=emit):
        size, log_id = entry['size'], entry['id']
        total_received = 0
        last_report = 0.0
        global_deadline = time.monotonic() + min(7200, max(60, size / 1024))
        for start in range(0, size, BLOCK_SIZE * WINDOW_BLOCKS):
            end = min(size, start + BLOCK_SIZE * WINDOW_BLOCKS)
            missing = set(range(start, end, BLOCK_SIZE))
            attempts = 0
            while missing:
                self.assert_disarmed()
                if attempts >= MAX_ATTEMPTS or time.monotonic() >= global_deadline:
                    raise CollectionError('Téléchargement USB incomplet ; reprise possible depuis le début.', retryable=True)
                first = min(missing)
                last = first
                while last + BLOCK_SIZE in missing:
                    last += BLOCK_SIZE
                request_end = min(end, last + BLOCK_SIZE)
                self.mav.log_request_data_send(self.system, self.component, log_id, first, request_end - first, force_mavlink1=self.force_mavlink1)
                attempts += 1
                deadline = min(global_deadline, time.monotonic() + RESPONSE_TIMEOUT)
                while (message := self.receive(deadline)) is not None:
                    if message.get_type() != 'LOG_DATA' or message.id != log_id:
                        continue
                    offset, count = message.ofs, message.count
                    if count == 0:
                        if offset < size:
                            raise CollectionError('Le log USB est plus court que l’inventaire ; actualiser la liste.')
                        continue
                    if offset not in missing:
                        continue  # Duplicate, stale window, misalignment or out-of-range.
                    expected = min(BLOCK_SIZE, size - offset)
                    if count != expected or count > len(message.data):
                        raise CollectionError('Bloc USB incomplet ou invalide ; le fichier n’a pas été importé.')
                    stream.seek(offset)
                    stream.write(bytes(message.data[:count]))
                    missing.remove(offset)
                    total_received += count
                    # Only new bytes reset the stall timeout; duplicates cannot
                    # make a broken transfer live forever. Global deadline stays.
                    deadline = min(global_deadline, time.monotonic() + RESPONSE_TIMEOUT)
                    attempts = 0
                    now = time.monotonic()
                    if now - last_report >= 0.25 or total_received == size:
                        report('progress', bytes=total_received, total=size)
                        last_report = now
                    if not missing or not any(first <= offset < request_end for offset in missing):
                        break
        if total_received != size:
            raise CollectionError('Des octets manquent dans le téléchargement USB.')
        stream.flush()
        os.fsync(stream.fileno())


def target_for(destination, identity, entry):
    root = validate_destination(destination)
    directory = root / ('USB-' + identity.replace(':', '-'))
    if directory.is_symlink():
        raise CollectionError('Un lien symbolique bloque la destination USB.')
    directory.mkdir(exist_ok=True)
    target = directory / f"log-{entry['id']}-{entry['timeUTC']}-{entry['size']}.ulg"
    if target.is_symlink():
        raise CollectionError('Le fichier USB cible ne peut pas être un lien symbolique.')
    return target


def download(session, identity, entry, destination):
    valid_identity(identity)
    if session.identity != identity:
        raise CollectionError('Un autre contrôleur USB est connecté. Reconnecter celui de ce téléchargement.')
    if not (0 <= entry['id'] <= 65535 and 0 <= entry['timeUTC'] <= 0xffffffff and 16 <= entry['size'] <= MAX_LOG_BYTES):
        raise CollectionError('Métadonnées du log USB invalides.')
    current = next((item for item in session.inventory() if item['id'] == entry['id']), None)
    if current != entry:
        raise CollectionError('Le log USB a disparu ou changé depuis la sélection ; actualiser l’inventaire.')
    session.revalidate_identity()
    target = target_for(destination, identity, entry)
    source = {'uuid': identity, 'path': f"mavlink-log://{entry['id']}/{entry['timeUTC']}",
              'size': entry['size'], 'transport': 'usb-mavlink-log', **entry}
    recover_pending_commit(target, source)
    cached = cache_record(target, source)
    if cached:
        emit('downloaded', localPath=str(target), sha256=cached['sha256'], bytes=entry['size'], cached=True)
        return
    if target.exists():
        raise CollectionError('Un fichier USB non vérifié existe déjà à destination ; il est conservé.')
    manifest = target.with_name(target.name + '.katalog.json')
    pending = target.with_name(target.name + '.katalog.pending.json')
    if manifest.exists() or manifest.is_symlink():
        raise CollectionError('Un manifeste USB existe déjà sans fichier vérifié ; il est conservé.')
    require_download_space(target, entry['size'])
    part = target.with_name(target.name + '.' + uuid.uuid4().hex + '.part')
    pending_created = False
    transaction = {}
    try:
        with part.open('xb') as stream:
            session.transfer(entry, stream)
        current = next((item for item in session.inventory() if item['id'] == entry['id']), None)
        if current != entry:
            raise CollectionError('Le log USB a changé pendant le transfert ; actualiser l’inventaire avant de recommencer.')
        session.revalidate_identity()
        digest = hash_file(part)  # Includes strict ULog magic check; BIN never imports.
        stat = part.stat()
        transaction = {'part': part.name, 'device': stat.st_dev, 'inode': stat.st_ino}
        record = {'source': source, 'sha256': digest, 'transaction': transaction,
                  'collectedAt': time.time(), 'device': session.device_info()}
        with pending.open('x') as stream:
            pending_created = True
            json.dump(record, stream, ensure_ascii=False)
            stream.flush()
            os.fsync(stream.fileno())
        sync_directory(target.parent)
        os.link(part, target)  # Refuse overwrite even if a concurrent writer won.
        sync_directory(target.parent)
        part.unlink()
        os.link(pending, manifest)  # Exclusive manifest publication too.
        pending.unlink()
        sync_directory(target.parent)
        emit('downloaded', localPath=str(target), sha256=digest, bytes=entry['size'], cached=False)
    finally:
        part.unlink(missing_ok=True)
        if pending_created and not same_file_identity(target, transaction):
            pending.unlink(missing_ok=True)


def cancelled(signum, frame):
    raise Cancelled('Collecte USB interrompue ; reprise possible depuis le début.')


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('command', choices=('ports', 'inventory', 'download'))
    parser.add_argument('--device')
    parser.add_argument('--baud', type=int, default=115200)
    parser.add_argument('--identity')
    parser.add_argument('--log-id', type=int)
    parser.add_argument('--time-utc', type=int)
    parser.add_argument('--size', type=int)
    parser.add_argument('--destination')
    args = parser.parse_args(argv)
    old_handlers = {sig: signal.signal(sig, cancelled) for sig in (signal.SIGINT, signal.SIGTERM)}
    try:
        if args.command == 'ports':
            emit('ports', ports=ports())
        else:
            if args.command == 'download':
                valid_identity(args.identity)
                if any(value is None for value in (args.log_id, args.time_utc, args.size, args.destination)):
                    raise CollectionError('Téléchargement USB : sélection de log ou destination manquante.')
                validate_destination(args.destination)
            with USBSession(open_serial(args.device, args.baud)) as session:
                if args.command == 'inventory':
                    logs = session.inventory()
                    session.revalidate_identity()
                    emit('usb_inventory', device=session.device_info(), logs=logs)
                else:
                    download(session, args.identity, {'id': args.log_id, 'timeUTC': args.time_utc, 'size': args.size}, args.destination)
        return 0
    except Cancelled as error:
        emit('error', message=str(error), retryable=False, cancelled=True)
        return 130
    except (CollectionError, OSError, serial.SerialException, ValueError) as error:
        emit('error', message=str(error), retryable=getattr(error, 'retryable', isinstance(error, serial.SerialException)))
        return 1
    finally:
        for sig, handler in old_handlers.items():
            signal.signal(sig, handler)


if __name__ == '__main__':
    sys.exit(main())
