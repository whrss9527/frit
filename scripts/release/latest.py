#!/usr/bin/env python3
"""决定正式版能否标成 latest；输入为 GitHub Releases 列表或 --paginate --slurp 的分页数组。"""

import json
import re
import sys


def stable_version(tag):
    """按数字比较正式版，兼容 v 前缀、缺省的零段和不参与比较的构建信息。"""
    if not isinstance(tag, str):
        raise ValueError("版本标签必须是字符串")
    match = re.fullmatch(r"[vV]?([0-9]+(?:\.[0-9]+)*)(?:\+[0-9A-Za-z.-]+)?", tag)
    if not match:
        raise ValueError(f"无法比较正式版标签：{tag!r}，请核对发布列表")
    parts = [int(part) for part in match[1].split(".")]
    while parts and parts[-1] == 0:
        parts.pop()
    return tuple(parts)


def should_mark_latest(tag, payload):
    candidate = stable_version(tag)
    if not isinstance(payload, list):
        raise ValueError("发布列表必须是数组")
    releases = []
    for entry in payload:
        releases.extend(entry if isinstance(entry, list) else [entry])

    # 全部校验后再做决定，不能因为第一页已有新版就掩盖后面的错误输入。
    versions = []
    for release in releases:
        if not isinstance(release, dict):
            raise ValueError("发布条目必须是对象")
        if any(type(release.get(field)) is not bool for field in ("draft", "prerelease")):
            raise ValueError("发布条目缺少有效的 draft/prerelease 标记")
        if release["draft"] or release["prerelease"]:
            continue
        version = stable_version(release.get("tag_name"))
        # 重新打包当前最新版时保留 latest；不同标签的同号版本不抢占。
        if release["tag_name"] != tag:
            versions.append(version)
    return all(candidate > version for version in versions)


def main():
    if len(sys.argv) != 2:
        raise ValueError("用法：latest.py <正式版标签> < releases.json")
    result = should_mark_latest(sys.argv[1], json.load(sys.stdin))
    print("true" if result else "false")


if __name__ == "__main__":
    try:
        main()
    except (ValueError, TypeError) as error:
        print(f"latest 检查失败：{error}", file=sys.stderr)
        sys.exit(1)
