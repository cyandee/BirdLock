"""Checks for the separately built, bundled telemetry reader (never executes it)."""
import hashlib
import json
import os
from pathlib import Path
import struct

TELEMETRY_REVISION = '19bc11f8c13eaa07ec1988bf0a55884f3fcc0f96'


def telemetry_source_digest(root):
    digest = hashlib.sha256()
    for name in ('Cargo.toml', 'Cargo.lock', 'src/main.rs'):
        digest.update(name.encode('utf-8') + b'\0')
        digest.update((Path(root) / 'tools/telemetry' / name).read_bytes())
    return digest.hexdigest()


def verify_telemetry(binary, resources, *, windows=False, universal=False, source_root=None):
    binary, resources = Path(binary), Path(resources)
    manifest = json.loads((resources / 'manifest.json').read_text(encoding='utf-8'))
    if (manifest.get('schema') != 1 or manifest.get('helperVersion') != '1.0.0'
            or manifest.get('telemetryParserRevision') != TELEMETRY_REVISION
            or manifest.get('binary') != binary.name):
        raise ValueError('陀螺仪组件版本或清单无效')
    if not binary.is_file(): raise ValueError('缺少陀螺仪读取组件')
    data = binary.read_bytes()
    if len(data) != manifest.get('bytes') or hashlib.sha256(data).hexdigest() != manifest.get('sha256'):
        raise ValueError('陀螺仪组件校验失败')
    if source_root and manifest.get('sourceSha256') != telemetry_source_digest(source_root):
        raise ValueError('陀螺仪组件与当前源码不一致，请重新构建')
    if windows:
        if len(data) < 64 or data[:2] != b'MZ': raise ValueError('陀螺仪组件不是 Windows PE 可执行文件')
        pe = struct.unpack_from('<I', data, 60)[0]
        if pe + 26 > len(data) or data[pe:pe+4] != b'PE\0\0' or struct.unpack_from('<H', data, pe+4)[0] != 0x8664:
            raise ValueError('陀螺仪组件必须是 Windows x64 可执行文件')
    else:
        if not os.access(binary, os.X_OK): raise ValueError('陀螺仪组件缺少执行权限')
        magic = data[:4]
        if magic not in (b'\xcf\xfa\xed\xfe', b'\xfe\xed\xfa\xcf', b'\xca\xfe\xba\xbe'):
            raise ValueError('陀螺仪组件不是 Mach-O 可执行文件')
        if universal:
            if magic != b'\xca\xfe\xba\xbe' or len(data) < 8: raise ValueError('陀螺仪组件缺少通用架构')
            count = struct.unpack_from('>I', data, 4)[0]
            if count > 8 or len(data) < 8 + count * 20: raise ValueError('陀螺仪组件通用架构清单无效')
            arches = {struct.unpack_from('>I', data, 8 + 20 * i)[0] for i in range(count)}
            if not {0x01000007, 0x0100000C}.issubset(arches): raise ValueError('陀螺仪组件缺少 Intel 或 Apple 芯片架构')
    licenses = resources / 'Licenses'
    checks = json.loads((licenses / 'checksums.json').read_text(encoding='utf-8'))
    required = {'telemetry-parser-MIT.txt', 'telemetry-parser-Apache-2.0.txt', 'dependencies.json'}
    if not required.issubset(checks) or not any(name.startswith('RustRuntime/COPYRIGHT') for name in checks):
        raise ValueError('陀螺仪组件第三方许可不完整')
    for name, entry in checks.items():
        path = Path(name)
        if path.is_absolute() or '..' in path.parts or '\\' in name: raise ValueError('陀螺仪许可文件名无效')
        file = licenses / path
        if not file.is_file(): raise ValueError('缺少陀螺仪组件第三方许可：' + name)
        content = file.read_bytes()
        if len(content) != entry.get('bytes') or hashlib.sha256(content).hexdigest() != entry.get('sha256'):
            raise ValueError('陀螺仪组件许可校验失败：' + name)
    dependencies = json.loads((licenses / 'dependencies.json').read_text(encoding='utf-8'))
    parser = [entry for entry in dependencies if entry.get('name') == 'telemetry-parser']
    if len(parser) != 1 or TELEMETRY_REVISION not in (parser[0].get('source') or ''):
        raise ValueError('陀螺仪解析库依赖版本无效')
    for entry in dependencies:
        component = str(entry.get('name', '')) + '-' + str(entry.get('version', ''))
        if Path(component).name != component or '\\' in component or not any(name.startswith('Crates/' + component + '/') for name in checks):
            raise ValueError('陀螺仪组件缺少依赖许可：' + component)
    return manifest
