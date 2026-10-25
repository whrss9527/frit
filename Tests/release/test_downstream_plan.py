"""真实临时Git检出验证发现只读、完整来源与原生runner选择。"""
import importlib.util
from pathlib import Path
import subprocess
import shutil
import tempfile
import unittest

spec = importlib.util.spec_from_file_location('downstream_plan', Path(__file__).resolve().parents[2] / 'scripts/downstream/plan.py')
plan = importlib.util.module_from_spec(spec)
spec.loader.exec_module(plan)


class DownstreamPlanTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name)
        self.shas = {}
        for app in plan.APPS:
            root = self.root / app
            root.mkdir()
            subprocess.run(['git', 'init', '-q', str(root)], check=True)
            (root / 'Package.swift').write_text('let package = Package(name: "Fixture")\n')
            self.commit(app)

    def commit(self, app):
        root = self.root / app
        subprocess.run(['git','-C',str(root),'add','.'], check=True)
        subprocess.run(['git','-C',str(root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                        'commit','-qm','fixture'], check=True)
        self.shas[app] = subprocess.check_output(['git','-C',str(root),'rev-parse','HEAD'], text=True).strip()

    def test_only_declared_dependencies_allocate_a_mac_and_keep_exact_sources(self):
        (self.root/'meno/Package.swift').write_text('let p = [.package(url: "https://github.com/whrss9527/Frit.git", from: "0.4.1")]\n')
        (self.root/'stox/project.yml').write_text('packages:\n  Frit:\n    url: https://github.com/whrss9527/frit\n    from: 0.4.1\n')
        self.commit('meno'); self.commit('stox')
        original = {p:p.read_bytes() for app in plan.APPS for p in (self.root/app).glob('*') if p.is_file()}
        rows = plan.discover(self.root, 'a'*40)['include']
        self.assertEqual([r['app'] for r in rows], list(plan.APPS))
        for row in rows:
            self.assertEqual(row['sha'], self.shas[row['app']])
            self.assertEqual(row['active'], row['app'] in ('meno','stox'))
            self.assertEqual(row['runner'], 'macos-15' if row['active'] else 'ubuntu-latest')
        self.assertTrue(all(p.read_bytes()==value for p,value in original.items()))
        for app in plan.APPS:
            self.assertEqual(subprocess.check_output(['git','-C',str(self.root/app),'status','--porcelain'],text=True),'')

    def test_unintegrated_apps_are_explicit_linux_rows(self):
        rows = plan.discover(self.root,'b'*40)['include']
        self.assertEqual(len(rows),4)
        self.assertTrue(all(not row['active'] and row['runner']=='ubuntu-latest' for row in rows))

    def test_invalid_declared_dependency_stops_discovery(self):
        (self.root/'meno/Package.swift').write_text('.package(url: "https://github.com/whrss9527/frit", revision: "main"')
        self.commit('meno')
        with self.assertRaises(ValueError): plan.discover(self.root,'c'*40)

    def test_missing_checkout_and_manifest_are_not_classed_as_inactive(self):
        (self.root/'pop/Package.swift').unlink()
        self.commit('pop')
        with self.assertRaises(ValueError): plan.discover(self.root,'d'*40)
        with self.assertRaises(subprocess.SubprocessError): plan.discover(self.root/'missing','d'*40)

    def test_invalid_frit_revision_is_rejected(self):
        with self.assertRaises(ValueError): plan.discover(self.root,'main')

    def test_working_tree_changes_cannot_drift_the_committed_source_plan(self):
        file = self.root/'meno/Package.swift'
        changed = '.package(url: "https://github.com/whrss9527/frit", from: "0.4.1")'
        file.write_text(changed)
        rows = plan.discover(self.root,'e'*40)['include']
        self.assertFalse(next(row for row in rows if row['app']=='meno')['active'])
        self.assertEqual(file.read_text(), changed)

    def test_nested_directory_cannot_inherit_the_parent_repository_source(self):
        subprocess.run(['git','init','-q',str(self.root)],check=True)
        marker = self.root/'marker';marker.write_text('parent')
        subprocess.run(['git','-C',str(self.root),'add','marker'],check=True)
        subprocess.run(['git','-C',str(self.root),'-c','user.name=Fixture','-c','user.email=fixture@example.invalid',
                        'commit','-qm','parent'],check=True)
        shutil.rmtree(self.root/'pop/.git')
        with self.assertRaises(ValueError): plan.discover(self.root,'f'*40)
