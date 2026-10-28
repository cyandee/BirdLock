import plistlib
import hashlib
import json
import tempfile
import unittest
from pathlib import Path

from scripts.verify_bundle import verify,verify_aircraft,verify_updater


class BundleTests(unittest.TestCase):
    def aircraft(self, folder):
        root = Path(folder);model = root/'AircraftParts.onnx';model.write_bytes(b'fixture');model.chmod(0o644)
        (root/'manifest.json').write_text(json.dumps(dict(file=model.name,bytes=7,sha256=hashlib.sha256(b'fixture').hexdigest())))
        licenses = root/'Licenses';licenses.mkdir()
        for name in ('Apache-2.0.txt','ONNXRuntime-MIT.txt','ONNXRuntime-Swift-MIT.txt','ONNXRuntime-ThirdPartyNotices.txt'):
            (licenses/name).write_text('fixture')
        checks = {p.name:dict(bytes=7,sha256=hashlib.sha256(b'fixture').hexdigest()) for p in licenses.glob('*.txt')}
        (licenses/'checksums.json').write_text(json.dumps(checks))
        return root,model

    def test_aircraft_resources_reject_missing_corrupt_and_private_weights(self):
        with tempfile.TemporaryDirectory() as folder:
            root,model = self.aircraft(folder);verify_aircraft(root)
            model.chmod(0o600)
            with self.assertRaisesRegex(ValueError,'账户'):verify_aircraft(root)
            model.chmod(0o644);model.write_bytes(b'changed')
            with self.assertRaisesRegex(ValueError,'校验'):verify_aircraft(root)
            model.unlink()
            with self.assertRaisesRegex(ValueError,'完整'):verify_aircraft(root)

    def test_aircraft_resources_require_third_party_notices_and_safe_names(self):
        with tempfile.TemporaryDirectory() as folder:
            root,model = self.aircraft(folder)
            (root/'Licenses/ONNXRuntime-ThirdPartyNotices.txt').unlink()
            with self.assertRaisesRegex(ValueError,'许可'):verify_aircraft(root)
            (root/'manifest.json').write_text(json.dumps(dict(file='../AircraftParts.onnx')))
            with self.assertRaisesRegex(ValueError,'文件名'):verify_aircraft(root)

    def test_aircraft_resources_reject_truncated_legal_text(self):
        with tempfile.TemporaryDirectory() as folder:
            root,_ = self.aircraft(folder)
            (root/'Licenses/ONNXRuntime-ThirdPartyNotices.txt').write_text('fixtur')
            with self.assertRaisesRegex(ValueError,'许可文件不完整'):verify_aircraft(root)
    def test_rejects_transferred_link_placeholder_as_executable(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "BirdLock.app"
            binary = app / "Contents/MacOS/BirdLock"
            binary.parent.mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "BirdLock",
                "CFBundleShortVersionString": "1.1.0"}))
            binary.write_text("XSym\n0010\nnot-an-executable\n")
            binary.chmod(0o755)
            with self.assertRaisesRegex(ValueError, "Mach-O"):
                verify(app, "1.1.0")

    def test_rejects_wrong_application_version(self):
        with tempfile.TemporaryDirectory() as folder:
            app = Path(folder) / "BirdLock.app"
            (app / "Contents").mkdir(parents=True)
            (app / "Contents/Info.plist").write_bytes(plistlib.dumps({
                "CFBundlePackageType": "APPL", "CFBundleExecutable": "BirdLock",
                "CFBundleShortVersionString": "1.0"}))
            with self.assertRaisesRegex(ValueError, "版本"):
                verify(app, "1.1.0")

    def test_update_bundle_requires_matching_version_framework_and_signatures(self):
        import base64
        with tempfile.TemporaryDirectory() as folder:
            app=Path(folder);info={'CFBundleVersion':'1.5.0'}
            with self.assertRaisesRegex(ValueError,'框架'):verify_updater(app,'1.5.0',info)
            binary=app/'Contents/Frameworks/Sparkle.framework/Sparkle';binary.parent.mkdir(parents=True);binary.write_bytes(b'fixture')
            license=app/'Contents/Resources/Sparkle-LICENSE.txt';license.parent.mkdir();license.write_text('fixture')
            verify_updater(app,'1.5.0',info)
            info.update(SUFeedURL='https://example.test/mac.xml',SUPublicEDKey=base64.b64encode(bytes(32)).decode())
            with self.assertRaisesRegex(ValueError,'签名'):verify_updater(app,'1.5.0',info)
            info.update(SURequireSignedFeed=True,SUVerifyUpdateBeforeExtraction=True);verify_updater(app,'1.5.0',info)
            info['CFBundleVersion']='999'
            with self.assertRaisesRegex(ValueError,'版本号'):verify_updater(app,'1.5.0',info)
