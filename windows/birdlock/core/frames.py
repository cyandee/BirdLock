"""Photo import and decoding (port of IO/SourceFrame.swift and IO/ImageLoader.swift).

Decoding uses OpenCV (libjpeg-turbo). JPEGs are decoded directly at 1/2, 1/4 or 1/8 size when a smaller
image is enough, which is several times faster and needs far less memory. EXIF orientation is applied
explicitly so every decode path agrees. Unicode (Chinese) paths work on Windows (np.fromfile + imdecode).
"""
from __future__ import annotations

import os
import unicodedata
import uuid
from concurrent.futures import ThreadPoolExecutor
from dataclasses import dataclass, field
from datetime import datetime, timezone
from pathlib import Path

import cv2
import numpy as np
from PIL import Image, ExifTags

try:  # HEIF / HEIC support (optional)
    import pillow_heif
    pillow_heif.register_heif_opener()
    HAVE_HEIF = True
except Exception:  # pragma: no cover
    HAVE_HEIF = False

from .util import median
from .raw_photo import RAW_EXT

SUPPORTED_EXT = {".jpg", ".jpeg", ".heic", ".heif", ".hif", ".png", ".tif", ".tiff"} | RAW_EXT
JPEG_EXT = {".jpg", ".jpeg"}
HEIF_EXT = {".heic", ".heif", ".hif"}

_TAG = {v: k for k, v in ExifTags.TAGS.items()}


@dataclass
class ExifInfo:
    make: str | None = None
    model: str | None = None
    lens: str | None = None
    focalLength: float | None = None
    exposureTime: float | None = None
    fNumber: float | None = None
    iso: int | None = None
    dateTimeOriginal: str | None = None

    @property
    def camera_name(self) -> str | None:
        if not self.model:
            return self.make
        if self.make and not self.model.lower().startswith(self.make.lower().split(" ")[0]):
            return f"{self.make} {self.model}"
        return self.model

    @property
    def shutter_text(self) -> str | None:
        t = self.exposureTime
        if not t or t <= 0:
            return None
        return f"{t:.1f}s" if t >= 0.5 else f"1/{round(1 / t)}s"

    @property
    def exposure_line(self) -> str:
        parts = []
        if self.focalLength:
            parts.append(f"{round(self.focalLength)}mm")
        if self.shutter_text:
            parts.append(self.shutter_text)
        if self.fNumber:
            n = self.fNumber
            parts.append(f"f/{int(n)}" if float(n).is_integer() else f"f/{n:.1f}")
        if self.iso:
            parts.append(f"ISO {self.iso}")
        return "  ".join(parts)


@dataclass
class SourceFrame:
    id: int
    path: str
    pixelWidth: int            # oriented (display) size
    pixelHeight: int
    orientation: int = 1       # EXIF orientation of the file
    captureTime: float | None = None
    fileSize: int = 0
    modified: float = 0.0
    exif: ExifInfo = field(default_factory=ExifInfo)
    raw: dict | None = None

    @property
    def file_name(self) -> str:
        return os.path.basename(self.path)

    def to_dict(self) -> dict:
        d = dict(self.__dict__)
        d["exif"] = dict(self.exif.__dict__)
        if self.raw is None:
            d.pop("raw")
        return d

    @staticmethod
    def from_dict(d: dict) -> "SourceFrame":
        d = dict(d)
        raw = d.get("raw")
        if raw is not None and (not isinstance(raw, dict) or raw.get("mode") not in ("camera", "raw")
                or raw.get("source") not in ("embedded", "decoded")
                or any(type(raw.get(k)) is not int or not 0 < raw[k] <= 100_000 for k in ("fullWidth", "fullHeight"))):
            raise ValueError("工程 RAW 图像记录无效。")
        d["exif"] = ExifInfo(**d.get("exif", {}))
        return SourceFrame(**d)


@dataclass
class BurstSegment:
    start: int
    stop: int        # exclusive
    fps: float
    groupID: str = field(default_factory=lambda: str(uuid.uuid4()))
    name: str = ""

    @property
    def count(self) -> int:
        return self.stop - self.start

    def label(self, index: int) -> str:
        return self.name or f"第 {index+1} 组"

    @classmethod
    def from_project(cls, value):
        start,count=value['start'],value['count']
        return cls(start,start+count,value['fps'],value.get('groupID') or f'legacy-{start}-{count}',value.get('name') or '')


# ---------------------------------------------------------------------------------------------- decoding


def _read_bytes(path: str) -> np.ndarray:
    return np.fromfile(path, dtype=np.uint8)


def _apply_orientation(img: np.ndarray, o: int) -> np.ndarray:
    if o == 2:
        return cv2.flip(img, 1)
    if o == 3:
        return cv2.rotate(img, cv2.ROTATE_180)
    if o == 4:
        return cv2.flip(img, 0)
    if o == 5:
        return cv2.flip(cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE), 1)
    if o == 6:
        return cv2.rotate(img, cv2.ROTATE_90_CLOCKWISE)
    if o == 7:
        return cv2.flip(cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE), 1)
    if o == 8:
        return cv2.rotate(img, cv2.ROTATE_90_COUNTERCLOCKWISE)
    return img


_REDUCED = {
    (2, False): cv2.IMREAD_REDUCED_COLOR_2, (4, False): cv2.IMREAD_REDUCED_COLOR_4, (8, False): cv2.IMREAD_REDUCED_COLOR_8,
    (2, True): cv2.IMREAD_REDUCED_GRAYSCALE_2, (4, True): cv2.IMREAD_REDUCED_GRAYSCALE_4, (8, True): cv2.IMREAD_REDUCED_GRAYSCALE_8,
}


def load_image(frame: SourceFrame, scale: float = 1.0, gray: bool = False) -> np.ndarray | None:
    """Decode `frame` (BGR uint8, or gray) with orientation applied, at about `scale` × full size.

    For JPEG, scale must be 1, 1/2, 1/4 or 1/8 (exact DCT scaling); other formats are resized.
    """
    ext = Path(frame.path).suffix.lower()
    try:
        if ext in RAW_EXT:
            from .raw_photo import inspect, pixels
            return pixels(frame if frame.raw else inspect(frame.path, frame.id, 'camera'), scale, gray)
        if ext in HEIF_EXT or (ext not in JPEG_EXT and ext not in {".png", ".tif", ".tiff"}):
            with Image.open(frame.path) as im:
                im = im.convert("L" if gray else "RGB")
                arr = np.asarray(im)
            img = arr if gray else cv2.cvtColor(arr, cv2.COLOR_RGB2BGR)
            img = _apply_orientation(img, frame.orientation)
        else:
            buf = _read_bytes(frame.path)
            factor = int(round(1 / scale)) if ext in JPEG_EXT else 1
            if factor in (2, 4, 8):
                flags = _REDUCED[(factor, gray)]
            else:
                flags = cv2.IMREAD_GRAYSCALE if gray else cv2.IMREAD_COLOR
            img = cv2.imdecode(buf, flags | cv2.IMREAD_IGNORE_ORIENTATION)
            if img is None:
                return None
            img = _apply_orientation(img, frame.orientation)
            if factor in (2, 4, 8):
                return img
        if scale < 0.999:
            w = max(1, int(round(img.shape[1] * scale)))
            h = max(1, int(round(img.shape[0] * scale)))
            img = cv2.resize(img, (w, h), interpolation=cv2.INTER_AREA)
        return img
    except Exception:
        return None


def load_max_side(frame: SourceFrame, max_side: int, gray: bool = False) -> np.ndarray | None:
    """Decode with the long side resized to `max_side` (uses the fastest DCT scale that is large enough)."""
    long_side = max(frame.pixelWidth, frame.pixelHeight)
    need = min(1.0, max_side / long_side)
    s = 1.0
    while s / 2 >= need and s > 0.125 + 1e-9:
        s /= 2
    img = load_image(frame, s, gray)
    if img is None:
        return None
    ls = max(img.shape[:2])
    if ls > max_side:
        k = max_side / ls
        img = cv2.resize(img, (max(1, round(img.shape[1] * k)), max(1, round(img.shape[0] * k))), interpolation=cv2.INTER_AREA)
    return img


def read_file_image(path: str, flags=cv2.IMREAD_COLOR) -> np.ndarray | None:
    try:
        return cv2.imdecode(_read_bytes(path), flags)
    except Exception:
        return None


def load_thumbnail(path: str, max_side: int = 160) -> np.ndarray | None:
    """Small BGR preview for the import dialog (fast: JPEG decoded at 1/8 when possible)."""
    if Path(path).suffix.lower() in RAW_EXT:
        try:
            frame = read_frame(path, 0)
            return load_max_side(frame, max_side)
        except (ValueError, OSError):
            return None
    img = read_file_image(path, cv2.IMREAD_REDUCED_COLOR_8)
    if img is None:
        try:
            with Image.open(path) as im:
                im = im.convert("RGB")
                im.thumbnail((max_side, max_side))
                img = cv2.cvtColor(np.asarray(im), cv2.COLOR_RGB2BGR)
        except Exception:
            return None
    h, w = img.shape[:2]
    k = max_side / max(h, w)
    if k < 1:
        img = cv2.resize(img, (max(1, round(w * k)), max(1, round(h * k))), interpolation=cv2.INTER_AREA)
    return img


def write_jpeg(img: np.ndarray, path: str, quality: int = 90) -> bool:
    ok, data = cv2.imencode(".jpg", img, [cv2.IMWRITE_JPEG_QUALITY, quality])
    if ok:
        data.tofile(path)
    return bool(ok)


# ---------------------------------------------------------------------------------------------- import


def _ratio(v):
    try:
        return float(v)
    except Exception:
        try:
            return v[0] / v[1]
        except Exception:
            return None


def clean_exif_text(value):
    if isinstance(value, bytes):
        value = value.decode("utf-8", errors="replace")
    if not isinstance(value, str):
        return None
    end = len(value)
    while end and (value[end-1].isspace() or unicodedata.category(value[end-1]) == "Cc"):
        end -= 1
    return value[:end].lstrip() or None


def exif_metadata(exif):
    sub = exif.get_ifd(0x8769) if exif else {}
    info = ExifInfo()
    info.make = clean_exif_text(exif.get(0x010F))
    info.model = clean_exif_text(exif.get(0x0110))
    info.lens = clean_exif_text(sub.get(0xA434))
    info.focalLength = _ratio(sub.get(0x920A)) if sub else None
    info.exposureTime = _ratio(sub.get(0x829A)) if sub else None
    info.fNumber = _ratio(sub.get(0x829D)) if sub else None
    iso = sub.get(0x8827) if sub else None
    if isinstance(iso, (tuple, list)):
        iso = iso[0] if iso else None
    info.iso = int(iso) if iso else None
    dto = (sub.get(0x9003) if sub else None) or exif.get(0x0132)
    info.dateTimeOriginal = dto
    t = None
    if dto:
        try:
            d = datetime.strptime(dto.strip(), "%Y:%m:%d %H:%M:%S").replace(tzinfo=timezone.utc)
            t = d.timestamp()
            subsec = (sub.get(0x9291) or sub.get(0x9290)) if sub else None
            if subsec:
                digits = str(subsec).strip()
                if digits.isdigit():
                    t += float("0." + digits)
        except Exception:
            t = None
    return info, t


def read_frame(path: str, id: int, raw_mode='camera') -> SourceFrame | None:
    if Path(path).suffix.lower() in RAW_EXT:
        from .raw_photo import inspect
        return inspect(path, id, raw_mode)
    try:
        with Image.open(path) as im:
            w, h = im.size
            exif = im.getexif()
            orientation = int(exif.get(0x0112, 1) or 1)
            info, t = exif_metadata(exif)
    except Exception:
        return None
    if w <= 0 or h <= 0:
        return None
    if orientation >= 5:
        w, h = h, w
    st = os.stat(path)
    return SourceFrame(id=id, path=os.path.abspath(path), pixelWidth=w, pixelHeight=h, orientation=orientation,
                       captureTime=t, fileSize=st.st_size, modified=st.st_mtime, exif=info)


def _images_in(folder: str) -> list[str]:
    try:
        names = os.listdir(folder)
    except OSError:
        return []
    return [os.path.join(folder, n) for n in names if not n.startswith(".") and Path(n).suffix.lower() in SUPPORTED_EXT
            and os.path.isfile(os.path.join(folder, n))]


def collect_image_paths(paths: list[str], max_depth: int = 2, limit: int | None = None) -> list[str]:
    """Image files of the given files / folders. A folder without photos of its own is searched one or two
    levels deep (e.g. a parent folder holding one sub-folder per burst); bursts are split by time later."""
    out = []
    for p in paths:
        p = os.path.normpath(p)
        if os.path.isdir(p):
            found = _images_in(p)
            level = [p]
            depth = 0
            while not found and depth < max_depth:
                nxt = []
                for d in level:
                    try:
                        nxt += [os.path.join(d, n) for n in sorted(os.listdir(d))
                                if not n.startswith(".") and os.path.isdir(os.path.join(d, n))]
                    except OSError:
                        pass
                for d in nxt:
                    found += _images_in(d)
                level, depth = nxt, depth + 1
            out += found
        elif os.path.isfile(p) and Path(p).suffix.lower() in SUPPORTED_EXT:
            out.append(p)
        if limit is not None and len(out) > limit:
            raise ValueError(f'找到超过 {limit:,} 张照片；请缩小选择范围')
    return list(dict.fromkeys(os.path.abspath(p) for p in out))


def _natural_key(s: str):
    import re
    return [int(t) if t.isdigit() else t.lower() for t in re.split(r"(\d+)", s)]


class PhotoImportCancelled(Exception):
    pass


def import_frames(paths: list[str], *, read=None, raw_mode='camera', pair_policy='jpeg', progress=lambda done,total: None,
                  cancelled=lambda: False, rejected=lambda path,error: None) -> list[SourceFrame]:
    files = collect_image_paths(paths)
    if read is None:
        read = lambda path,i: read_frame(path, i, raw_mode)
    def inspect(item):
        i, path = item
        try:
            frame = read(path, i)
            return frame, None if frame else '无法读取图像或元数据'
        except (OSError, ValueError, TypeError, OverflowError) as error:
            return None, str(error)
    frames = []
    with ThreadPoolExecutor(max_workers=min(16, (os.cpu_count() or 4))) as ex:
        for start in range(0, len(files), 32):
            if cancelled():
                raise PhotoImportCancelled()
            batch = enumerate(files[start:start+32], start=start)
            for i, (frame, error) in enumerate(ex.map(inspect, batch), start=start):
                if cancelled():
                    raise PhotoImportCancelled()
                if frame is not None: frames.append(frame)
                else: rejected(files[i], error)
                progress(i+1, len(files))

    if pair_policy not in ('jpeg','raw','both'):
        raise ValueError('无效的 RAW+JPEG 导入策略')
    if pair_policy != 'both':
        def pair_key(frame):
            return os.path.normcase(str(Path(frame.path).with_suffix('')))
        preferred = {}
        for frame in frames:
            ext = Path(frame.path).suffix.lower()
            if ext in (JPEG_EXT if pair_policy == 'jpeg' else RAW_EXT):
                preferred.setdefault(pair_key(frame), []).append(frame)
        def is_alternate(frame):
            ext = Path(frame.path).suffix.lower()
            if ext not in (RAW_EXT if pair_policy == 'jpeg' else JPEG_EXT):
                return False
            return any(frame.captureTime is None or other.captureTime is None or
                       abs(frame.captureTime-other.captureTime) < .51 for other in preferred.get(pair_key(frame), ()))
        frames = [frame for frame in frames if not is_alternate(frame)]
    # sort by time; equal timestamps (within 0.1 ms) fall back to file name order
    frames.sort(key=lambda f: _natural_key(f.file_name))
    frames.sort(key=lambda f: round(f.captureTime, 4) if f.captureTime is not None else float("inf"))
    for i, f in enumerate(frames):
        f.id = i
    return frames


def estimate_fps(frames: list[SourceFrame]) -> float:
    t = [f.captureTime for f in frames if f.captureTime is not None]
    if len(t) < 3:
        return 30.0
    dts = [b - a for a, b in zip(t, t[1:]) if 0.001 < b - a < 1]
    m = median(dts)
    if not m or m <= 0:
        return 30.0
    fps = 1 / m
    for c in (10.0, 12, 15, 20, 24, 25, 30, 40, 50, 60, 120):
        if abs(fps - c) / c < 0.08:
            return float(c)
    return fps


def segments(frames: list[SourceFrame]) -> list[BurstSegment]:
    if not frames:
        return []
    fps = estimate_fps(frames)
    gap = max(0.5, 6.0 / fps)
    segs, start = [], 0
    for i in range(1, len(frames)):
        a, b = frames[i - 1].captureTime, frames[i].captureTime
        if a is not None and b is not None and b - a > gap:
            segs.append(BurstSegment(start, i, estimate_fps(frames[start:i])))
            start = i
    segs.append(BurstSegment(start, len(frames), estimate_fps(frames[start:])))
    return segs
