import hashlib
import json
from pathlib import Path
import struct
import tempfile
import unittest

from scripts.package_checks import TELEMETRY_REVISION, telemetry_source_digest, verify_telemetry

ROOT = Path(__file__).resolve().parents[2]


class TelemetryPackageTests(unittest.TestCase):
    def test_inventory_excludes_unreachable_cross_platform_metadata(self):
        from scripts.build_telemetry_helper import target_packages
        packages=[dict(id=n,name=n) for n in ("app","parser","windows","android-jni")]
        graph=dict(root="app",nodes=[dict(id="app",deps=[dict(pkg="parser")]),dict(id="parser",deps=[dict(pkg="windows")]),dict(id="windows",deps=[]),dict(id="android-jni",deps=[])])
        self.assertEqual({p["name"] for p in target_packages(dict(packages=packages,resolve=graph))},{"app","parser","windows"})

    def component(self, folder, *, windows=False, universal=False):
        folder = Path(folder)
        if windows:
            data = bytearray(128);data[:2] = b'MZ';struct.pack_into('<I', data, 60, 64)
            data[64:68] = b'PE\0\0';struct.pack_into('<H', data, 68, 0x8664)
        elif universal:
            data = bytearray(64);data[:4] = b'\xca\xfe\xba\xbe';struct.pack_into('>I', data, 4, 2)
            struct.pack_into('>I', data, 8, 0x01000007);struct.pack_into('>I', data, 28, 0x0100000C)
        else:
            data = b'\xcf\xfa\xed\xfe' + bytes(60)
        binary = folder / ('BirdLockTelemetry.exe' if windows else 'BirdLockTelemetry')
        binary.write_bytes(data);binary.chmod(0o755)
        licenses = folder / 'Licenses';licenses.mkdir()
        files = {'telemetry-parser-MIT.txt': b'MIT fixture', 'telemetry-parser-Apache-2.0.txt': b'Apache fixture', 'Crates/telemetry-parser-0.4.0/LICENSE-MIT': b'MIT fixture',
                 'RustRuntime/COPYRIGHT-library.html': b'Runtime fixture', 'dependencies.json': json.dumps([
                     dict(name='telemetry-parser', version='0.4.0', source='git+https://github.com/AdrianEddy/telemetry-parser#' + TELEMETRY_REVISION)]).encode()}
        for name, value in files.items():
            path = licenses / name;path.parent.mkdir(parents=True, exist_ok=True);path.write_bytes(value)
        checks = {name: dict(bytes=len(value), sha256=hashlib.sha256(value).hexdigest()) for name, value in files.items()}
        (licenses / 'checksums.json').write_text(json.dumps(checks))
        manifest = dict(schema=1, helperVersion='1.0.0', telemetryParserRevision=TELEMETRY_REVISION,
                        binary=binary.name, bytes=len(data), sha256=hashlib.sha256(data).hexdigest(), sourceSha256=telemetry_source_digest(ROOT))
        (folder / 'manifest.json').write_text(json.dumps(manifest))
        return binary, folder

    def test_architectures_integrity_and_current_source(self):
        for windows, universal in [(False, False), (False, True), (True, False)]:
            with tempfile.TemporaryDirectory() as folder:
                binary, resource = self.component(folder, windows=windows, universal=universal)
                verify_telemetry(binary, resource, windows=windows, universal=universal, source_root=ROOT)
                binary.write_bytes(binary.read_bytes()[:-1])
                with self.assertRaisesRegex(ValueError, '校验'):
                    verify_telemetry(binary, resource, windows=windows, universal=universal)

    def test_refuses_wrong_architecture_missing_or_changed_notices(self):
        with tempfile.TemporaryDirectory() as folder:
            binary, resource = self.component(folder)
            with self.assertRaisesRegex(ValueError, '通用架构'):
                verify_telemetry(binary, resource, universal=True)
            with self.assertRaisesRegex(ValueError, 'PE'):
                verify_telemetry(binary, resource, windows=True)
            notice = resource / 'Licenses/telemetry-parser-MIT.txt';notice.write_text('changed')
            with self.assertRaisesRegex(ValueError, '许可校验'):
                verify_telemetry(binary, resource)
            notice.unlink()
            with self.assertRaisesRegex(ValueError, '第三方许可'):
                verify_telemetry(binary, resource)

    def test_refuses_stale_build_and_unsafe_notice_path(self):
        with tempfile.TemporaryDirectory() as folder:
            binary, resource = self.component(folder)
            path = resource / 'manifest.json';manifest = json.loads(path.read_text());manifest['sourceSha256'] = 'old';path.write_text(json.dumps(manifest))
            with self.assertRaisesRegex(ValueError, '当前源码'):
                verify_telemetry(binary, resource, source_root=ROOT)
            path = resource / 'Licenses/checksums.json';checks = json.loads(path.read_text());checks['../escape'] = {};path.write_text(json.dumps(checks))
            with self.assertRaisesRegex(ValueError, '文件名'):
                verify_telemetry(binary, resource)


if __name__ == '__main__': unittest.main()
