"""实际发布脚本的状态、摘要、失败和竞态回归；只使用本地 Git 与 gh 替身。"""
import json
import os
from pathlib import Path
import subprocess
import sys
import tempfile
import unittest

RELEASE = Path(__file__).resolve().parents[2] / 'scripts/release'
FAKE_GH = r'''#!/usr/bin/env python3
import hashlib, json, os, pathlib, shutil, sys
root = pathlib.Path(os.environ['FAKE_RELEASE_ROOT'])
state_path = root / 'state.json'
s = json.loads(state_path.read_text())
a = sys.argv[1:]
s['calls'].append(a)
def save(): state_path.write_text(json.dumps(s))
def stop(message):
    save(); print(message, file=sys.stderr); sys.exit(1)
def argument(flag): return a[a.index(flag) + 1]
def snapshot():
    result = json.loads(pathlib.Path(os.environ['FAKE_DRAFT_FIXTURE']).read_text())
    result['draft'] = s['status'] == 'draft'
    result['assets'] = []
    for name in s['assets']:
        data = (root / 'remote' / name).read_bytes()
        item = {'name': name, 'state': 'uploaded', 'size': len(data), 'digest': 'sha256:' + hashlib.sha256(data).hexdigest()}
        item.update(s.get('overrides', {}).get(name, {}))
        result['assets'].append(item)
    result.update(s.get('snapshot_override', {}))
    return result
if a[0] == 'api':
    endpoint = next(x for x in a[1:] if x.startswith('repos/'))
    method = argument('--method') if '--method' in a else 'GET'
    if method == 'POST':
        body = json.loads(pathlib.Path(argument('--input')).read_text())
        s['status'] = 'draft'; s['assets'] = []; s['notes'] = body['body']; s['uploaded'] = False
        print(json.dumps(snapshot()))
    elif method == 'PATCH':
        body = json.loads(pathlib.Path(argument('--input')).read_text())
        if 'body' in body:
            s['notes'] = body['body']
            if os.environ.get('FAKE_PUBLISHED_BEFORE_UPLOAD'): s['status'] = 'published'
        if body.get('draft') is False: s['status'] = 'published'
        if 'make_latest' in body: s['latest'] = body['make_latest']
        print(json.dumps(snapshot()))
    elif '/releases/tags/' in endpoint:
        if s['status'] != 'published': stop('HTTP 404: Not Found')
        print(json.dumps(snapshot()))
    elif '/releases/' in endpoint and '?' not in endpoint:
        if os.environ.get('FAKE_QUERY_ERROR'): stop('HTTP 502: Bad Gateway')
        if s['status'] == 'none' or os.environ.get('FAKE_ID_QUERY_ERROR'): stop('HTTP 404: Not Found')
        result = snapshot()
        if os.environ.get('FAKE_QUERY_ID_MISMATCH'): result['id'] += 1
        print(json.dumps(result))
    else:
        s['list_count'] += 1
        if os.environ.get('FAKE_QUERY_ERROR'): stop('HTTP 502: Bad Gateway')
        if os.environ.get('FAKE_LIST_ERROR'):
            if os.environ.get('FAKE_LIST_ERROR') == 'partial': print('[[]]')
            stop('HTTP 502: Bad Gateway')
        if os.environ.get('FAKE_FINAL_LIST_ERROR') and s.get('uploaded'):
            stop('HTTP 502: Bad Gateway')
        items = [snapshot()] if s['status'] != 'none' else []
        if os.environ.get('FAKE_NEWER_AFTER_UPLOAD') and s.get('uploaded'):
            items.append({'id': 42, 'tag_name': 'v2.0.0', 'draft': False, 'prerelease': False})
        if os.environ.get('FAKE_DUPLICATE_TAG') and items: items.append(items[0])
        if os.environ.get('FAKE_LATER_PAGE'):
            print('[]'); print(json.dumps(items))
        else: print(json.dumps(items))
elif a[:2] == ['release', 'download']:
    name = argument('--pattern'); destination = pathlib.Path(argument('--dir'))
    if os.environ.get('FAKE_DOWNLOAD_ERROR'): stop('download failed')
    shutil.copyfile(root / 'remote' / name, destination / name)
elif a[:2] == ['release', 'upload']:
    for index, value in enumerate([x for x in a[3:] if x != '--clobber'], 1):
        path = pathlib.Path(value); shutil.copyfile(path, root / 'remote' / path.name)
        if path.name not in s['assets']: s['assets'].append(path.name)
        if os.environ.get('FAKE_UPLOAD_FAIL_AFTER') == str(index): stop('upload failed after an asset was replaced')
    if os.environ.get('FAKE_REMOTE_SUMS_CHANGED'):
        p = root / 'remote' / 'SHA256SUMS.txt'; p.write_text(p.read_text() + '\n')
    s['uploaded'] = True
else: stop('unexpected fake gh command')
save()
'''


class ReleaseIntegrityTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='frit-release-integrity-')
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.app = self.root / 'app'
        self.app.mkdir()
        (self.root / 'remote').mkdir()
        self.env = dict(os.environ, GIT_AUTHOR_NAME='test', GIT_AUTHOR_EMAIL='test@example.com',
                        GIT_COMMITTER_NAME='test', GIT_COMMITTER_EMAIL='test@example.com')
        subprocess.run(['git', 'init', '-q', '--bare', str(self.root / 'origin.git')], check=True)
        self.git('init', '-q')
        self.git('remote', 'add', 'origin', str(self.root / 'origin.git'))
        (self.app / 'CHANGELOG.md').write_text('# 更新日志\n\n## 1.0.0\n\n- fixture\n')
        self.git('add', 'CHANGELOG.md')
        self.git('commit', '-q', '-m', 'fixture')
        self.sha = self.git('rev-parse', 'HEAD').stdout.strip()
        self.git('push', '-q', 'origin', self.sha + ':refs/tags/v1.0.0')
        (self.app / 'dist').mkdir()
        (self.app / 'dist/App.zip').write_bytes(b'new app bytes')
        (self.app / 'dist/plugins.json').write_bytes(b'{"plugins":[]}')
        (self.app / 'notes.md').write_text('new notes')
        (self.root / 'bin').mkdir()
        (self.root / 'bin/gh').write_text(FAKE_GH)
        (self.root / 'bin/gh').chmod(0o700)
        self.env.update(PATH=str(self.root / 'bin') + os.pathsep + self.env['PATH'],
                        FAKE_RELEASE_ROOT=str(self.root), GITHUB_REPOSITORY='fixture/app',
                        FAKE_DRAFT_FIXTURE=str(RELEASE.parents[1] / 'Tests/release/Fixtures/new-draft.json'),
                        GH_REPO='fixture/app', TAG='v1.0.0', SHA=self.sha, APP_NAME='App',
                        ARCHIVES='dist/App.zip', EXTRA_ASSETS='dist/plugins.json',
                        RELEASE_ASSETS='dist/App.zip dist/plugins.json', ASSET_ALIASES='',
                        PRERELEASE='false', OVERWRITE='false', DRY_RUN='false',
                        ARCHIVE_DIR='dist', NOTES_FILE='notes.md', GITHUB_OUTPUT=str(self.root / 'output'))
        for channel in ('GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_STEP_SUMMARY', 'GITHUB_STATE'):
            self.env[channel] = str(self.root / channel.lower())
        subprocess.run(['bash', str(RELEASE / 'assets.sh')], cwd=self.app, env=self.env, check=True, capture_output=True)
        self.save({'status': 'none', 'assets': [], 'notes': 'old notes', 'latest': 'true', 'calls': [], 'list_count': 0})

    def git(self, *args):
        return subprocess.run(['git', *args], cwd=self.app, env=self.env, check=True, capture_output=True, text=True)

    def load(self):
        return json.loads((self.root / 'state.json').read_text())

    def save(self, value):
        (self.root / 'state.json').write_text(json.dumps(value))

    def seed(self, status='published'):
        state = self.load()
        state.update(status=status, assets=['App.zip', 'plugins.json', 'SHA256SUMS.txt'])
        for name in state['assets']:
            (self.root / 'remote' / name).write_bytes((self.app / 'dist' / name).read_bytes())
        self.save(state)

    def run_script(self, script='publish.sh', **overrides):
        (self.root / 'output').write_text('')
        return subprocess.run(['bash', str(RELEASE / script)], cwd=self.app, env=dict(self.env, **overrides), capture_output=True, text=True)

    def assert_no_mutation(self, before):
        after = self.load()
        for key in ('status', 'assets', 'notes', 'latest'):
            self.assertEqual(after[key], before[key])
        self.assertFalse(any(call[:2] == ['release', 'upload'] or
                             (call[0] == 'api' and '--method' in call and call[call.index('--method') + 1] in ('POST', 'PATCH'))
                             for call in after['calls']))
        self.assertEqual((self.root / 'output').read_text(), '')

    def test_public_complete_is_read_only_even_with_different_rebuild(self):
        self.seed()
        before = self.load()
        (self.app / 'dist/App.zip').write_bytes(b'different rebuild')
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_mutation(before)

    def test_public_missing_asset_never_reaches_partial_upload(self):
        for missing in ('App.zip', 'plugins.json', 'SHA256SUMS.txt'):
            with self.subTest(missing=missing):
                self.seed()
                state = self.load(); state['assets'].remove(missing); state['calls'] = []; self.save(state)
                before = self.load()
                result = self.run_script(FAKE_UPLOAD_FAIL_AFTER='1')
                self.assertNotEqual(result.returncode, 0)
                self.assertIn('新的补丁版本', result.stdout)
                self.assert_no_mutation(before)

    def test_public_hash_mismatch_stops_without_mutation(self):
        self.seed(); state = self.load()
        state['overrides'] = {'App.zip': {'digest': 'sha256:' + '0' * 64}}; self.save(state)
        before = self.load()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_no_mutation(before)

    def test_public_without_digest_downloads_and_hashes_old_bytes(self):
        self.seed(); state = self.load()
        state['overrides'] = {'App.zip': {'digest': None}}; self.save(state)
        before = self.load()
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertTrue(any('App.zip' in call and call[:2] == ['release', 'download'] for call in self.load()['calls']))
        self.assert_no_mutation(before)

    def test_public_legacy_bytes_mismatch_is_detected(self):
        self.seed(); state = self.load()
        state['overrides'] = {'App.zip': {'digest': None}}; self.save(state)
        (self.root / 'remote/App.zip').write_bytes(b'bad app bytes')
        before = self.load()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_no_mutation(before)

    def test_public_overwrite_is_explicitly_rejected(self):
        self.seed(); before = self.load()
        result = self.run_script(OVERWRITE='true')
        self.assertNotEqual(result.returncode, 0)
        self.assertIn('不允许 overwrite', result.stdout)
        self.assert_no_mutation(before)

    def test_public_invalid_remote_state_and_checksums_are_rejected(self):
        for content in ('bad checksum', '0' * 64 + '  ../App.zip', '0' * 64 + '  App.zip\n' + '0' * 64 + '  App.zip'):
            with self.subTest(content=content):
                self.seed(); state = self.load(); state['calls'] = []; self.save(state)
                (self.root / 'remote/SHA256SUMS.txt').write_text(content)
                before = self.load()
                self.assertNotEqual(self.run_script().returncode, 0)
                self.assert_no_mutation(before)
        self.seed(); state = self.load(); state['calls'] = []
        state['overrides'] = {'App.zip': {'state': 'starter'}}; self.save(state)
        before = self.load()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_no_mutation(before)

    def test_partial_draft_failure_stays_hidden_and_retries(self):
        result = self.run_script(FAKE_UPLOAD_FAIL_AFTER='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.load()['status'], 'draft')
        self.assertEqual(self.load()['assets'], ['App.zip'])
        self.assertEqual((self.root / 'output').read_text(), '')
        result = self.run_script(OVERWRITE='true')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.load()['status'], 'published')
        self.assertEqual((self.root / 'output').read_text(), 'tag=v1.0.0\n')

    def test_new_draft_uses_response_id_with_real_tag_endpoint_404(self):
        self.seed('draft')
        probe = subprocess.run(['gh', 'api', 'repos/fixture/app/releases/tags/v1.0.0'],
                               cwd=self.app, env=self.env, capture_output=True, text=True)
        self.assertNotEqual(probe.returncode, 0)
        self.assertIn('HTTP 404', probe.stderr)
        state = self.load(); state['status'] = 'none'; state['calls'] = []; self.save(state)
        result = self.run_script()
        self.assertEqual(result.returncode, 0, result.stderr)
        calls = self.load()['calls']
        self.assertFalse(any('/releases/tags/' in ' '.join(call) for call in calls))
        self.assertTrue(any('/releases/411323629' in ' '.join(call) for call in calls))

    def test_draft_id_http_error_does_not_upload_or_recreate(self):
        result = self.run_script(FAKE_ID_QUERY_ERROR='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.load()['status'], 'draft')
        calls = self.load()['calls']
        self.assertEqual(sum('--method' in call and call[call.index('--method') + 1] == 'POST' for call in calls), 1)
        self.assertFalse(any(call[:2] == ['release', 'upload'] for call in calls))
        self.assertEqual((self.root / 'output').read_text(), '')

    def test_draft_snapshot_id_mismatch_fails_closed(self):
        result = self.run_script(FAKE_QUERY_ID_MISMATCH='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.load()['status'], 'draft')
        self.assertFalse(any(call[:2] == ['release', 'upload'] for call in self.load()['calls']))

    def test_matching_release_on_later_page_is_found(self):
        self.seed(); before = self.load()
        result = self.run_script(FAKE_LATER_PAGE='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_mutation(before)

    def test_duplicate_tag_across_list_is_rejected(self):
        self.seed('draft'); before = self.load()
        result = self.run_script(FAKE_DUPLICATE_TAG='1')
        self.assertNotEqual(result.returncode, 0)
        self.assert_no_mutation(before)

    def test_draft_remote_checksums_must_be_this_upload(self):
        self.seed('draft')
        result = self.run_script(FAKE_REMOTE_SUMS_CHANGED='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.load()['status'], 'draft')
        self.assertEqual((self.root / 'output').read_text(), '')

    def test_draft_unbound_leftover_asset_is_not_published(self):
        self.seed('draft'); state = self.load()
        state['assets'].append('old.zip'); self.save(state)
        (self.root / 'remote/old.zip').write_bytes(b'old draft bytes')
        result = self.run_script()
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.load()['status'], 'draft')
        self.assertEqual((self.root / 'output').read_text(), '')

    def test_bad_local_hash_stops_before_tag_and_release_changes(self):
        self.git('push', '-q', 'origin', ':refs/tags/v1.0.0')
        (self.app / 'dist/App.zip').write_bytes(b'bad local bytes')
        before = self.load()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_no_mutation(before)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/v1.0.0').stdout, '')

    def test_query_error_does_not_trigger_upload_or_create(self):
        before = self.load()
        self.assertNotEqual(self.run_script(FAKE_QUERY_ERROR='1').returncode, 0)
        self.assert_no_mutation(before)

    def test_pagination_error_does_not_modify_release(self):
        before = self.load()
        self.assertNotEqual(self.run_script(FAKE_LIST_ERROR='1').returncode, 0)
        self.assert_no_mutation(before)

    def test_partial_pagination_output_is_not_accepted(self):
        before = self.load()
        self.assertNotEqual(self.run_script(FAKE_LIST_ERROR='partial').returncode, 0)
        self.assert_no_mutation(before)

    def test_latest_is_rechecked_after_upload(self):
        result = self.run_script(FAKE_NEWER_AFTER_UPLOAD='1')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.load()['latest'], 'false')
        self.assertEqual(self.load()['list_count'], 3)

    def test_final_latest_error_keeps_draft(self):
        result = self.run_script(FAKE_FINAL_LIST_ERROR='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(self.load()['status'], 'draft')
        self.assertEqual((self.root / 'output').read_text(), '')

    def test_public_missing_tag_is_not_reattached(self):
        self.seed()
        self.git('push', '-q', 'origin', ':refs/tags/v1.0.0')
        before = self.load()
        self.assertNotEqual(self.run_script().returncode, 0)
        self.assert_no_mutation(before)
        self.assertEqual(self.git('ls-remote', 'origin', 'refs/tags/v1.0.0').stdout, '')

    def test_tag_commit_mismatch_preserves_draft(self):
        self.seed('draft'); self.git('commit', '-q', '--allow-empty', '-m', 'other commit')
        before = self.load()
        result = self.run_script(SHA=self.git('rev-parse', 'HEAD').stdout.strip())
        self.assertEqual(result.returncode, 0)
        self.assert_no_mutation(before)

    def test_external_publish_is_detected_before_upload(self):
        self.seed('draft')
        result = self.run_script(FAKE_PUBLISHED_BEFORE_UPLOAD='1')
        self.assertNotEqual(result.returncode, 0)
        self.assertFalse(any(call[:2] == ['release', 'upload'] for call in self.load()['calls']))
        self.assertEqual(self.load()['status'], 'published')
        self.assertEqual((self.root / 'output').read_text(), '')

    def test_plan_rejects_public_missing_or_mismatched_assets(self):
        self.seed(); state = self.load()
        state['overrides'] = {'App.zip': {'digest': 'sha256:' + '0' * 64}}; self.save(state)
        before = self.load()
        self.assertNotEqual(self.run_script('plan.sh').returncode, 0)
        self.assert_no_mutation(before)

    def test_plan_complete_is_read_only(self):
        self.seed(); before = self.load()
        result = self.run_script('plan.sh')
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assert_no_mutation(before)


class FixtureIsolationTests(unittest.TestCase):
    def test_consecutive_ci_steps_do_not_leak_file_commands(self):
        with tempfile.TemporaryDirectory(prefix='frit-ci-file-commands-') as directory:
            root = Path(directory)
            env = dict(os.environ)
            env.update(RELEASE_ASSETS='dist/Production.zip', EXTRA_ASSETS='dist/Production-plugin.zip',
                       TAG='v99.0.0', PRERELEASE='true', OVERWRITE='true')
            channels = ('GITHUB_OUTPUT', 'GITHUB_ENV', 'GITHUB_PATH', 'GITHUB_STEP_SUMMARY', 'GITHUB_STATE')
            for channel in channels:
                path = root / channel.lower()
                path.write_bytes(b'')
                env[channel] = str(path)
            first = subprocess.run([sys.executable, '-m', 'unittest',
                                    'test_release_integrity.ReleaseIntegrityTests.test_partial_draft_failure_stays_hidden_and_retries'],
                                   cwd=RELEASE.parents[1] / 'Tests/release', env=env, capture_output=True, text=True)
            self.assertEqual(first.returncode, 0, first.stdout + first.stderr)
            for channel in channels:
                self.assertEqual(Path(env[channel]).read_bytes(), b'', channel + ' 被 Python fixture 污染')
            second = subprocess.run(['bash', str(RELEASE.parents[1] / 'Tests/release/test-publish.sh')],
                                    cwd=RELEASE.parents[1], env=env, capture_output=True, text=True)
            self.assertEqual(second.returncode, 0, second.stdout + second.stderr)
            for channel in channels:
                self.assertEqual(Path(env[channel]).read_bytes(), b'', channel + ' 被后续发布脚本 fixture 污染')


if __name__ == '__main__':
    unittest.main()
