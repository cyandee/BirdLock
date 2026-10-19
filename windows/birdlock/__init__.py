"""BirdLock 鸟眼锁定 — Windows version (Python + Qt).

Aligns bird bursts on the bird's eye and renders them into a video. Same algorithms as the native
macOS app (Sources/BirdLockCore), ported to numpy / OpenCV / ONNX Runtime.
"""

import sys
from pathlib import Path


def _version() -> str:
    root = Path(getattr(sys, "_MEIPASS", Path(__file__).resolve().parents[2]))
    try:
        return (root / "VERSION").read_text(encoding="utf-8").strip()
    except OSError:
        return "dev"


__version__ = _version()
APP_NAME = "BirdLock 鸟眼锁定"
CONTACT_EMAIL = "cyanodee@gmail.com"
CONTACT_TEXT = f"邮箱：{CONTACT_EMAIL}"
