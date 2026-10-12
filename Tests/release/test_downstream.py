import importlib.util
from pathlib import Path
import unittest

path = Path(__file__).resolve().parents[2] / "scripts/downstream/pin.py"
spec = importlib.util.spec_from_file_location("pin", path)
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)


class DownstreamPinTests(unittest.TestCase):
    def test_current_meno_revision_and_version_rules_are_replaced(self):
        for argument in ['revision: "old"', 'from: "0.1.0"', '.upToNextMinor(from: "0.1.0")']:
            source = '.package(url: "https://github.com/whrss9527/Frit", ' + argument + '),\n.package(url: "https://example.com/other", from: "1.0.0")'
            updated, active = pin.pin_swift(source, "a" * 40)
            self.assertTrue(active)
            self.assertIn('revision: "' + "a" * 40 + '"', updated)
            self.assertIn('.package(url: "https://example.com/other", from: "1.0.0")', updated)

    def test_comments_and_unrelated_packages_do_not_activate(self):
        source = '// .package(url: "https://github.com/whrss9527/frit", from: "0.1.0")\nlet text = "package"\n.package(url: "https://example.com/frit", from: "1.0.0")'
        self.assertEqual(pin.pin_swift(source, "b" * 40), (source, False))

    def test_duplicate_and_unclosed_declarations_fail(self):
        package = '.package(url: "https://github.com/whrss9527/frit.git", from: "0.1.0")'
        with self.assertRaises(ValueError): pin.pin_swift(package + package, "c" * 40)
        with self.assertRaises(ValueError): pin.pin_swift(package[:-1], "c" * 40)

    def test_pop_project_changes_only_frit_package(self):
        source = 'name: Pop\npackages:\n  Other:\n    url: https://example.com/other\n    from: 1.0.0\n  Frit:\n    url: https://github.com/whrss9527/Frit.git\n    from: 0.1.0\ntargets:\n  Pop:\n    type: application\n'
        updated, active = pin.pin_project(source, "d" * 40)
        self.assertTrue(active)
        self.assertIn('    revision: "' + "d" * 40 + '"', updated)
        self.assertIn('    from: 1.0.0', updated)
        self.assertNotIn('from: 0.1.0', updated)
        self.assertIn('targets:\n  Pop:\n    type: application', updated)

    def test_non_adopter_is_unchanged(self):
        source = 'name: Pop\ntargets:\n  Pop:\n    type: application\n'
        self.assertEqual(pin.pin_project(source, "e" * 40), (source, False))
