#!/usr/bin/env python3
"""从唯一文案源 xcstrings 生成 SwiftPM 命令行可直接使用的 strings。"""
import argparse
import json
from pathlib import Path
import re

parser = argparse.ArgumentParser()
parser.add_argument("--check", action="store_true")
args = parser.parse_args()
root = Path(__file__).resolve().parents[1]
resources = root / "Sources/FritUpdate/Resources"
catalog = json.loads((resources / "Localizable.xcstrings").read_text())
source_keys = set()
for source in (root / "Sources/FritUpdate").glob("*.swift"):
    source_keys.update(re.findall(r'updateText\("([^"\n]*)"', source.read_text()))
if source_keys != set(catalog["strings"]):
    raise SystemExit("文案键不一致：" + repr(source_keys ^ set(catalog["strings"])))
for language in ["zh-Hans", "zh-Hant", "en"]:
    lines = []
    for key, entry in sorted(catalog["strings"].items()):
        unit = entry["localizations"][language]["stringUnit"]
        if unit["state"] != "translated":
            raise SystemExit("译文未完成：" + key)
        value = unit["value"]
        if re.findall(r"%(?:@|lld)", key) != re.findall(r"%(?:@|lld)", value):
            raise SystemExit("占位符不一致：" + key)
        lines.append(json.dumps(key, ensure_ascii=False) + " = " + json.dumps(value, ensure_ascii=False) + ";")
    output = "// 自动生成；修改 Localizable.xcstrings 后运行 scripts/generate-localizations.py。\n" + "\n".join(lines) + "\n"
    path = resources / (language + ".lproj") / "Localizable.strings"
    if args.check:
        if not path.exists() or path.read_text() != output:
            raise SystemExit("语言资源需要重新生成：" + str(path))
    else:
        path.parent.mkdir(parents=True, exist_ok=True)
        path.write_text(output)
print("简体、繁体和英文资源及占位符已核对")
