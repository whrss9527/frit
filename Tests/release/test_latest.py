"""重新打包旧版本不能让应用的 latest 更新入口倒退。"""

import importlib.util
import json
from pathlib import Path
import subprocess
import sys
import unittest

SCRIPT = Path(__file__).resolve().parents[2] / "scripts/release/latest.py"
SPEC = importlib.util.spec_from_file_location("release_latest", SCRIPT)
LATEST = importlib.util.module_from_spec(SPEC)
SPEC.loader.exec_module(LATEST)


def release(tag, **flags):
    return dict(tag_name=tag, draft=False, prerelease=False, **flags)


class LatestTests(unittest.TestCase):
    def test_first_release_and_numeric_version_order(self):
        self.assertTrue(LATEST.should_mark_latest("v0.1.0", []))
        self.assertTrue(LATEST.should_mark_latest("v1.10.0", [release("v1.9.0")]))
        self.assertFalse(LATEST.should_mark_latest("v1.9.0", [release("v1.10.0")]))

    def test_overwrite_old_version_does_not_replace_latest(self):
        # 旧版刚重打包，时间和列表顺序可能比最新版本还靠前。
        releases = [release("v1.0.0"), release("v2.0.0"), release("v1.9.0")]
        self.assertFalse(LATEST.should_mark_latest("v1.0.0", releases))
        self.assertTrue(LATEST.should_mark_latest("v2.0.0", releases))

    def test_prereleases_and_drafts_do_not_block_stable(self):
        releases = [dict(tag_name="v9.0.0-beta.1", draft=False, prerelease=True),
                    dict(tag_name="v10.0.0", draft=True, prerelease=False), release("v1.0.0")]
        self.assertTrue(LATEST.should_mark_latest("v2.0.0", releases))

    def test_all_pages_are_compared(self):
        pages = [[release("v1.0.0")], [release("v3.0.0")], []]
        self.assertFalse(LATEST.should_mark_latest("v2.0.0", pages))

    def test_equivalent_tags_do_not_steal_latest(self):
        for tag in ["v1.2", "1.2.0", "V1.2.0.0", "v1.2.0+rebuild.1"]:
            with self.subTest(tag=tag):
                self.assertFalse(LATEST.should_mark_latest(tag, [release("v1.2.0")]))
        self.assertTrue(LATEST.should_mark_latest("v1.2.1", [release("v1.2.0+build.9")]))

    def test_invalid_stable_tags_and_api_payload_fail_closed(self):
        for tag in ["nightly", "v1.0.0-beta.1", "v1..0", "", None]:
            with self.subTest(tag=tag), self.assertRaises(ValueError):
                LATEST.should_mark_latest(tag, [])
        for payload in [{"message": "API failure"}, [None], [{}], [release("nightly")],
                        [dict(tag_name="v1.0.0", draft="false", prerelease=False)],
                        [[release("v9.0.0")], [None]]]:
            with self.subTest(payload=payload), self.assertRaises(ValueError):
                LATEST.should_mark_latest("v2.0.0", payload)

    def test_command_output_is_suitable_for_gh_latest_flag(self):
        for versions, expected in [([], "true\n"), ([release("v3.0.0")], "false\n")]:
            result = subprocess.run([sys.executable, str(SCRIPT), "v2.0.0"],
                                    input=json.dumps(versions), text=True, capture_output=True)
            self.assertEqual(result.returncode, 0, result.stderr)
            self.assertEqual(result.stdout, expected)
        result = subprocess.run([sys.executable, str(SCRIPT), "v2.0.0"],
                                input="not JSON", text=True, capture_output=True)
        self.assertNotEqual(result.returncode, 0)
        self.assertEqual(result.stdout, "")


if __name__ == "__main__":
    unittest.main()
