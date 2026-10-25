#!/usr/bin/env python3
"""在 stapler validate 之后，核对根程序每个架构的 CDHash 都包含在票据中。"""
from pathlib import Path
import plistlib
import re
import subprocess
import sys


def check(app):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    executable = info["CFBundleExecutable"]
    if not isinstance(executable, str) or not executable or Path(executable).name != executable or executable in (".", ".."):
        raise ValueError("无效的 CFBundleExecutable")
    binary = app / "Contents/MacOS" / executable
    architectures = subprocess.check_output(["lipo", "-archs", str(binary)], text=True).split()
    if not architectures or len(set(architectures)) != len(architectures) or any(
        not re.fullmatch(r"[A-Za-z0-9_]+", arch) for arch in architectures
    ):
        raise ValueError("无法确认归档架构")
    ticket = (app / "Contents/CodeResources").read_bytes()
    if not ticket:
        raise ValueError("缺少公证票据")
    for arch in architectures:
        result = subprocess.run(["codesign", "--display", "--verbose=4", "--arch", arch, str(app)],
                                check=True, text=True, stdout=subprocess.PIPE, stderr=subprocess.STDOUT)
        hashes = re.findall(r"^CDHash=([0-9a-fA-F]{40})$", result.stdout, re.M)
        if len(hashes) != 1 or bytes.fromhex(hashes[0]) not in ticket:
            raise ValueError(f"{arch} 的 CDHash 未包含在已校验的票据中")
        print(f"{arch}：票据包含根程序 CDHash {hashes[0]}")


if __name__ == "__main__":
    try:
        if len(sys.argv) != 2:
            raise ValueError("用法：check-ticket.py 程序.app")
        check(Path(sys.argv[1]))
    except (OSError, ValueError, KeyError, TypeError, subprocess.SubprocessError) as error:
        sys.exit(f"公证票据核验失败：{error}")
