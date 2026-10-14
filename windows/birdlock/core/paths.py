"""Where things live: bundled resources (models, docs, ffmpeg) and the user's data (settings, cache).

Portable by design: when the program folder is writable, settings and cache are kept in a `data`
folder next to BirdLock.exe, so the whole folder can be copied to another PC or a USB drive.
Otherwise %LOCALAPPDATA%\\BirdLock (Windows) / ~/Library/Application Support/BirdLock (macOS) is used.
"""
from __future__ import annotations

import os
import shutil
import sys
from pathlib import Path

FROZEN = getattr(sys, "frozen", False)
IS_WINDOWS = sys.platform == "win32"
IS_MAC = sys.platform == "darwin"


def app_dir() -> Path:
    """Folder containing BirdLock.exe (frozen) or the `windows` source folder (development)."""
    if FROZEN:
        return Path(sys.executable).resolve().parent
    return Path(__file__).resolve().parents[2]


def resource_dir() -> Path:
    """Bundled read-only resources (PyInstaller puts them in _internal)."""
    if FROZEN:
        return Path(getattr(sys, "_MEIPASS", app_dir()))
    return app_dir()


def models_dir() -> Path:
    return resource_dir() / "models"


def docs_dir() -> Path:
    d = resource_dir() / "docs"
    if d.exists():
        return d
    return app_dir().parent / "docs"   # development: repo docs/


def _writable(d: Path) -> bool:
    try:
        d.mkdir(parents=True, exist_ok=True)
        probe = d / ".write_test"
        probe.write_text("ok")
        probe.unlink()
        return True
    except OSError:
        return False


_data: Path | None = None


def data_dir() -> Path:
    global _data
    if _data is None:
        env = os.environ.get("BIRDLOCK_DATA")
        if env:
            _data = Path(env)
        elif _writable(app_dir() / "data"):
            _data = app_dir() / "data"
        elif IS_WINDOWS:
            _data = Path(os.environ.get("LOCALAPPDATA", Path.home())) / "BirdLock"
        else:
            _data = Path.home() / "Library" / "Application Support" / "BirdLock-PC"
        _data.mkdir(parents=True, exist_ok=True)
    return _data


def cache_dir() -> Path:
    d = data_dir() / "cache"
    d.mkdir(parents=True, exist_ok=True)
    return d


def ffmpeg_path() -> str | None:
    env = os.environ.get("BIRDLOCK_FFMPEG")
    if env and Path(env).exists():
        return env
    exe = "ffmpeg.exe" if IS_WINDOWS else "ffmpeg"
    for cand in (resource_dir() / "ffmpeg" / exe, app_dir() / "ffmpeg" / exe):
        if cand.exists():
            return str(cand)
    return shutil.which("ffmpeg")
