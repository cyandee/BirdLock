"""Build the portable Windows package:  python build_windows.py [--version 1.0]

1. downloads a GPL build of FFmpeg (NVENC / AMF / Quick Sync encoders) into ffmpeg/
2. renders the manual to HTML
3. runs PyInstaller (one-folder, no installer) and zips dist/BirdLock → dist/BirdLock-<ver>-Windows-x64.zip
"""
import argparse
import io
import os
import shutil
import subprocess
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FFMPEG_URL = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-n7.1-latest-win64-gpl-7.1.zip"


def fetch_ffmpeg():
    dst = os.path.join(HERE, "ffmpeg", "ffmpeg.exe")
    if os.path.exists(dst):
        return
    print("downloading FFmpeg …", FFMPEG_URL)
    data = urllib.request.urlopen(FFMPEG_URL, timeout=300).read()
    with zipfile.ZipFile(io.BytesIO(data)) as z:
        exe = next(n for n in z.namelist() if n.endswith("bin/ffmpeg.exe"))
        os.makedirs(os.path.dirname(dst), exist_ok=True)
        with z.open(exe) as src, open(dst, "wb") as out:
            shutil.copyfileobj(src, out)
        lic = next((n for n in z.namelist() if n.endswith("LICENSE.txt")), None)
        if lic:
            with z.open(lic) as src, open(os.path.join(HERE, "ffmpeg", "LICENSE.txt"), "wb") as out:
                shutil.copyfileobj(src, out)


def version_file(ver: str):
    parts = (ver.split(".") + ["0", "0", "0"])[:4]
    t = tuple(int(p) if p.isdigit() else 0 for p in parts)
    with open(os.path.join(HERE, "version_info.txt"), "w", encoding="utf-8") as f:
        f.write(f"""VSVersionInfo(
  ffi=FixedFileInfo(filevers={t}, prodvers={t}, mask=0x3f, flags=0x0, OS=0x40004, fileType=0x1, subtype=0x0, date=(0, 0)),
  kids=[StringFileInfo([StringTable('080404b0', [
    StringStruct('CompanyName', 'cyanol'), StringStruct('FileDescription', 'BirdLock 鸟眼锁定'),
    StringStruct('FileVersion', '{ver}'), StringStruct('InternalName', 'BirdLock'),
    StringStruct('LegalCopyright', 'Copyright (C) 2026 cyanol. AGPL-3.0'), StringStruct('OriginalFilename', 'BirdLock.exe'),
    StringStruct('ProductName', 'BirdLock 鸟眼锁定'), StringStruct('ProductVersion', '{ver}')])]),
    VarFileInfo([VarStruct('Translation', [2052, 1200])])]
)
""")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default="1.0")
    a = ap.parse_args()
    fetch_ffmpeg()
    subprocess.check_call([sys.executable, os.path.join(REPO, "scripts", "md2html.py"),
                           os.path.join(REPO, "docs", "windows", "使用说明.md"),
                           os.path.join(REPO, "docs", "windows", "使用说明.html")])
    version_file(a.version)
    subprocess.check_call([sys.executable, "-m", "PyInstaller", "--noconfirm", "--clean", os.path.join(HERE, "BirdLock.spec")],
                          cwd=HERE)
    dist = os.path.join(HERE, "dist", "BirdLock")
    shutil.copy(os.path.join(REPO, "LICENSE"), os.path.join(dist, "LICENSE.txt"))
    shutil.copy(os.path.join(REPO, "docs", "windows", "使用说明.html"), os.path.join(dist, "使用说明.html"))
    with open(os.path.join(dist, "源代码.txt"), "w", encoding="utf-8") as f:
        f.write("BirdLock 鸟眼锁定依据 GNU AGPL-3.0 开源。\n完整源代码：https://github.com/cyandee/BirdLock\n"
                "（每个版本在 Releases 页面也附有源代码压缩包）\n")
    os.makedirs(os.path.join(dist, "data"), exist_ok=True)   # portable: settings & cache live here
    zip_path = os.path.join(HERE, "dist", f"BirdLock-{a.version}-Windows-x64.zip")
    if os.path.exists(zip_path):
        os.remove(zip_path)
    shutil.make_archive(zip_path[:-4], "zip", os.path.join(HERE, "dist"), "BirdLock")
    print("built", zip_path, os.path.getsize(zip_path) // (1 << 20), "MB")


if __name__ == "__main__":
    main()
