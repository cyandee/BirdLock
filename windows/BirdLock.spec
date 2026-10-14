# PyInstaller spec: portable one-folder build  →  dist/BirdLock/BirdLock.exe
# Build with:  python build_windows.py   (downloads FFmpeg, then runs PyInstaller)
import os
from PyInstaller.utils.hooks import collect_dynamic_libs

here = os.path.abspath(SPECPATH)
repo = os.path.dirname(here)

datas = [
    (os.path.join(here, "models"), "models"),
    (os.path.join(here, "assets"), "assets"),
    (os.path.join(here, "ffmpeg"), "ffmpeg"),
    (os.path.join(repo, "docs", "windows"), os.path.join("docs", "windows")),
    (os.path.join(repo, "docs", "用户协议.md"), "docs"),
    (os.path.join(repo, "docs", "第三方许可.md"), "docs"),
    (os.path.join(repo, "LICENSE"), "docs"),
]
binaries = collect_dynamic_libs("onnxruntime")   # includes DirectML.dll

a = Analysis(
    [os.path.join(here, "BirdLock.pyw")],
    pathex=[here],
    binaries=binaries,
    datas=datas,
    hiddenimports=["pillow_heif"],
    excludes=["tkinter", "matplotlib", "scipy", "pandas", "IPython", "PySide6.QtWebEngineCore", "PySide6.Qt3DCore",
              "PySide6.QtQuick", "PySide6.QtQml", "PySide6.QtPdf", "PySide6.QtCharts"],
    noarchive=False,
)
pyz = PYZ(a.pure)
exe = EXE(pyz, a.scripts, [], exclude_binaries=True, name="BirdLock", console=False,
          icon=os.path.join(here, "assets", "BirdLock.ico"), version=os.path.join(here, "version_info.txt"))
coll = COLLECT(exe, a.binaries, a.datas, strip=False, upx=False, name="BirdLock")
