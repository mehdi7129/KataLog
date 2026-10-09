#!/usr/bin/env python3
"""Serialize app/engine builds through the final artifact capture.

The inherited descriptor lets build-app call build-engine under the same lock.
It also keeps the lock held if the wrapper exits while its child is still alive.
"""
import fcntl
import os
from pathlib import Path
import signal
import subprocess
import sys


def main(argv=None):
    args = sys.argv[1:] if argv is None else argv
    if not args:
        raise SystemExit('Usage: build-lock.py BUILD_SCRIPT [ARGUMENTS...]')
    script = str(Path(args[0]).resolve())
    lock = Path('/private/tmp') / ('katalog-build-' + str(os.getuid()) + '.lock')
    inherited = os.environ.get('KATALOG_BUILD_LOCK_FD')
    if inherited is None:
        descriptor = os.open(lock, os.O_CREAT | os.O_RDWR, 0o600)
        try:
            fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
        except BlockingIOError:
            print('Un autre build KataLog est actif ; attente de sa capture finale.', file=sys.stderr, flush=True)
            fcntl.flock(descriptor, fcntl.LOCK_EX)
    else:
        descriptor = int(inherited)
        actual, expected = os.fstat(descriptor), lock.stat()
        if (actual.st_dev, actual.st_ino) != (expected.st_dev, expected.st_ino):
            raise RuntimeError('Le verrou de build hérité est invalide.')
        # The same open file description already owns this lock. Never unlock
        # it in the nested wrapper: the parent still needs it during packaging.
        fcntl.flock(descriptor, fcntl.LOCK_EX | fcntl.LOCK_NB)
    try:
        environment = dict(os.environ, KATALOG_BUILD_LOCK_FD=str(descriptor),
                           KATALOG_BUILD_LOCK_SCRIPT=script)
        child = subprocess.Popen(['/bin/bash', script, *args[1:]], env=environment,
                                 pass_fds=(descriptor,), start_new_session=True)
        def interrupt(signum, _frame):
            try:
                os.killpg(child.pid, signum)
            except ProcessLookupError:
                pass
        previous = {signum: signal.signal(signum, interrupt) for signum in (signal.SIGINT, signal.SIGTERM)}
        try:
            status = child.wait()
            return status if status >= 0 else 128 - status
        finally:
            for signum, handler in previous.items():
                signal.signal(signum, handler)
    finally:
        os.close(descriptor)


if __name__ == '__main__':
    raise SystemExit(main())
