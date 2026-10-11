"""附件与别名清单的跨平台回归测试。"""
import hashlib
import json
import os
from pathlib import Path
import subprocess
import tempfile
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / 'scripts/release/assets.sh'


class AssetsTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.archive = self.root / 'App.zip'
        self.archive.write_bytes(b'final archive')
        self.extra = self.root / 'plugins.json'
        self.extra.write_text('{}')

    def run_script(self, **overrides):
        env = dict(os.environ, ARCHIVES=str(self.archive), EXTRA_ASSETS=str(self.extra),
                   ASSET_ALIASES='', GITHUB_ENV=str(self.root / 'env'),
                   GITHUB_OUTPUT=str(self.root / 'output'))
        env.update(overrides)
        return subprocess.run(['bash', str(SCRIPT)], env=env, capture_output=True, text=True)

    def test_final_bytes_and_outputs(self):
        alias = self.root / 'OldApp.zip'
        result = self.run_script(ASSET_ALIASES=f'{self.archive}={alias}')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(alias.read_bytes(), self.archive.read_bytes())
        assets = json.loads(result.stdout)
        self.assertEqual([a['name'] for a in assets], ['App.zip', 'plugins.json', 'OldApp.zip'])
        for asset in assets:
            self.assertEqual(asset['sha256'], hashlib.sha256((self.root / asset['name']).read_bytes()).hexdigest())
        sums = (self.root / 'SHA256SUMS.txt').read_text()
        self.assertEqual(len(sums.splitlines()), 3)
        self.assertIn('assets=' + json.dumps(assets, separators=(',', ':')), (self.root / 'output').read_text())
        self.assertIn(str(alias), (self.root / 'env').read_text())
        self.assertEqual(json.loads((self.root / 'release-assets.json').read_text()), assets)

    def test_no_optional_assets(self):
        result = self.run_script(EXTRA_ASSETS='')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(len(json.loads(result.stdout)), 1)

    def test_reject_invalid_inputs_before_copy(self):
        alias = self.root / 'Alias.zip'
        cases = [dict(ARCHIVES=''), dict(EXTRA_ASSETS=str(self.root / 'missing.json')),
                 dict(EXTRA_ASSETS=str(self.archive)),
                 dict(ASSET_ALIASES=f'{self.extra}={alias}'),
                 dict(ASSET_ALIASES=f'{self.archive}={self.archive}'),
                 dict(ASSET_ALIASES=f'{self.archive}={self.root}/../Outside.zip'),
                 dict(ASSET_ALIASES=f'{self.archive}={alias} invalid'),
                 dict(ASSET_ALIASES=f'{self.archive}={alias} {self.archive}={alias}')]
        for case in cases:
            with self.subTest(case=case):
                self.assertNotEqual(self.run_script(**case).returncode, 0)
                self.assertFalse(alias.exists())

    def test_reserved_names_and_other_directory(self):
        for name in ['SHA256SUMS.txt', 'release-assets.json']:
            path = self.root / name
            path.write_text('preserve')
            self.assertNotEqual(self.run_script(EXTRA_ASSETS=str(path)).returncode, 0)
            self.assertEqual(path.read_text(), 'preserve')
        sub = self.root / 'other'
        sub.mkdir()
        file = sub / 'other.json'
        file.write_text('{}')
        self.assertNotEqual(self.run_script(EXTRA_ASSETS=str(file)).returncode, 0)


if __name__ == '__main__':
    unittest.main()
