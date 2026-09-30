#!/usr/bin/env python3
"""Sign nested native runtime files before signing the enclosing macOS app."""
import argparse
from pathlib import Path
import plistlib
import re
import subprocess

MACHO = {b'\xfe\xed\xfa\xce', b'\xce\xfa\xed\xfe', b'\xfe\xed\xfa\xcf',
         b'\xcf\xfa\xed\xfe', b'\xca\xfe\xba\xbe', b'\xbe\xba\xfe\xca',
         b'\xca\xfe\xba\xbf', b'\xbf\xba\xfe\xca'}


def is_native(path):
    if path.is_symlink() or not path.is_file():
        return False
    with path.open('rb') as stream:
        return stream.read(4) in MACHO


def sign_bundle(app, identity):
    if app.suffix != '.app' or not (app / 'Contents/Info.plist').is_file():
        raise ValueError('Un bundle .app valide est requis.')
    apps = [path for pattern in ('*.app', '*.xpc') for path in app.rglob(pattern) if not path.is_symlink()]
    apps.append(app)
    main_executables = set()
    for bundle in apps:
        info = plistlib.loads((bundle / 'Contents/Info.plist').read_bytes())
        main_executables.add(bundle / 'Contents/MacOS' / info['CFBundleExecutable'])
    all_native = [path for path in app.rglob('*') if is_native(path)]
    # Recent Xcode toolchains inject development-only Swift search paths.
    # System Swift is available from /usr/lib/swift on supported macOS versions.
    # Remove these paths before signing so a developer installation is not part
    # of the distributed executable's runtime search order.
    for path in all_native:
        commands = subprocess.check_output(['/usr/bin/otool', '-l', str(path)], text=True)
        for rpath in re.findall(r'cmd LC_RPATH\s+cmdsize \d+\s+path (.+?) \(offset', commands):
            if not rpath.startswith(('@loader_path', '@executable_path', '/System/Library/', '/usr/lib/')):
                subprocess.run(['/usr/bin/install_name_tool', '-delete_rpath', rpath, str(path)], check=True)
    native = [path for path in all_native if path not in main_executables]
    frameworks = [path for path in app.rglob('*.framework') if not path.is_symlink()]
    paths = sorted(native, key=lambda path: len(path.parts), reverse=True)
    paths += sorted(set(frameworks + apps), key=lambda path: len(path.parts), reverse=True)
    for path in paths:
        command = ['/usr/bin/codesign', '--force', '--sign', identity]
        if identity != '-':
            command += ['--options', 'runtime', '--timestamp']
        command += [str(path)]
        subprocess.run(command, check=True, stdout=subprocess.DEVNULL)
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    print(f'{len(native) + len(apps)} composants natifs et {len(apps)} bundles signés.')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', type=Path, required=True)
    parser.add_argument('--identity', required=True)
    args = parser.parse_args()
    sign_bundle(args.app.resolve(), args.identity)
