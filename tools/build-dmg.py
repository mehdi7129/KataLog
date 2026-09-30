#!/usr/bin/env python3
"""Create the standard drag-to-Applications disk image from a signed app."""
import argparse
import hashlib
import importlib.util
import json
import os
from pathlib import Path
import plistlib
import subprocess
import shutil
import tempfile

import dmgbuild

_mount_spec = importlib.util.spec_from_file_location('katalog_dmg_mount', Path(__file__).with_name('dmg_mount.py'))
dmg_mount = importlib.util.module_from_spec(_mount_spec)
_mount_spec.loader.exec_module(dmg_mount)


def notarize(path, profile):
    result = subprocess.run(['/usr/bin/xcrun', 'notarytool', 'submit', str(path),
                             '--keychain-profile', profile, '--wait', '--output-format', 'json'],
                            check=True, capture_output=True, text=True)
    submission = json.loads(result.stdout)
    if submission.get('status') != 'Accepted':
        raise RuntimeError('Notarisation non acceptée : ' + str(submission.get('id', '')))
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'staple', str(path)], check=True)
    subprocess.run(['/usr/bin/xcrun', 'stapler', 'validate', str(path)], check=True)
    return {'id': submission['id'], 'status': submission['status']}


def build(app, output, identity, profile=None):
    output = output.resolve()
    if output.exists():
        raise ValueError('Le DMG de destination existe déjà ; choisissez un autre nom pour le conserver.')
    output.parent.mkdir(parents=True, exist_ok=True)
    # File Provider directories do not support hdiutil's writable temporary
    # image on macOS 27. Build, sign and verify on the local volume first.
    with tempfile.TemporaryDirectory(prefix='katalog-dmg-publish-', dir='/private/tmp') as staging:
        local = Path(staging) / output.name
        result = _build_local(app, local, identity, profile)
        created = False
        try:
            with local.open('rb') as source, output.open('xb') as destination:
                created = True
                shutil.copyfileobj(source, destination, 1024 * 1024)
                destination.flush(); os.fsync(destination.fileno())
            if hashlib.sha256(output.read_bytes()).hexdigest() != result['sha256']:
                raise ValueError('Le DMG publié ne correspond pas au package local vérifié.')
        except BaseException:
            if created:
                output.unlink(missing_ok=True)
            raise
    print(json.dumps(result, indent=2))
    return result


def _build_local(app, output, identity, profile=None):
    app, output = app.resolve(), output.resolve()
    if output.exists():
        raise ValueError('Le DMG de destination existe déjà ; choisissez un autre nom pour le conserver.')
    info = plistlib.loads((app / 'Contents/Info.plist').read_bytes())
    if info.get('KatalogBundledEngineRequired') is not True:
        raise ValueError('Cette app ne contient pas le moteur autonome requis.')
    if profile and identity == '-':
        raise ValueError('Une signature Developer ID est requise pour notariser.')
    subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(app)], check=True)
    output.parent.mkdir(parents=True, exist_ok=True)
    with tempfile.TemporaryDirectory(prefix='katalog-dmg-build-', dir='/private/tmp') as work:
        work = Path(work)
        background = work / 'background.png'
        subprocess.run(['/usr/bin/xcrun', 'swift', str(Path(__file__).with_name('dmg-background.swift')), str(background)], check=True)
        settings = {
            'format': 'ULFO', 'filesystem': 'HFS+',
            'files': [str(app)], 'symlinks': {'Applications': '/Applications'},
            'icon': str(app / 'Contents/Resources/KataLog.icns'),
            'background': str(background), 'window_rect': ((150, 150), (660, 420)),
            'icon_locations': {app.name: (170, 205), 'Applications': (490, 205)},
            'icon_size': 104, 'text_size': 13, 'label_pos': 'bottom',
            'default_view': 'icon-view', 'arrange_by': None,
            'show_status_bar': False, 'show_tab_view': False, 'show_toolbar': False,
            'show_pathbar': False, 'show_sidebar': False,
            # SetFile's hide-extension flag adds FinderInfo to the app and
            # breaks strict signature verification. Leave the signed bundle
            # untouched; Finder handles the .app extension using its settings.
        }
        volume_name = 'KataLog Preview' if info.get('KataLogUIReviewPreview') is True else 'KataLog'
        dmgbuild.build_dmg(str(output), volume_name + ' ' + info['CFBundleShortVersionString'], settings=settings)
    sign = ['/usr/bin/codesign', '--force', '--sign', identity]
    if identity != '-':
        sign += ['--timestamp']
    subprocess.run(sign + [str(output)], check=True)
    subprocess.run(['/usr/bin/hdiutil', 'verify', str(output)], check=True)
    with dmg_mount.readonly_mount(output, prefix='katalog-dmg-content-') as mount:
        copied = mount / app.name
        copied_info = plistlib.loads((copied / 'Contents/Info.plist').read_bytes())
        for key in ('CFBundleShortVersionString', 'CFBundleVersion', 'KatalogBundledEngineRequired'):
            if copied_info.get(key) != info.get(key):
                raise ValueError('Le bundle copié dans le DMG ne correspond pas au build.')
        link = mount / 'Applications'
        if not link.is_symlink() or str(link.readlink()) != '/Applications':
            raise ValueError('Le raccourci Applications est invalide.')
        subprocess.run(['/usr/bin/codesign', '--verify', '--deep', '--strict', str(copied)], check=True)
        helper = copied / 'Contents/Helpers/KataLogEngine.app/Contents/MacOS/KataLogEngine'
        subprocess.run([str(helper), '--katalog-runtime-info'], check=True, stdout=subprocess.DEVNULL)
    result = {'version': info['CFBundleShortVersionString'], 'build': info['CFBundleVersion'], 'notarization': None}
    if profile:
        result['notarization'] = notarize(output, profile)
    result['sha256'] = hashlib.sha256(output.read_bytes()).hexdigest()
    result['bytes'] = output.stat().st_size
    return result


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--app', required=True, type=Path)
    parser.add_argument('--output', required=True, type=Path)
    parser.add_argument('--identity', default='-')
    parser.add_argument('--notary-profile')
    args = parser.parse_args()
    build(args.app, args.output, args.identity, args.notary_profile)
