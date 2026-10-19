"""Build the portable Windows package:  python build_windows.py [--version 1.0]

1. downloads a GPL build of FFmpeg (NVENC / AMF / Quick Sync encoders) into ffmpeg/
2. renders the manual to HTML
3. runs PyInstaller (one-folder, no installer) and zips dist/BirdLock → dist/BirdLock-<ver>-Windows-x64.zip
"""
import argparse
import io
import os
import re
import shutil
import subprocess
import sys
import urllib.request
import zipfile

HERE = os.path.dirname(os.path.abspath(__file__))
REPO = os.path.dirname(HERE)
FFMPEG_RELEASES = "https://api.github.com/repos/BtbN/FFmpeg-Builds/releases/latest"
FFMPEG_FALLBACK = "https://github.com/BtbN/FFmpeg-Builds/releases/download/latest/ffmpeg-master-latest-win64-gpl.zip"


def ffmpeg_url() -> str:
    """Newest stable-branch static GPL build (asset names change with each FFmpeg release)."""
    import json
    import re
    try:
        req = urllib.request.Request(FFMPEG_RELEASES, headers={"Accept": "application/vnd.github+json"})
        tok = os.environ.get("GITHUB_TOKEN") or os.environ.get("GH_TOKEN")
        if tok:
            req.add_header("Authorization", f"Bearer {tok}")
        assets = json.load(urllib.request.urlopen(req, timeout=60))["assets"]
        stable = [a for a in assets if re.fullmatch(r"ffmpeg-n(\d+)\.(\d+)-latest-win64-gpl-\d+\.\d+\.zip", a["name"])]
        if stable:
            best = max(stable, key=lambda a: tuple(int(x) for x in re.findall(r"n(\d+)\.(\d+)", a["name"])[0]))
            return best["browser_download_url"]
    except Exception as e:
        print("could not list FFmpeg releases:", e)
    return FFMPEG_FALLBACK


def fetch_ffmpeg():
    dst = os.path.join(HERE, "ffmpeg", "ffmpeg.exe")
    if os.path.exists(dst):
        return
    url = ffmpeg_url()
    print("downloading FFmpeg:", url)
    data = urllib.request.urlopen(url, timeout=600).read()
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
    with open(os.path.join(REPO, "VERSION"), encoding="utf-8") as f:
        version = f.read().strip()
    if not re.fullmatch(r"\d+\.\d+\.\d+", version):
        raise SystemExit("VERSION 必须使用 major.minor.patch 格式")
    ap = argparse.ArgumentParser()
    ap.add_argument("--version", default=version)
    a = ap.parse_args()
    if a.version != version:
        raise SystemExit("打包版本与 VERSION 不一致，请先统一更新 VERSION")
    subprocess.check_call([sys.executable, "-I", os.path.join(REPO,"scripts","fetch_aircraft_model.py")])
    subprocess.check_call([sys.executable,"-I",os.path.join(REPO,"scripts","verify_bundle.py"),
                           "--aircraft-resources",os.path.join(REPO,"SharedResources","AircraftModels")])
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
