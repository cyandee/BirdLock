"""Assemble the unrun 1.9.0 Windows candidate from the verified 1.6.0 runtime.

This is a local maintenance fallback, not PyInstaller cross-compilation. It preserves
the Windows bootloader, native dependencies and third-party PYZ payloads, recompiles
every BirdLock module with the same Python bytecode version, and checks the result.
Normal Windows builds continue to use windows/build_windows.py.
"""
from __future__ import annotations

import argparse
import hashlib
import importlib.util
import json
import marshal
from pathlib import Path
import shutil
import struct
import subprocess
import sys
import tempfile
import zipfile
import zlib

import pefile
import PyInstaller
from PyInstaller.archive.readers import CArchiveReader
from PyInstaller.archive.writers import CArchiveWriter
from PyInstaller.building.utils import replace_filename_in_code_object

ROOT = Path(__file__).resolve().parents[1]
BASE_SHA256 = '628ccddf5214a1f9d8b1dc58a3c5608bc17bdee1279c98352211912f00fed1e4'


def digest(path):
    h = hashlib.sha256()
    with Path(path).open('rb') as stream:
        for block in iter(lambda: stream.read(1 << 20), b''): h.update(block)
    return h.hexdigest()


def make_pyz(old_data, reader, sources):
    if old_data[:8] != b'PYZ\0' + importlib.util.MAGIC_NUMBER:
        raise ValueError('Base PYZ bytecode is not compatible with this Python')
    payload = bytearray(old_data[:17]); toc = []
    for name in sorted(set(reader.toc) | set(sources)):
        if name in sources:
            path = sources[name]
            filename = '\\'.join(path.relative_to(ROOT / 'windows').parts)
            code = replace_filename_in_code_object(compile(path.read_bytes(), filename, 'exec', optimize=0), filename)
            data = zlib.compress(marshal.dumps(code), 6)
            kind = 1 if path.name == '__init__.py' else 0
        else:
            kind, offset, length = reader.toc[name]
            data = old_data[offset:offset+length]
        toc.append((name, (kind, len(payload), len(data))))
        payload.extend(data)
    offset = len(payload); payload.extend(marshal.dumps(toc)); payload[8:12] = struct.pack('!i', offset)
    return bytes(payload)


def make_executable(base_path, pyz_data, launcher):
    original = base_path.read_bytes(); reader = CArchiveReader(str(base_path))
    cookie = struct.unpack(reader._COOKIE_FORMAT, original[reader._end_offset-reader._COOKIE_LENGTH:reader._end_offset])
    if cookie[4] != 312 or cookie[5].rstrip(b'\0') != b'python312.dll': raise ValueError('Unexpected base Python runtime')
    prefix = bytearray(original[:reader._start_offset]); pe = pefile.PE(data=bytes(prefix))
    if pe.FILE_HEADER.Machine != 0x8664 or pe.OPTIONAL_HEADER.DATA_DIRECTORY[4].VirtualAddress:
        raise ValueError('Expected the unsigned x64 local test bootloader')
    old_text = '1.6.0'.encode('utf-16le'); new_text = '1.9.0'.encode('utf-16le')
    if prefix.count(old_text) != 2: raise ValueError('Unexpected version resource layout')
    prefix = prefix.replace(old_text, new_text)
    fixed = pe.VS_FIXEDFILEINFO[0]
    for field in ('FileVersionMS', 'ProductVersionMS'):
        offset = fixed.get_field_absolute_offset(field)
        prefix[offset:offset+4] = struct.pack('<I', (1 << 16) | 9)
    for field in ('FileVersionLS', 'ProductVersionLS'):
        offset = fixed.get_field_absolute_offset(field); prefix[offset:offset+4] = struct.pack('<I', 0)
    data = bytearray(); toc = []
    for name, (offset, length, unpacked, compressed, kind) in reader.toc.items():
        blob = original[reader._start_offset+offset:reader._start_offset+offset+length]
        if name == 'PYZ.pyz':
            blob = pyz_data; unpacked = len(blob); compressed = 0
        elif name == 'BirdLock':
            code = compile(launcher.read_bytes(), 'BirdLock.pyw', 'exec', optimize=0)
            raw = marshal.dumps(code); compressed = 1; unpacked = len(raw); blob = zlib.compress(raw, 6)
        toc.append((len(data), len(blob), unpacked, compressed, kind, name)); data.extend(blob)
    for option in reader.options: toc.append((0, 0, 0, 0, 'o', option))
    offset = len(data); table = CArchiveWriter._serialize_toc(toc); data.extend(table)
    data.extend(struct.pack(reader._COOKIE_FORMAT, cookie[0], len(data)+reader._COOKIE_LENGTH, offset, len(table), cookie[4], cookie[5]))
    result = bytes(prefix) + bytes(data)
    pe = pefile.PE(data=result); pe.OPTIONAL_HEADER.CheckSum = pe.generate_checksum()
    result = pe.write()
    if pefile.PE(data=original).get_section_by_rva(pe.OPTIONAL_HEADER.AddressOfEntryPoint).get_data() != pe.get_section_by_rva(pe.OPTIONAL_HEADER.AddressOfEntryPoint).get_data():
        raise ValueError('Bootloader executable code changed')
    return result


def verify_archive(base_path, executable, sources):
    base = CArchiveReader(str(base_path)); result = CArchiveReader(str(executable))
    if base.options != result.options: raise ValueError('Bootloader options changed')
    old = base.open_embedded_archive('PYZ.pyz'); new = result.open_embedded_archive('PYZ.pyz')
    before = base.extract('PYZ.pyz'); after = result.extract('PYZ.pyz')
    preserved = 0
    for name, (kind, offset, length) in old.toc.items():
        if name in sources: continue
        k, p, n = new.toc[name]
        if kind != k or before[offset:offset+length] != after[p:p+n]: raise ValueError('Third-party bytecode changed: ' + name)
        preserved += 1
    for name, path in sources.items():
        filename = '\\'.join(path.relative_to(ROOT / 'windows').parts)
        expected = replace_filename_in_code_object(compile(path.read_bytes(), filename, 'exec', optimize=0), filename)
        code = new.extract(name)
        if code != expected or code.co_filename != filename: raise ValueError('Source/bytecode mismatch: ' + name)
    for name in base.toc:
        if name not in ('PYZ.pyz', 'BirdLock') and base.extract(name) != result.extract(name): raise ValueError('Bootstrap module changed: ' + name)
    if marshal.loads(result.extract('BirdLock')) != compile((ROOT/'windows/BirdLock.pyw').read_bytes(), 'BirdLock.pyw', 'exec', optimize=0):
        raise ValueError('Launcher/source mismatch')
    for name in ('xml.etree.ElementTree', 'xml.etree.ElementPath', 'xml.parsers.expat', 'wave', 'csv'):
        if name not in new.toc: raise ValueError('Missing standard-library module: ' + name)
    pe = pefile.PE(str(executable)); fixed = pe.VS_FIXEDFILEINFO[0]
    if fixed.FileVersionMS != (1 << 16) | 9 or fixed.FileVersionLS != 0: raise ValueError('Incorrect PE version')
    for info in pe.FileInfo:
        for entry in info:
            for table in getattr(entry, 'StringTable', []):
                if table.entries.get(b'FileVersion') != b'1.9.0' or table.entries.get(b'ProductVersion') != b'1.9.0': raise ValueError('Incorrect version strings')
    return dict(birdlockModules=len(sources), preservedThirdPartyModules=preserved, python='3.12', pyinstaller=PyInstaller.__version__, sourceBytecodeEqual=True, bootloaderCodeUnchanged=True)


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('--base', type=Path, required=True)
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--release',action='store_true',help='Package for an authorized public release, keeping the Windows runtime limitation explicit')
    args = parser.parse_args()
    if sys.version_info[:2] != (3,12) or PyInstaller.__version__ != '6.22.3': raise SystemExit('Use Python 3.12 and PyInstaller 6.22.3')
    if (ROOT/'VERSION').read_text().strip() != '1.9.0': raise SystemExit('This maintenance fallback is limited to the reviewed 1.6.0 → 1.9.0 change')
    if digest(args.base) != BASE_SHA256: raise SystemExit('Base is not the verified local 1.6.0 Windows package')
    output = args.output.resolve()
    if output.exists(): raise SystemExit('Output already exists; choose a new directory to retain the rollback point')
    output.parent.mkdir(parents=True, exist_ok=True)
    sources = {}
    for path in (ROOT/'windows/birdlock').rglob('*.py'):
        parts = list(path.relative_to(ROOT/'windows').with_suffix('').parts)
        if parts[-1] == '__init__': parts.pop()
        sources['.'.join(parts)] = path
    with tempfile.TemporaryDirectory(prefix='birdlock-windows-assemble-', dir=output.parent) as work:
        stage = Path(work)
        with zipfile.ZipFile(args.base) as archive:
            names = archive.namelist()
            if len({name.casefold() for name in names}) != len(names): raise ValueError('Duplicate Windows archive paths')
            for name in names:
                p = Path(name)
                if p.is_absolute() or '..' in p.parts or '\\' in name: raise ValueError('Unsafe archive path')
                if name.startswith('BirdLock/data/') and not name.endswith('/'): raise ValueError('Base includes user data')
            if archive.testzip(): raise ValueError('Base ZIP CRC error')
            archive.extractall(stage)
        app = stage/'BirdLock'; internal = app/'_internal'; executable = app/'BirdLock.exe'
        base_executable = stage/'original.exe'; shutil.copy2(executable, base_executable)
        reader = CArchiveReader(str(base_executable)); pyz = reader.open_embedded_archive('PYZ.pyz')
        executable.write_bytes(make_executable(base_executable, make_pyz(reader.extract('PYZ.pyz'), pyz, sources), ROOT/'windows/BirdLock.pyw'))
        receipt = verify_archive(base_executable, executable, sources)
        for name in ('pyexpat.pyd', '_elementtree.pyd'):
            if not (internal/name).is_file(): raise ValueError('Missing native XML parser: ' + name)
        shutil.copy2(ROOT/'VERSION', internal/'VERSION')
        for source, target in ((ROOT/'SharedResources/LensProfiles', internal/'lens_profiles'), (ROOT/'windows/telemetry', internal/'telemetry')):
            shutil.copytree(source, target)
        docs = internal/'docs'
        for name in ('用户协议.md','第三方许可.md','自动更新.md','视频导入与镜头配置.md','工程与缓存管理.md','更新说明-1.9.0.md'):
            shutil.copy2(ROOT/'docs'/name, docs/name)
        shutil.copy2(ROOT/'LICENSE', docs/'LICENSE')
        for source in (ROOT/'docs/windows').glob('*.md'): shutil.copy2(source, docs/'windows'/source.name)
        subprocess.run([sys.executable,'-I',str(ROOT/'scripts/md2html.py'),str(ROOT/'docs/windows/使用说明.md'),str(docs/'windows/使用说明.html')],check=True)
        shutil.copy2(docs/'windows/使用说明.html', app/'使用说明.html')
        note = 'Windows 1.9.0 本地待测候选。基于已核验 1.6.0 运行库重新编入当前程序与资源；未做本次 Windows 运行验证，请在实体电脑测试。\n'
        if args.release:
            note='BirdLock 1.9.0 Windows版。已核对源码、版本、更新协议与资源；本次未完成Windows实体电脑运行验证，请先用短片段测试。\n'
            (app/'本地测试说明.txt').unlink(missing_ok=True)
        (app/('运行验证说明.txt' if args.release else '本地测试说明.txt')).write_text(note,encoding='utf-8')
        (app/'源代码.txt').write_text('1.9.0 完整源代码随同版本 BirdLock-1.9.0-source.zip 提供。公开仓库：https://github.com/cyandee/BirdLock\n',encoding='utf-8')
        subprocess.run([sys.executable,'-I',str(ROOT/'scripts/verify_bundle.py'),'--lens-resources',str(internal/'lens_profiles')],check=True)
        subprocess.run([sys.executable,'-I',str(ROOT/'scripts/verify_bundle.py'),'--telemetry-resources',str(internal/'telemetry'),'--telemetry-binary',str(internal/'telemetry/BirdLockTelemetry.exe'),'--telemetry-windows'],check=True)
        catalog = internal/'updates/managed-files.json'
        managed = sorted(p.relative_to(app).as_posix() for p in app.rglob('*') if p.is_file() and p.relative_to(app).parts[0].casefold() != 'data')
        catalog.write_text(json.dumps(managed),encoding='utf-8')
        native_files = 0
        with zipfile.ZipFile(args.base) as original:
            for name in original.namelist():
                relative = Path(name).relative_to('BirdLock')
                if relative.as_posix() == 'BirdLock.exe' or relative.suffix.lower() not in ('.dll','.pyd','.exe','.onnx'): continue
                if hashlib.sha256(original.read(name)).hexdigest() != digest(app/relative):
                    raise ValueError('Existing native dependency changed: ' + str(relative))
                native_files += 1
        receipt['preservedNativeFiles'] = native_files
        output.mkdir(); shutil.move(str(app), str(output/'BirdLock'))
    archive = output/'BirdLock-1.9.0-Windows-x64.zip'
    with zipfile.ZipFile(archive, 'w', zipfile.ZIP_DEFLATED, compresslevel=6, strict_timestamps=False) as z:
        for path in sorted((output/'BirdLock').rglob('*')): z.write(path, path.relative_to(output).as_posix())
    with zipfile.ZipFile(archive) as z:
        if z.testzip(): raise ValueError('Final ZIP CRC error')
    receipt.update(version='1.9.0', baseSHA256=BASE_SHA256, archiveSHA256=digest(archive), windowsRuntimeVerified=False, nativeDependenciesReused=True)
    (output/'assembly-verification.json').write_text(json.dumps(receipt,indent=2)+'\n',encoding='utf-8')
    print(json.dumps(receipt,indent=2))


if __name__ == '__main__': main()
