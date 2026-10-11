#!/bin/bash
# 公证完成后复制归档别名，校验附件清单并生成校验和与机器可读输出。
set -euo pipefail
python3 - <<'PY'
import hashlib
import json
import os
from pathlib import Path
import re
import shutil


def fail(message):
    raise SystemExit('::error::' + message)


def paths(value):
    return value.split()


archives = paths(os.environ.get('ARCHIVES', ''))
extras = paths(os.environ.get('EXTRA_ASSETS', ''))
if not archives:
    fail('archives 不能为空')
items = archives + extras
root = Path(archives[0]).resolve().parent
seen = set()
for item in items:
    path = Path(item)
    if not re.fullmatch(r'[A-Za-z0-9_./+-]+', item) or not path.is_file():
        fail('附件不存在或路径含不支持的字符：' + item)
    if path.resolve().parent != root:
        fail('所有附件必须和 archives 在同一个文件夹里：' + item)
    if path.name in seen or path.name in ('SHA256SUMS.txt', 'release-assets.json'):
        fail('附件名称重复或占用了输出文件名：' + path.name)
    seen.add(path.name)

copies = []
for mapping in paths(os.environ.get('ASSET_ALIASES', '')):
    if mapping.count('=') != 1:
        fail('别名格式应为 源归档=目标路径：' + mapping)
    source, target = mapping.split('=')
    if source not in archives:
        fail('别名来源必须在 archives 中：' + source)
    destination = Path(target)
    if not re.fullmatch(r'[A-Za-z0-9_./+-]+', target) or not target.endswith('.zip'):
        fail('别名目标必须是 zip，路径不能包含空格或特殊字符：' + target)
    if destination.resolve().parent != root or destination.name in seen or destination.exists():
        fail('别名目标重复、已存在或不在归档目录：' + target)
    seen.add(destination.name)
    copies.append((source, target))
# 全部验证通过才复制；来源是公证后重新打包的归档。
for source, target in copies:
    shutil.copyfile(source, target)
    items.append(target)

assets = []
for item in items:
    digest = hashlib.sha256()
    with open(item, 'rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    assets.append({'name': Path(item).name, 'sha256': digest.hexdigest()})
(root / 'SHA256SUMS.txt').write_text(''.join(a['sha256'] + '  ' + a['name'] + '\n' for a in assets))
manifest = json.dumps(assets, ensure_ascii=False, separators=(',', ':'))
(root / 'release-assets.json').write_text(manifest + '\n')
if os.environ.get('GITHUB_ENV'):
    with open(os.environ['GITHUB_ENV'], 'a') as stream:
        stream.write('RELEASE_ASSETS=' + ' '.join(items) + '\n')
        stream.write('ASSET_MANIFEST=' + str(root / 'release-assets.json') + '\n')
if os.environ.get('GITHUB_OUTPUT'):
    with open(os.environ['GITHUB_OUTPUT'], 'a') as stream:
        stream.write('assets=' + manifest + '\n')
        stream.write('paths<<FRIT_ASSET_PATHS\n' + '\n'.join(items) + '\nFRIT_ASSET_PATHS\n')
print(manifest)
PY
