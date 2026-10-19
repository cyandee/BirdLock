"""Actual resource-seal checks with disposable signed Mac apps; never launches a GUI."""
from pathlib import Path
import plistlib
import shutil
import subprocess
import sys
import tempfile
import unittest

from scripts.verify_mac_artifact import check_app,digest,verify


@unittest.skipUnless(sys.platform=='darwin' and shutil.which('codesign') and shutil.which('clang'),'macOS signing tools required')
class MacArtifactTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory(prefix='birdlock-seal-test-');self.addCleanup(self.temp.cleanup)
        self.root = Path(self.temp.name);self.app = self.root/'payload/BirdLock.app'
        (self.app/'Contents/MacOS').mkdir(parents=True)
        (self.app/'Contents/Resources').mkdir()
        self.resource = self.app/'Contents/Resources/payload.txt';self.resource.write_text('original resource')
        self.binary = self.app/'Contents/MacOS/BirdLock'
        (self.app/'Contents/Info.plist').write_bytes(plistlib.dumps(dict(CFBundlePackageType='APPL',CFBundleExecutable='BirdLock',
            CFBundleIdentifier='local.birdlock.seal-test',CFBundleVersion='1',CFBundleShortVersionString='1.0')))
        self.command('/usr/bin/clang','-x','c','-mmacosx-version-min=14.0','-o',str(self.binary),'-',input=b'int main(void){return 0;}')
        self.command('/usr/bin/codesign','--force','--sign','-',str(self.app))

    def command(self,*args,**kwargs):
        return subprocess.run(args,check=True,stdout=subprocess.PIPE,stderr=subprocess.PIPE,**kwargs)

    def archive(self,suffix):
        path = self.root/('BirdLock'+suffix)
        if suffix=='.dmg':
            self.command('/usr/bin/hdiutil','create','-srcfolder',str(self.app.parent),'-format','UDZO',str(path))
        else:self.command('/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(self.app),str(path))
        return path

    def test_signed_app_passes_but_a_changed_resource_is_rejected_without_repair(self):
        check_app(self.app)
        self.resource.write_text('changed after signing')
        with self.assertRaisesRegex(ValueError,'codesign'):check_app(self.app)
        self.assertEqual(self.resource.read_text(),'changed after signing')

    def test_missing_executable_permission_is_rejected(self):
        self.binary.chmod(0o644)
        with self.assertRaisesRegex(ValueError,'执行权限'):check_app(self.app)

    def test_dmg_mount_and_install_copy_preserve_seal_and_leave_image_unchanged(self):
        path = self.archive('.dmg');before = digest(path)
        verify(path)
        self.assertEqual(digest(path),before)

    def test_valid_dmg_with_broken_app_seal_is_rejected(self):
        self.resource.unlink()
        path = self.archive('.dmg')
        with self.assertRaisesRegex(ValueError,'codesign'):verify(path)

    def test_zip_extract_and_install_copy_preserve_seal(self):
        wrapper = self.root/'测试包 空格';wrapper.mkdir()
        shutil.copytree(self.app,wrapper/'BirdLock.app')
        path = self.root/'wrapped.zip'
        self.command('/usr/bin/ditto','-c','-k','--sequesterRsrc','--keepParent',str(wrapper),str(path))
        before = digest(path)
        verify(path,'测试包 空格/BirdLock.app')
        self.assertEqual(digest(path),before)

    def test_valid_zip_with_changed_signed_resource_is_rejected(self):
        self.resource.write_text('bad resource')
        with self.assertRaisesRegex(ValueError,'codesign'):verify(self.archive('.zip'))


if __name__=='__main__':unittest.main()
