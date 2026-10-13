#!/usr/bin/env python3
"""核对发行资产与校验和；公开发行只读，草稿公开前核对本次上传。"""
import hashlib
import json
from pathlib import Path
import re
import subprocess
import sys
import tempfile


def fail(message):
    raise ValueError(message)


def sha256(path):
    digest = hashlib.sha256()
    with path.open('rb') as stream:
        for chunk in iter(lambda: stream.read(1024 * 1024), b''):
            digest.update(chunk)
    return digest.hexdigest()


def names(paths):
    result = [Path(path).name for path in paths.split()]
    if not result or len(result) != len(set(result)):
        fail('发行附件清单为空或名称重复')
    if any(not re.fullmatch(r'[A-Za-z0-9_.+-]+', name) or name in ('.', '..', 'SHA256SUMS.txt') for name in result):
        fail('发行附件名称无效或占用了校验和文件名')
    return result


def checksums(path):
    result = {}
    for line in path.read_text(encoding='utf-8').splitlines():
        if not line.strip():
            continue
        match = re.fullmatch(r'([0-9A-Fa-f]{64})\s+\*?([A-Za-z0-9_.+-]+)', line)
        if not match or match[2] in ('.', '..', 'SHA256SUMS.txt') or match[2] in result:
            fail('SHA256SUMS.txt 含无效或重复的附件条目')
        result[match[2]] = match[1].lower()
    if not result:
        fail('SHA256SUMS.txt 没有附件校验和')
    return result


def snapshot(tag, path):
    value = json.loads(path.read_text())
    if not isinstance(value, dict) or value.get('tag_name') != tag or type(value.get('id')) is not int or value['id'] <= 0 or type(value.get('draft')) is not bool or not isinstance(value.get('assets'), list):
        fail('发行状态或标签无效，停止发布')
    return value


def pages(path):
    text = path.read_text()
    decoder = json.JSONDecoder()
    result = []
    index = 0
    while index < len(text):
        if text[index].isspace():
            index += 1
            continue
        value, index = decoder.raw_decode(text, index)
        if not isinstance(value, list):
            fail('发行分页列表格式无效')
        if value and all(isinstance(item, list) for item in value):
            result.extend(value)
        else:
            result.append(value)
    if not result:
        fail('没有取得发行分页列表')
    return result


def select(tag, path):
    matches = []
    for page in pages(path):
        for item in page:
            if not isinstance(item, dict) or not isinstance(item.get('tag_name'), str) or type(item.get('id')) is not int or item['id'] <= 0 or type(item.get('draft')) is not bool:
                fail('发行分页条目格式无效')
            if item['tag_name'] == tag:
                matches.append(item)
    if not matches:
        sys.exit(3)
    if len(matches) != 1:
        fail('同一标签存在多个发行，停止自动恢复')
    print(matches[0]['id'])


def assets(value):
    result = {}
    for asset in value['assets']:
        if not isinstance(asset, dict) or not isinstance(asset.get('name'), str) or asset['name'] in result:
            fail('远端发行附件信息无效或名称重复')
        result[asset['name']] = asset
    return result


def download(tag, name, directory, asset):
    # 文件名已由本地清单或校验和解析限制，不接受下载 glob 或路径穿越。
    subprocess.run(['gh', 'release', 'download', tag, '--pattern', name, '--dir', str(directory)], check=True)
    path = directory / name
    if not path.is_file() or path.stat().st_size != asset['size']:
        fail('远端附件下载大小不符：' + name)
    return path


def digest(asset):
    value = asset.get('digest')
    if value is None:
        return None
    if not isinstance(value, str) or not re.fullmatch(r'sha256:[0-9A-Fa-f]{64}', value):
        fail('远端附件摘要无效：' + asset['name'])
    return value[7:].lower()


def verify(tag, value, expected, local=None):
    remote = assets(value)
    required = set(expected) | {'SHA256SUMS.txt'}
    if required - remote.keys():
        fail('远端发行缺少附件：' + ', '.join(sorted(required - remote.keys())))
    if local and remote.keys() != required:
        fail('草稿含本次清单之外的附件，停止公开')
    with tempfile.TemporaryDirectory(prefix='frit-release-check-') as directory:
        root = Path(directory)
        for name in required:
            item = remote[name]
            if item.get('state') != 'uploaded' or type(item.get('size')) is not int or item['size'] <= 0:
                fail('远端附件未完整上传：' + name)
        sums = download(tag, 'SHA256SUMS.txt', root, remote['SHA256SUMS.txt'])
        declared = digest(remote['SHA256SUMS.txt'])
        if declared and sha256(sums) != declared:
            fail('远端校验和文件摘要不符')
        if local and sha256(sums) != sha256(local):
            fail('草稿校验和文件不是本次上传的内容')
        hashes = checksums(sums)
        if set(expected) - hashes.keys():
            fail('SHA256SUMS.txt 缺少要求的附件条目')
        # 校验和列出的额外附件也必须完整，防止遗漏插件或历史别名。
        for name, expected_hash in hashes.items():
            item = remote.get(name)
            if not item or item.get('state') != 'uploaded' or type(item.get('size')) is not int or item['size'] <= 0:
                fail('校验和对应的远端附件未完整上传：' + name)
            actual = digest(item)
            if actual is None:
                actual = sha256(download(tag, name, root, item))
            if actual != expected_hash:
                fail('远端附件与公开校验和不一致：' + name)


def main():
    mode = sys.argv[1]
    if mode == 'pages':
        print(json.dumps(pages(Path(sys.argv[2]))))
        return
    if mode == 'select':
        select(sys.argv[2], Path(sys.argv[3]))
        return
    if mode == 'local':
        paths = sys.argv[2].split()
        expected = names(sys.argv[2])
        hashes = checksums(Path(sys.argv[3]))
        if set(expected) != hashes.keys():
            fail('本次附件清单与 SHA256SUMS.txt 不一致')
        for path, name in zip(paths, expected):
            file = Path(path)
            if not file.is_file() or file.stat().st_size <= 0 or sha256(file) != hashes[name]:
                fail('本次附件与校验和不一致：' + name)
        return
    tag, path = sys.argv[2], Path(sys.argv[3])
    value = snapshot(tag, path)
    if mode == 'id':
        print(value['id'])
        return
    if mode == 'state':
        if len(sys.argv) > 4 and str(value['id']) != sys.argv[4]:
            fail('发行 ID 与查询对象不符')
        print('draft' if value['draft'] else 'published')
        return
    expected = names(sys.argv[4])
    if mode == 'published' and value['draft']:
        fail('发行仍是草稿')
    if mode == 'draft' and not value['draft']:
        fail('发行已被公开，停止覆盖附件')
    verify(tag, value, expected, Path(sys.argv[5]) if mode == 'draft' else None)


if __name__ == '__main__':
    try:
        main()
    except (ValueError, OSError, subprocess.CalledProcessError, IndexError) as error:
        print('::error::发行核验失败：' + str(error), file=sys.stderr)
        sys.exit(1)
