#!/usr/bin/env python3
"""只读发现四App的Frit依赖与精确源码，让未接入列留在Linux。"""
import importlib.util
import json
from pathlib import Path
import re
import subprocess
import sys

spec = importlib.util.spec_from_file_location('frit_downstream_pin', Path(__file__).with_name('pin.py'))
pin = importlib.util.module_from_spec(spec)
spec.loader.exec_module(pin)
APPS = ('stox', 'pop', 'proxi', 'meno')
SHA = re.compile(r'[0-9a-f]{40}')


def discover(checkouts, revision):
    if not SHA.fullmatch(revision): raise ValueError('Frit需要完整提交SHA')
    rows = []
    for app in APPS:
        root = (checkouts / app).resolve()
        top = subprocess.check_output(['git', '-C', str(root), 'rev-parse', '--show-toplevel'], text=True).strip()
        if Path(top).resolve() != root: raise ValueError(app + '缺少独立检出')
        source = subprocess.check_output(['git', '-C', str(root), 'rev-parse', 'HEAD'], text=True).strip()
        if not SHA.fullmatch(source): raise ValueError(app + '源码SHA无效')
        tracked = set(subprocess.check_output(['git', '-C', str(root), 'ls-tree', '--name-only', source, '--',
                                               'Package.swift', 'project.yml'], text=True).splitlines())
        active = found_manifest = False
        for name, parse in [('Package.swift', pin.pin_swift), ('project.yml', pin.pin_project)]:
            if name in tracked:
                found_manifest = True
                original = subprocess.check_output(['git', '-C', str(root), 'show', source + ':' + name], text=True)
                _, found = parse(original, revision)
                active = active or found
        if not found_manifest: raise ValueError(app + '缺少已支持的工程声明')
        rows.append(dict(app=app, sha=source, active=active, runner='macos-15' if active else 'ubuntu-latest'))
    return dict(include=rows)


if __name__ == '__main__':
    try:
        print(json.dumps(discover(Path(sys.argv[1]), sys.argv[2]), separators=(',', ':')))
    except (ValueError, OSError, IndexError, subprocess.SubprocessError) as error:
        sys.exit('下游发现失败：' + str(error))
