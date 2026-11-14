"""Mount only a caller-owned temporary read-only DMG, then detach it safely."""
from contextlib import contextmanager
import json
from pathlib import Path
import plistlib
import re
import stat
import subprocess
import sys
import tempfile
import time


class TemporaryMountError(RuntimeError):
    pass


def _detached_state(mount, image, device=None):
    """Require independent disk-image and filesystem evidence after a failed detach."""
    state = dict(mount=str(mount), image=str(image), ownedDevice=device, confirmedDetached=False)
    try:
        result = subprocess.run(['/usr/bin/hdiutil', 'info', '-plist'], check=True,
                                capture_output=True, timeout=10)
        info = plistlib.loads(result.stdout)
        if not isinstance(info, dict) or not isinstance(info.get('images'), list):
            raise ValueError('Missing disk-image inventory')
        image_path, mount_path = image.resolve(), mount.resolve()
        image_present, mount_present, owned_device_for_image = False, False, False
        for entry in info['images']:
            if (not isinstance(entry, dict) or not isinstance(entry.get('image-path'), str)
                    or not Path(entry['image-path']).is_absolute()
                    or not isinstance(entry.get('system-entities'), list)):
                raise ValueError('Incomplete disk-image inventory entry')
            same_image = Path(entry['image-path']).resolve() == image_path
            image_present |= same_image
            for entity in entry['system-entities']:
                if (not isinstance(entity, dict) or not isinstance(entity.get('dev-entry'), str)
                        or not entity['dev-entry'].startswith('/dev/')):
                    raise ValueError('Invalid disk-image system entity')
                owned_device_for_image |= same_image and device is not None and entity['dev-entry'] == device
                if 'mount-point' in entity:
                    if not isinstance(entity['mount-point'], str) or not Path(entity['mount-point']).is_absolute():
                        raise ValueError('Invalid disk-image mount point')
                    mount_present |= Path(entity['mount-point']).resolve() == mount_path
        state.update(inventoryValid=True, imagePresent=image_present, mountPresent=mount_present,
                     ownedDeviceForImage=owned_device_for_image)
        parent_stat = mount.parent.stat()
        try:
            mount_stat = mount.lstat()
        except FileNotFoundError:
            state['mountPointState'] = 'absent'
        else:
            if not stat.S_ISDIR(mount_stat.st_mode):
                state['mountPointState'] = 'not-a-directory'
            elif mount_stat.st_dev != parent_stat.st_dev or mount_stat.st_ino == parent_stat.st_ino:
                state['mountPointState'] = 'mounted-filesystem'
            else:
                state['mountPointState'] = 'nonempty-directory' if next(mount.iterdir(), None) else 'empty-parent-filesystem-directory'
        state['confirmedDetached'] = (not image_present and not mount_present and
                                      state['mountPointState'] in ('absent', 'empty-parent-filesystem-directory'))
    except (OSError, ValueError, TypeError, plistlib.InvalidFileException, subprocess.SubprocessError) as error:
        state['inspectionError'] = str(error)[:1000]
    print('DMG detach state: ' + json.dumps(state, sort_keys=True), file=sys.stderr)
    return state


def _attached_device(data, mount):
    """Capture the root device from this attach, bound to its exact mountpoint."""
    try:
        info = plistlib.loads(data)
        entities = info.get('system-entities') if isinstance(info, dict) else None
        if not isinstance(entities, list) or not entities:
            raise ValueError('Missing attached system entities')
        mounted = []
        for entity in entities:
            if (not isinstance(entity, dict) or not isinstance(entity.get('dev-entry'), str)
                    or not re.fullmatch(r'/dev/disk[0-9]+(?:s[0-9]+)*', entity['dev-entry'])):
                raise ValueError('Invalid attached device')
            if 'mount-point' in entity:
                value = entity['mount-point']
                if not isinstance(value, str) or not Path(value).is_absolute():
                    raise ValueError('Invalid attached mountpoint')
                mounted.append((entity['dev-entry'], Path(value).resolve()))
        roots = {entity['dev-entry'] for entity in entities if re.fullmatch(r'/dev/disk[0-9]+', entity['dev-entry'])}
        if len(roots) != 1:
            raise ValueError('Attach plist does not identify one root device')
        device = roots.pop()
        if (len(mounted) != 1 or mounted[0][1] != mount.resolve()
                or not re.fullmatch(re.escape(device) + r'(?:s[0-9]+)*', mounted[0][0])):
            raise ValueError('Attached root device is not bound to the owned mountpoint')
    except (ValueError, TypeError, OSError, plistlib.InvalidFileException) as error:
        raise TemporaryMountError('Cannot establish owned device from attach plist; mount preserved at %s: %s' %
                                  (mount, error)) from error
    print('DMG attach device: ' + json.dumps(dict(mount=str(mount), device=device)), file=sys.stderr)
    return device


def _detach_owned_mount(mount, image, device):
    """Detach only the captured device while it still belongs to this image."""
    failure = None
    for attempt in range(4):
        state = _detached_state(mount, image, device)
        if state['confirmedDetached']:
            return
        if not state.get('ownedDeviceForImage') or 'inspectionError' in state:
            raise TemporaryMountError('Owned device cannot be safely detached; mount preserved at %s; state=%s' %
                                      (mount, json.dumps(state, sort_keys=True)))
        arguments = ['/usr/bin/hdiutil', 'detach', device]
        if attempt == 3:
            arguments.append('-force')
        try:
            subprocess.run(arguments, check=True, capture_output=True, timeout=10)
            failure = None
            state = _detached_state(mount, image, device)
            if state['confirmedDetached']:
                return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            failure = error
        if attempt < 3:
            time.sleep(.5)
    # A timed-out hdiutil may finish detaching after its caller exits. Never
    # infer that from stderr: require both a valid image inventory and a safe
    # mountpoint before allowing the caller's nonrecursive rmdir cleanup.
    state = _detached_state(mount, image, device)
    if state['confirmedDetached']:
        return
    status = ('exit status %d' % failure.returncode if isinstance(failure, subprocess.CalledProcessError)
              else 'timeout' if failure is not None else 'device still attached after successful hdiutil')
    # Keep the system diagnostic: an exit code alone cannot distinguish a busy
    # volume from an already detached image or a runner's disk-image failure.
    detail = getattr(failure, 'stderr', None) or getattr(failure, 'stdout', None) or ''
    if isinstance(detail, bytes):
        detail = detail.decode('utf-8', errors='replace')
    detail = str(detail).strip()[:2000]
    raise TemporaryMountError('Temporary DMG detach failed (%s); mount preserved at %s%s; state=%s' %
                              (status, mount, ': ' + detail if detail else '', json.dumps(state, sort_keys=True))) from failure


@contextmanager
def readonly_mount(image, *, prefix, command=None):
    """Never recursively remove a directory that may still be a mounted disk."""
    mount = Path(tempfile.mkdtemp(prefix=prefix, dir='/private/tmp'))
    mounted = False
    device = None
    original_error = None
    try:
        arguments = ['/usr/bin/hdiutil', 'attach', '-plist', '-readonly', '-nobrowse', '-noautoopen',
                     '-mountpoint', mount, image]
        if command is None:
            data = subprocess.run([str(value) for value in arguments], check=True, capture_output=True).stdout
        else:
            data = command(arguments)
        mounted = True
        device = _attached_device(data, mount)
        yield mount
    except BaseException as error:
        original_error = error
        raise
    finally:
        try:
            if mounted:
                if device is None:
                    raise TemporaryMountError('Unknown attached device; mount preserved at %s' % mount)
                _detach_owned_mount(mount, Path(image), device)
            # Even a partial attach or unexpected leftover is safe: rmdir
            # cannot descend into or delete files from the read-only volume.
            try:
                mount.rmdir()
            except FileNotFoundError:
                pass
        except Exception as cleanup_error:
            if original_error is not None:
                if hasattr(original_error, 'add_note'):
                    original_error.add_note('Temporary DMG cleanup failed; mount preserved at %s' % mount)
                raise original_error from cleanup_error
            raise
