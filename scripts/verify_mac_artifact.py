"""Read-only distribution checks, including a copy out of the final DMG or ZIP.

This verifies integrity, not Developer ID trust or Apple notarization. Never repairs,
re-signs, removes quarantine, or launches the application being checked.
"""
from __future__ import annotations

import argparse
from contextlib import contextmanager
import hashlib
import os
from pathlib import Path
import plistlib
import subprocess
import tempfile
import zipfile


def run(*args):
    result = subprocess.run([str(a) for a in args],capture_output=True,text=True)
    if result.returncode:
        raise ValueError(f"{Path(args[0]).name} 验证失败："+(result.stderr.strip() or result.stdout.strip()))
    return result.stdout


def check_app(app: Path):
    info = plistlib.loads((app/'Contents/Info.plist').read_bytes())
    name = info.get('CFBundleExecutable','')
    if info.get('CFBundlePackageType') != 'APPL' or not name or Path(name).name != name:
        raise ValueError('应用包或启动入口无效')
    binary = app/'Contents/MacOS'/name
    if binary.is_symlink() or not binary.is_file() or not os.access(binary,os.X_OK):
        raise ValueError('应用启动文件必须是具有执行权限的普通文件')
    run('/usr/bin/codesign','--verify','--deep','--strict','--verbose=2',app)


def digest(path: Path):
    h = hashlib.sha256()
    with path.open('rb') as stream:
        for block in iter(lambda: stream.read(1<<20),b''):h.update(block)
    return h.hexdigest()


@contextmanager
def mounted_image(image: Path, mount: Path):
    run('/usr/bin/hdiutil','verify',image)
    run('/usr/bin/hdiutil','attach',image,'-readonly','-nobrowse','-plist','-mountpoint',mount)
    try:
        yield mount
    finally:
        run('/usr/bin/hdiutil','detach',mount)


def check_copy(app: Path, installed: Path):
    check_app(app)
    run('/usr/bin/ditto',app,installed)
    check_app(installed)


def verify(artifact: Path, app_relative: str = 'BirdLock.app'):
    artifact = artifact.resolve()
    relative = Path(app_relative)
    if relative.is_absolute() or '..' in relative.parts or relative.name != 'BirdLock.app':
        raise ValueError('应用在分发包中的路径无效')
    before = digest(artifact)
    with tempfile.TemporaryDirectory(prefix='birdlock-distribution-check-') as folder:
        root = Path(folder);installed = root/'installation/BirdLock.app'
        if artifact.suffix.lower() == '.dmg':
            mount = root/'mounted';mount.mkdir()
            with mounted_image(artifact,mount):check_copy(mount/relative,installed)
        elif artifact.suffix.lower() == '.zip':
            # Check names before extracting an archive produced by our own release script.
            with zipfile.ZipFile(artifact) as z:
                for name in z.namelist():
                    path = Path(name)
                    if path.is_absolute() or '..' in path.parts or '\\' in name:
                        raise ValueError('压缩包包含无效路径')
                if z.testzip() is not None:raise ValueError('压缩包完整性校验失败')
            unpacked = root/'unpacked'
            run('/usr/bin/ditto','-x','-k',artifact,unpacked)
            check_copy(unpacked/relative,installed)
        else:raise ValueError('只支持最终DMG或ZIP分发包')
    if digest(artifact) != before:raise ValueError('验证期间分发文件发生变化')


if __name__ == '__main__':
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument('artifact',type=Path)
    parser.add_argument('--app-relative',default='BirdLock.app')
    args = parser.parse_args()
    verify(args.artifact,args.app_relative)
    print('最终分发包、包内签名及模拟安装后的签名检查通过（不代表已公证）')
