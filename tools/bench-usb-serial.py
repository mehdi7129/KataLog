#!/usr/bin/env python3
"""Synthetic PX4 vehicle over an OS pseudo-terminal; never opens physical hardware.

Run with the project's .venv Python. connection.json describes the slave port and
two valid synthetic ULogs. Edit control.json atomically to change identityIndex,
connected, reconnectToken, pauseData, pauseHeartbeat, armed, noiseHz, dropEvery,
rateKiB or stop. A new reconnectToken closes/recreates the PTY; connected=false
only silences the existing port. Metrics and every request are written to output.
"""
from __future__ import annotations

import argparse
from collections import Counter, deque
import errno
import hashlib
import json
import os
from pathlib import Path
import pty
import select
import signal
import sys
import time
import tty

from pymavlink.dialects.v20 import common as mav
from pymavlink.dialects.v10 import common as mav1

ROOT = Path(__file__).resolve().parents[1]
sys.path.insert(0, str(ROOT / 'Tests'))
from fixture_ulog import synthetic_ulog


def atomic_json(path, value):
    temporary = path.with_suffix(path.suffix + '.tmp')
    temporary.write_text(json.dumps(value, indent=2, sort_keys=True) + '\n')
    temporary.replace(path)


class PTYVehicle:
    def __init__(self, output, *, version=2, log_mib=1.25, rate_kib=256,
                 drop_every=0, noise_hz=0, heartbeat_hz=2):
        self.output = Path(output).resolve()
        self.output.mkdir(parents=True, exist_ok=True)
        self.logs_directory = self.output / 'logs'
        self.logs_directory.mkdir(exist_ok=True)
        self.version = version
        self.heartbeat_interval = 1 / heartbeat_hz
        self.control = dict(identityIndex=1, connected=True, reconnectToken=0,
                            pauseData=False, pauseHeartbeat=False, armed=False,
                            noiseHz=noise_hz, dropEvery=drop_every, rateKiB=rate_kib, stop=False)
        self.control_path = self.output / 'control.json'
        atomic_json(self.control_path, self.control)
        self.payloads = {}
        self.logs = []
        minimum = max(16, int(log_mib * 1024 * 1024))
        for index, log_id in enumerate((7, 9)):
            samples = max(2, minimum // 100 + index * 23)
            payload = synthetic_ulog(f'USB synthetic log {log_id}', samples=samples)
            while len(payload) < minimum:
                samples += max(100, (minimum - len(payload)) // 90)
                payload = synthetic_ulog(f'USB synthetic log {log_id}', samples=samples)
            path = self.logs_directory / f'log-{log_id}.ulg'
            path.write_bytes(payload)
            self.payloads[log_id] = payload
            self.logs.append(dict(id=log_id, timeUTC=1700000000 + index * 600,
                                  size=len(payload), path=str(path), sha256=hashlib.sha256(payload).hexdigest()))
        self.encoder = mav.MAVLink(None, srcSystem=42, srcComponent=1)
        self.noise_encoder = mav.MAVLink(None, srcSystem=43, srcComponent=1)
        self.parser = mav.MAVLink(None)
        self.parser.robust_parsing = True
        self.urgent = deque()
        self.data_frames = deque()
        self.pending = b''
        self.dropped = set()
        self.metrics = Counter()
        self.received = Counter()
        self.started = time.monotonic()
        self.master = None
        self.port = None
        self.running = True
        self.create_pty()

    @property
    def uid(self):
        return 0x0102030405060708 + int(self.control['identityIndex'])

    @property
    def uid2(self):
        return bytes([int(self.control['identityIndex'])]) + bytes(range(2, 19))

    @property
    def identity(self):
        return 'uid2:' + self.uid2.hex().upper() if self.version == 2 else f'uid:{self.uid:016X}'

    def publish_connection(self):
        atomic_json(self.output / 'connection.json', dict(
            port=self.port, identity=self.identity, mavlinkVersion=self.version,
            systemID=42, componentID=1, logs=self.logs, pid=os.getpid(),
            controlPath=str(self.control_path), connected=self.control['connected'],
            generation=self.control['reconnectToken'], simulated=True))

    def create_pty(self):
        if self.master is not None:
            os.close(self.master)
        master, slave = pty.openpty()
        tty.setraw(slave)
        self.port = os.ttyname(slave)
        os.set_blocking(master, False)
        # No keeper slave fd: keeping one open retains TIOCEXCL after the
        # collector exits on macOS, preventing the next inventory/download.
        os.close(slave)
        self.master = master
        self.urgent.clear(); self.data_frames.clear(); self.pending = b''
        self.parser = mav.MAVLink(None); self.parser.robust_parsing = True
        self.metrics['ptyGenerations'] += 1
        self.publish_connection()

    def encode(self, message, *, noise=False):
        encoder = self.noise_encoder if noise else self.encoder
        if self.version == 1:
            # v20.pack(force_mavlink1=True) can retain extension fields. Use
            # the v1 schema so AUTOPILOT_VERSION really omits uid2 on the wire.
            message_type = mav1.mavlink_map[message.get_msgId()]
            message = message_type(*(getattr(message, name) for name in message_type.fieldnames))
        frame = message.pack(encoder, force_mavlink1=self.version == 1)
        encoder.seq = (encoder.seq + 1) % 256
        return frame

    def heartbeat(self):
        mode = mav.MAV_MODE_FLAG_SAFETY_ARMED if self.control['armed'] else 0
        self.urgent.append(self.encode(mav.MAVLink_heartbeat_message(
            mav.MAV_TYPE_SURFACE_BOAT, mav.MAV_AUTOPILOT_PX4, mode, 0, 3, 3)))
        self.metrics['heartbeatsScheduled'] += 1

    def noise(self):
        self.urgent.append(self.encode(mav.MAVLink_log_data_message(7, 0, 90, b'N' * 90), noise=True))
        self.metrics['noiseFramesScheduled'] += 1

    def record_request(self, message):
        kind = message.get_type()
        self.received[kind] += 1
        if kind in ('HEARTBEAT', 'BAD_DATA'):
            return
        row = dict(time=time.time(), elapsed=time.monotonic()-self.started,
                   identity=self.identity, sourceSystem=message.get_srcSystem(),
                   sourceComponent=message.get_srcComponent(), **message.to_dict())
        with (self.output / 'requests.jsonl').open('a') as stream:
            stream.write(json.dumps(row) + '\n')

    def handle(self, message):
        self.record_request(message)
        if not self.control['connected']:
            return
        if getattr(message, 'target_system', 42) not in (0, 42) or getattr(message, 'target_component', 1) not in (0, 1):
            self.metrics['wrongTargetRequests'] += 1
            return
        kind = message.get_type()
        if kind == 'COMMAND_LONG' and message.command in (mav.MAV_CMD_REQUEST_MESSAGE, mav.MAV_CMD_REQUEST_AUTOPILOT_CAPABILITIES):
            if message.command == mav.MAV_CMD_REQUEST_MESSAGE and int(message.param1) != 148:
                return
            self.urgent.append(self.encode(mav.MAVLink_autopilot_version_message(
                0, 0x010E0000, 0, 0, 0, [0]*8, [0]*8, [0]*8, 0, 0,
                self.uid, list(self.uid2) if self.version == 2 else [0]*18)))
        elif kind == 'LOG_REQUEST_LIST':
            for entry in self.logs:
                if message.start <= entry['id'] <= message.end:
                    self.urgent.append(self.encode(mav.MAVLink_log_entry_message(
                        entry['id'], len(self.logs), self.logs[-1]['id'], entry['timeUTC'], entry['size'])))
        elif kind == 'LOG_REQUEST_DATA':
            payload = self.payloads.get(message.id)
            if payload is None:
                return
            self.metrics['dataRequests'] += 1
            # Bound a response to log bytes and requested range, as PX4 does.
            for offset in range(message.ofs, min(len(payload), message.ofs + message.count), 90):
                key = (self.identity, message.id, offset)
                every = int(self.control['dropEvery'])
                if every > 0 and offset // 90 % every == 0 and key not in self.dropped:
                    self.dropped.add(key); self.metrics['blocksDroppedOnce'] += 1
                    continue
                chunk = payload[offset:offset+90]
                self.data_frames.append(self.encode(mav.MAVLink_log_data_message(
                    message.id, offset, len(chunk), chunk.ljust(90, b'\0'))))
                self.metrics['logPayloadBytesScheduled'] += len(chunk)
            if message.ofs >= len(payload):
                self.data_frames.append(self.encode(mav.MAVLink_log_data_message(message.id, message.ofs, 0, bytes(90))))
        elif kind == 'LOG_REQUEST_END':
            self.metrics['endRequests'] += 1
            self.data_frames.clear()

    def read_control(self):
        try:
            incoming = json.loads(self.control_path.read_text())
            update = {key: value for key, value in incoming.items() if key in self.control}
            if not 1 <= int(update.get('identityIndex', self.control['identityIndex'])) <= 255:
                raise ValueError('identityIndex must be in 1...255')
            for key in ('noiseHz', 'rateKiB', 'dropEvery'):
                if key in update and not 0 <= float(update[key]) <= 1_000_000:
                    raise ValueError(key + ' must be nonnegative and bounded')
        except (OSError, ValueError, TypeError, json.JSONDecodeError):
            self.metrics['controlReadErrors'] += 1
            return
        previous = self.control.copy()
        self.control.update(update)
        if previous['reconnectToken'] != self.control['reconnectToken']:
            self.create_pty()
        elif previous['identityIndex'] != self.control['identityIndex'] or previous['connected'] != self.control['connected']:
            self.urgent.clear(); self.data_frames.clear(); self.pending = b''
            self.publish_connection()
        if self.control['stop']:
            self.running = False

    def publish_metrics(self):
        elapsed = time.monotonic() - self.started
        atomic_json(self.output / 'metrics.json', dict(
            **self.metrics, receivedMessages=dict(self.received), identity=self.identity,
            port=self.port, elapsedSeconds=elapsed, pendingDataFrames=len(self.data_frames),
            simulated=True, running=self.running, control=self.control,
            wireKiBPerSecond=self.metrics['wireBytesSent']/max(elapsed, .001)/1024))

    def run(self):
        next_heartbeat = next_noise = next_control = next_metrics = time.monotonic()
        last = time.monotonic(); tokens = 0.0
        try:
            while self.running:
                now = time.monotonic()
                rate = float(self.control['rateKiB']) * 1024
                tokens = min(max(65536, rate), tokens + (now-last) * rate)
                last = now
                if now >= next_control:
                    self.read_control(); next_control = now + .1
                if now >= next_heartbeat:
                    if self.control['connected'] and not self.control['pauseHeartbeat']:
                        self.heartbeat()
                    next_heartbeat = now + self.heartbeat_interval
                if now >= next_noise:
                    if self.control['connected'] and float(self.control['noiseHz']) > 0:
                        self.noise()
                    next_noise = now + 1/max(.01, float(self.control['noiseHz']))
                if now >= next_metrics:
                    self.publish_metrics(); next_metrics = now + .5
                readable, _, _ = select.select([self.master], [], [], .01)
                if readable:
                    try:
                        data = os.read(self.master, 65536)
                        for message in self.parser.parse_buffer(data) or []:
                            self.handle(message)
                    except OSError as error:
                        if error.errno not in (errno.EIO, errno.EAGAIN):
                            raise
                        # EIO while the slave is closed is expected between helper invocations.
                        time.sleep(.01)
                if not self.control['connected']:
                    continue
                # Serial writes remain bounded/nonblocking, leaving heartbeat
                # scheduling independent of a slow consumer or large data reply.
                for _ in range(64):
                    if not self.pending:
                        if self.urgent:
                            self.pending = self.urgent.popleft()
                        elif not self.control['pauseData'] and self.data_frames and tokens >= len(self.data_frames[0]):
                            self.pending = self.data_frames.popleft(); tokens -= len(self.pending)
                        else:
                            break
                    try:
                        written = os.write(self.master, self.pending)
                        self.pending = self.pending[written:]
                        self.metrics['wireBytesSent'] += written
                    except BlockingIOError:
                        break
                    except OSError as error:
                        if error.errno != errno.EIO:
                            raise
                        self.pending = b''; self.urgent.clear(); self.data_frames.clear()
                        break
        finally:
            self.running = False
            self.publish_metrics()
            os.close(self.master); self.master = None


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--mavlink-version', type=int, choices=(1, 2), default=2)
    parser.add_argument('--log-mib', type=float, default=1.25)
    parser.add_argument('--rate-kib', type=float, default=256)
    parser.add_argument('--drop-every', type=int, default=0)
    parser.add_argument('--noise-hz', type=float, default=0)
    parser.add_argument('--heartbeat-hz', type=float, default=2)
    args = parser.parse_args()
    if not (0 < args.log_mib <= 32 and 0 < args.heartbeat_hz <= 10 and 0 <= args.rate_kib <= 100000):
        parser.error('log-mib: (0,32], heartbeat-hz: (0,10], rate-kib: [0,100000]')
    vehicle = PTYVehicle(args.output, version=args.mavlink_version, log_mib=args.log_mib,
                         rate_kib=args.rate_kib, drop_every=args.drop_every,
                         noise_hz=args.noise_hz, heartbeat_hz=args.heartbeat_hz)
    def stop(_signum, _frame):
        vehicle.running = False
    signal.signal(signal.SIGTERM, stop); signal.signal(signal.SIGINT, stop)
    print(json.dumps(dict(event='ready', connection=str(vehicle.output/'connection.json'), port=vehicle.port, identity=vehicle.identity)), flush=True)
    vehicle.run()


if __name__ == '__main__':
    main()
