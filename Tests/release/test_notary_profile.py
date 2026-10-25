"""在 macOS 真实验证 notarytool 的 stdin 密码录入，不验证虚构测试账号的服务器身份。"""
import os
from pathlib import Path
import subprocess
import tempfile
import unittest


@unittest.skipUnless(os.uname().sysname == "Darwin", "需要 macOS 钥匙串和 Xcode")
class NotaryProfileTests(unittest.TestCase):
    def test_store_password_from_stdin(self):
        with tempfile.TemporaryDirectory() as directory:
            keychain = str(Path(directory) / "test.keychain-db")
            subprocess.run(["security", "create-keychain", "-p", "test-only", keychain], check=True)
            try:
                subprocess.run(["security", "unlock-keychain", "-p", "test-only", keychain], check=True)
                # --no-validate 仅用于本测试的虚构账号；生产脚本存储时仍会验证身份。
                result = subprocess.run([
                    "xcrun", "notarytool", "store-credentials", "test-profile",
                    "--apple-id", "test@example.invalid", "--team-id", "ABCDE12345",
                    "--keychain", keychain, "--no-validate",
                ], input="aaaa-bbbb-cccc-dddd\n", capture_output=True, text=True, timeout=30)
                self.assertEqual(result.returncode, 0, result.stdout + result.stderr)
                self.assertNotIn("aaaa-bbbb-cccc-dddd", result.stdout + result.stderr)
            finally:
                subprocess.run(["security", "delete-keychain", keychain], check=True)


if __name__ == "__main__":
    unittest.main()
