#!/usr/bin/env python3
"""仅在已有 Frit 依赖时，将 CI 临时 checkout 的声明固定到本次提交。"""
import argparse
import json
from pathlib import Path
import re

FRIT_URL = re.compile(r"https://github\.com/whrss9527/frit(?:\.git)?/?", re.I)
TOKENS = re.compile(r'//[^\n]*|/\*.*?\*/|"(?:\\.|[^"\\])*"|\bpackage\b|[()]', re.S)


def pin_swift(source, revision):
    tokens = list(TOKENS.finditer(source))
    edits = []
    for index, token in enumerate(tokens):
        if token.group() != "package" or source[token.start() - 1:token.start()] != ".":
            continue
        if index + 1 == len(tokens) or tokens[index + 1].group() != "(":
            continue
        depth = 0
        url = None
        for current in tokens[index + 1:]:
            text = current.group()
            if text == "(": depth += 1
            elif text == ")":
                depth -= 1
                if depth == 0:
                    if url:
                        edits.append((token.start() - 1, current.end(), '.package(url: ' + json.dumps(url) + ', revision: ' + json.dumps(revision) + ')'))
                    break
            elif text.startswith('"'):
                try: value = json.loads(text)
                except json.JSONDecodeError: continue
                if FRIT_URL.fullmatch(value): url = value
        else:
            raise ValueError("Swift package 声明没有闭合")
    if len(edits) > 1: raise ValueError("发现多个 Frit package 声明，停止修改")
    for start, end, text in reversed(edits): source = source[:start] + text + source[end:]
    return source, bool(edits)


def pin_project(source, revision):
    lines = source.splitlines(keepends=True)
    in_packages = False
    start = end = None
    for index, line in enumerate(lines):
        if re.fullmatch(r"packages:\s*\n?", line): in_packages = True; continue
        if in_packages and line and not line[0].isspace() and line.strip() and not line.startswith("#"):
            in_packages = False
        if in_packages and re.match(r"^  [\w-]+:\s*$", line):
            stop = index + 1
            while stop < len(lines) and (lines[stop].startswith("    ") or not lines[stop].strip()): stop += 1
            block = "".join(lines[index:stop])
            if any(FRIT_URL.fullmatch(value.strip(" '\"\n")) for value in re.findall(r"^    url:\s*(.+)$", block, re.M)):
                if start is not None: raise ValueError("发现多个 Frit XcodeGen package 声明")
                start, end = index, stop
    if start is None: return source, False
    block = [line for line in lines[start:end] if not re.match(r"^    (from|revision|branch|exactVersion|version|majorVersion|minorVersion|minimumVersion|maximumVersion|upToNextMajorVersion|upToNextMinorVersion):", line)]
    block.append('    revision: "' + revision + '"\n')
    return "".join(lines[:start] + block + lines[end:]), True


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument("checkout", type=Path)
    parser.add_argument("revision")
    args = parser.parse_args()
    if not re.fullmatch(r"[0-9a-f]{40}", args.revision): raise SystemExit("需要完整的小写提交 SHA")
    manifest = args.checkout / "Package.swift"
    project = args.checkout / "project.yml"
    active = False
    for path, pin in [(manifest, pin_swift), (project, pin_project)]:
        if path.exists():
            original = path.read_text()
            updated, found = pin(original, args.revision)
            if found: path.write_text(updated)
            active = active or found
    print("active=" + str(active).lower())


if __name__ == "__main__": main()
