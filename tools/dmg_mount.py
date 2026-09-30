"""Mount only a caller-owned temporary read-only DMG, then detach it safely."""
from contextlib import contextmanager
from pathlib import Path
import subprocess
import tempfile
import time


class TemporaryMountError(RuntimeError):
    pass


def _detach_owned_mount(mount):
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
    status = ('exit status %d' % failure.returncode if isinstance(failure, subprocess.CalledProcessError)
              else 'timeout')
    raise TemporaryMountError('Temporary DMG detach failed (%s); mount preserved at %s' % (status, mount)) from failure


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
                _detach_owned_mount(mount)
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
