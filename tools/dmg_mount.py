"""Mount only a caller-owned temporary read-only DMG, then detach it safely."""
from contextlib import contextmanager
import json
from pathlib import Path
import plistlib
import stat
import subprocess
import sys
import tempfile
import time


class TemporaryMountError(RuntimeError):
    pass


def _detached_state(mount, image):
    """Require independent disk-image and filesystem evidence after a failed detach."""
    state = dict(mount=str(mount), image=str(image), confirmedDetached=False)
    try:
        result = subprocess.run(['/usr/bin/hdiutil', 'info', '-plist'], check=True,
                                capture_output=True, timeout=10)
        info = plistlib.loads(result.stdout)
        if not isinstance(info, dict) or not isinstance(info.get('images'), list):
            raise ValueError('Missing disk-image inventory')
        image_path, mount_path = image.resolve(), mount.resolve()
        image_present, mount_present = False, False
        for entry in info['images']:
            if (not isinstance(entry, dict) or not isinstance(entry.get('image-path'), str)
                    or not Path(entry['image-path']).is_absolute()
                    or not isinstance(entry.get('system-entities'), list)):
                raise ValueError('Incomplete disk-image inventory entry')
            image_present |= Path(entry['image-path']).resolve() == image_path
            for entity in entry['system-entities']:
                if (not isinstance(entity, dict) or not isinstance(entity.get('dev-entry'), str)
                        or not entity['dev-entry'].startswith('/dev/')):
                    raise ValueError('Invalid disk-image system entity')
                if 'mount-point' in entity:
                    if not isinstance(entity['mount-point'], str) or not Path(entity['mount-point']).is_absolute():
                        raise ValueError('Invalid disk-image mount point')
                    mount_present |= Path(entity['mount-point']).resolve() == mount_path
        state.update(inventoryValid=True, imagePresent=image_present, mountPresent=mount_present)
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


def _detach_owned_mount(mount, image):
    """Retry this context's mount only; force is the last bounded attempt."""
    for attempt in range(4):
        arguments = ['/usr/bin/hdiutil', 'detach', str(mount)]
        if attempt == 3:
            arguments.append('-force')
        try:
            subprocess.run(arguments, check=True, capture_output=True, timeout=10)
            return
        except (subprocess.CalledProcessError, subprocess.TimeoutExpired) as error:
            failure = error
            if attempt < 3:
                time.sleep(.5)
    # A timed-out hdiutil may finish detaching after its caller exits. Never
    # infer that from stderr: require both a valid image inventory and a safe
    # mountpoint before allowing the caller's nonrecursive rmdir cleanup.
    state = _detached_state(mount, image)
    if state['confirmedDetached']:
        return
    status = ('exit status %d' % failure.returncode if isinstance(failure, subprocess.CalledProcessError)
              else 'timeout')
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
    original_error = None
    try:
        arguments = ['/usr/bin/hdiutil', 'attach', '-readonly', '-nobrowse', '-noautoopen',
                     '-mountpoint', mount, image]
        if command is None:
            subprocess.run([str(value) for value in arguments], check=True, stdout=subprocess.DEVNULL)
        else:
            command(arguments)
        mounted = True
        yield mount
    except BaseException as error:
        original_error = error
        raise
    finally:
        try:
            if mounted:
                _detach_owned_mount(mount, Path(image))
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
