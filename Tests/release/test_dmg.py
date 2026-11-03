import json
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import unittest
import zipfile


RELEASE = Path(__file__).resolve().parents[2] / 'scripts/release'
MOCK = r'''#!/usr/bin/env python3
import json, os, sys, zipfile
from pathlib import Path
tool, args = Path(sys.argv[0]).name, sys.argv[1:]
with open(os.environ['FAKE_CALLS'], 'a') as stream:
    stream.write(json.dumps([tool, *args]) + '\n')
if tool == 'hdiutil' and args[0] == 'attach':
    volume = Path(args[args.index('-mountpoint') + 1])
    with zipfile.ZipFile(os.environ['FAKE_ZIP']) as archive: archive.extractall(volume)
    if os.environ.get('FAKE_DIFFERENT'): (volume / 'Sample.app/Contents/MacOS/Sample').write_bytes(b'other')
    (volume / '.background').mkdir()
    (volume / '.background/background.png').write_bytes(b'picture')
    if not os.environ.get('FAKE_NO_LAYOUT'): (volume / '.DS_Store').write_bytes(b'layout')
elif tool == 'ditto':
    with zipfile.ZipFile(args[-2]) as archive: archive.extractall(args[-1])
elif tool == 'codesign':
    if args[0] == '--verify': sys.exit(int(os.environ.get('FAKE_SIGNATURE', '0')))
    print('Authority=Developer ID Application: Fixture (TESTONLY00)')
    team = os.environ.get('FAKE_DMG_TEAM', 'TESTONLY00') if args[-1].endswith('.dmg') else 'TESTONLY00'
    print('TeamIdentifier=' + team)
    print('CDHash=' + '0' * 39 + '1')
elif tool == 'xcrun':
    if args[0] == 'notarytool':
        if args[1] == 'submit': print('{"id":"fixture"}')
        elif args[1] == 'wait': print(json.dumps({'status':os.environ.get('FAKE_STATUS','Accepted')}))
        else: print('{}')
    elif args[0] == 'stapler': sys.exit(int(os.environ.get('FAKE_TICKET', '0')))
    elif args[0] == 'swift': sys.exit(int(os.environ.get('FAKE_ALIAS', '0')))
elif tool == 'spctl':
    if args[0] == '--status': print('assessments enabled')
    else: print('source=' + os.environ.get('FAKE_SOURCE', 'Notarized Developer ID'))
elif tool == 'lipo': print('x86_64')
'''


class DMGTests(unittest.TestCase):
    def run_check(self, notarize=False, **overrides):
        with tempfile.TemporaryDirectory() as directory:
            root = Path(directory)
            (root / 'bin').mkdir()
            mock = root / 'bin/mock'
            mock.write_text(MOCK)
            mock.chmod(0o755)
            for name in ('hdiutil', 'ditto', 'codesign', 'xcrun', 'spctl', 'lipo', 'sleep'):
                (root / 'bin' / name).symlink_to(mock)
            image = root / 'Sample.dmg'
            image.write_bytes(b'dmg fixture')
            archive = root / 'Sample.zip'
            with zipfile.ZipFile(archive, 'w') as bundle:
                bundle.writestr('Sample.app/Contents/Info.plist', plistlib.dumps({'CFBundleExecutable':'Sample'}))
                bundle.writestr('Sample.app/Contents/MacOS/Sample', b'fixture')
                bundle.writestr('Sample.app/Contents/CodeResources', bytes.fromhex('0' * 39 + '1'))
            calls = root / 'calls'
            env = dict(os.environ, PATH=str(root / 'bin') + os.pathsep + os.environ['PATH'],
                       RUNNER_TEMP=str(root), FAKE_ZIP=str(archive), FAKE_CALLS=str(calls),
                       NOTARY_KEY_P8='fixture', NOTARY_KEY_ID='fixture', SPCTL_TRIES='1',
                       NOTARY_APPLE_ID='', CODESIGN_NAME='')
            env.update(overrides)
            command = [str(RELEASE / ('notarize.sh' if notarize else 'verify-dmg.sh')), str(image)]
            if not notarize: command.append(str(archive))
            result = subprocess.run(command, env=env, capture_output=True, text=True)
            self.assertFalse(list(root.glob('frit-dmg-check.*')))
            return result, [json.loads(line) for line in calls.read_text().splitlines()]

    def test_notarized_dmg_and_its_app_pass_without_repacking(self):
        result, calls = self.run_check(notarize=True)
        self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
        self.assertTrue(any(call[:3] == ['spctl', '--assess', '--type'] and 'open' in call for call in calls))
        self.assertTrue(any(call[:2] == ['hdiutil', 'detach'] for call in calls))
        self.assertFalse(any(call[:2] == ['ditto', '-c'] for call in calls))

    def test_changed_app_missing_layout_wrong_alias_signature_ticket_or_team_are_rejected(self):
        for overrides in ({'FAKE_DIFFERENT':'1'}, {'FAKE_NO_LAYOUT':'1'}, {'FAKE_ALIAS':'1'},
                          {'FAKE_SIGNATURE':'1'}, {'FAKE_TICKET':'65'}, {'FAKE_DMG_TEAM':'OTHER12345'},
                          {'FAKE_SOURCE':'Unnotarized Developer ID'}):
            with self.subTest(overrides=overrides):
                result, calls = self.run_check(**overrides)
                self.assertNotEqual(result.returncode, 0)
                self.assertTrue(any(call[:2] == ['hdiutil', 'detach'] for call in calls))

    def test_apple_rejection_stops_before_mounting_or_stapling(self):
        result, calls = self.run_check(notarize=True, FAKE_STATUS='Invalid')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[0] == 'hdiutil' or call[:2] == ['xcrun', 'stapler'] for call in calls))
