"""User settings (port of Composition.swift, ExportSettings.swift, FrameRenderer.LookSettings, FrameSelection).

All settings are dataclasses that round-trip through JSON. Loading is tolerant: missing or invalid keys
keep their defaults, so settings saved by older versions never break.
"""
from __future__ import annotations

import dataclasses
from dataclasses import dataclass, field
from enum import Enum
from typing import Any


class Choice(str, Enum):
    """String enum with a Chinese display title."""

    @property
    def title(self) -> str:  # overridden by TITLES
        return TITLES.get(self, self.value)


class LockPoint(Choice):
    EYE = "eye"
    HEAD_CENTER = "headCenter"


class SizeMode(Choice):
    LOCK_SIZE = "lockSize"
    FIXED_CROP = "fixedCrop"


class RotationMode(Choice):
    NONE = "none"
    LOCK_HEAD = "lockHead"
    FOLLOW_HEAD_SMOOTH = "followHeadSmooth"


class EdgeFill(Choice):
    SHIFT = "shift"
    AUTO_ZOOM = "autoZoom"
    BLUR_EXTEND = "blurExtend"
    BLACK = "black"


class VideoCodec(Choice):
    H264 = "h264"
    HEVC = "hevc"
    PRORES_422HQ = "proRes422HQ"
    PRORES_4444 = "proRes4444"

    @property
    def ext(self) -> str:
        return "mp4" if self in (VideoCodec.H264, VideoCodec.HEVC) else "mov"


class VideoQuality(Choice):
    STANDARD = "standard"
    HIGH = "high"
    MAX = "max"

    @property
    def bpp(self) -> float:
        return {"standard": 0.08, "high": 0.15, "max": 0.28}[self.value]


class FrameInterpolation(Choice):
    NEAREST = "nearest"
    BLEND = "blend"
    AI = "ai"


class LoopMode(Choice):
    FORWARD = "forward"
    REVERSE = "reverse"
    PING_PONG = "pingPong"


class OverlayCorner(Choice):
    TOP_LEFT = "topLeft"
    TOP_RIGHT = "topRight"
    BOTTOM_LEFT = "bottomLeft"
    BOTTOM_RIGHT = "bottomRight"


class FocusMarkStyle(Choice):
    BOX = "box"
    BRACKETS = "brackets"


class FocusMarkColor(Choice):
    GREEN = "green"
    WHITE = "white"
    ORANGE = "orange"

    @property
    def bgr(self) -> tuple[int, int, int]:
        r, g, b = {"green": (0.30, 0.92, 0.36), "white": (1, 1, 1), "orange": (1.0, 0.62, 0.12)}[self.value]
        return int(b * 255), int(g * 255), int(r * 255)


TITLES: dict[Choice, str] = {
    LockPoint.EYE: "鸟眼（遮挡时自动用鸟头）", LockPoint.HEAD_CENTER: "鸟头中心",
    SizeMode.LOCK_SIZE: "锁定鸟的大小", SizeMode.FIXED_CROP: "固定取景（鸟自然远近）",
    RotationMode.NONE: "不旋转", RotationMode.LOCK_HEAD: "锁定头部角度", RotationMode.FOLLOW_HEAD_SMOOTH: "柔和校正倾斜",
    EdgeFill.SHIFT: "平移取景，用满原图（推荐）", EdgeFill.AUTO_ZOOM: "放大避免越界（鸟始终锁定）",
    EdgeFill.BLUR_EXTEND: "模糊延展填充", EdgeFill.BLACK: "黑边",
    VideoCodec.H264: "H.264（兼容性最好）", VideoCodec.HEVC: "HEVC / H.265（体积小）",
    VideoCodec.PRORES_422HQ: "ProRes 422 HQ（后期剪辑）", VideoCodec.PRORES_4444: "ProRes 4444",
    VideoQuality.STANDARD: "标准", VideoQuality.HIGH: "高", VideoQuality.MAX: "极高",
    FrameInterpolation.NEAREST: "重复帧（清晰）", FrameInterpolation.BLEND: "帧混合（顺滑）",
    FrameInterpolation.AI: "光流补帧（最顺滑，导出较慢）",
    LoopMode.FORWARD: "正放", LoopMode.REVERSE: "倒放", LoopMode.PING_PONG: "往返（正放+倒放）",
    OverlayCorner.TOP_LEFT: "左上", OverlayCorner.TOP_RIGHT: "右上",
    OverlayCorner.BOTTOM_LEFT: "左下", OverlayCorner.BOTTOM_RIGHT: "右下",
    FocusMarkStyle.BOX: "方框（索尼鸟眼对焦）", FocusMarkStyle.BRACKETS: "四角框（追踪框）",
    FocusMarkColor.GREEN: "绿色", FocusMarkColor.WHITE: "白色", FocusMarkColor.ORANGE: "橙色",
}


# ---------------------------------------------------------------------------------------------- base


class Settings:
    """Mixin: tolerant JSON round-trip for dataclasses (nested dataclasses and Choice enums included)."""

    def to_dict(self) -> dict[str, Any]:
        out = {}
        for f in dataclasses.fields(self):
            v = getattr(self, f.name)
            if isinstance(v, Settings):
                v = v.to_dict()
            elif isinstance(v, Enum):
                v = v.value
            out[f.name] = v
        return out

    @classmethod
    def from_dict(cls, d: Any):
        obj = cls()
        if not isinstance(d, dict):
            return obj
        for f in dataclasses.fields(cls):
            if f.name not in d:
                continue
            cur = getattr(obj, f.name)
            raw = d[f.name]
            try:
                if isinstance(cur, Settings):
                    val = type(cur).from_dict(raw)
                elif isinstance(cur, Enum):
                    val = type(cur)(raw)
                elif isinstance(cur, bool):
                    val = bool(raw)
                elif isinstance(cur, int) and not isinstance(cur, bool):
                    val = int(raw)
                elif isinstance(cur, float):
                    val = float(raw)
                else:
                    val = raw
            except (ValueError, TypeError):
                continue
            setattr(obj, f.name, val)
        return obj

    def copy(self):
        return type(self).from_dict(self.to_dict())


# ---------------------------------------------------------------------------------------------- composition


@dataclass
class Composition(Settings):
    lockPoint: LockPoint = LockPoint.EYE
    anchorX: float = 0.5          # anchor position in the output (0…1, top-left origin)
    anchorY: float = 0.45
    autoLeadRoom: bool = True     # mirror anchorX when the bird flies to the left
    framing: float = 14.0         # output short side = framing × head length
    sizeMode: SizeMode = SizeMode.LOCK_SIZE
    sizeSmoothing: float = 12.0
    rotationMode: RotationMode = RotationMode.NONE
    rotationOffsetDeg: float = 0.0
    followSoftness: float = 0.0   # 0 = hard lock … 1 = soft camera follow
    edgeFill: EdgeFill = EdgeFill.SHIFT
    edgeMargin: float = 0.12
    maxEdgeZoom: float = 1.6


FRAMING_RANGE = (2.0, 300.0)


@dataclass(frozen=True)
class CompositionPreset:
    id: str
    name: str
    detail: str
    composition: Composition


def _presets() -> list[CompositionPreset]:
    def c(**kw):
        x = Composition()
        for k, v in kw.items():
            setattr(x, k, v)
        return x
    return [
        CompositionPreset("center", "鸟眼居中", "鸟眼锁定在画面正中，最经典的锁头效果",
                          c(anchorX=0.5, anchorY=0.5, autoLeadRoom=False, framing=14)),
        CompositionPreset("lead", "前方留白", "鸟眼在三分线附近，飞行方向留出空间",
                          c(anchorX=0.36, anchorY=0.42, autoLeadRoom=True, framing=14)),
        CompositionPreset("closeup", "头部特写", "放大鸟头，锁定头部角度，强调眼神",
                          c(anchorX=0.5, anchorY=0.45, autoLeadRoom=False, framing=6, rotationMode=RotationMode.LOCK_HEAD)),
        CompositionPreset("wide", "全身舒展", "取景宽松，完整展示振翅",
                          c(anchorX=0.42, anchorY=0.4, autoLeadRoom=True, framing=26)),
        CompositionPreset("cine", "电影跟随", "镜头柔和跟随，鸟在画面中轻微浮动",
                          c(anchorX=0.4, anchorY=0.45, autoLeadRoom=True, framing=18, followSoftness=0.45,
                            rotationMode=RotationMode.FOLLOW_HEAD_SMOOTH)),
        CompositionPreset("natural", "自然远近", "鸟头锁定，大小随距离自然变化",
                          c(anchorX=0.5, anchorY=0.5, autoLeadRoom=False, framing=20, sizeMode=SizeMode.FIXED_CROP)),
    ]


PRESETS = _presets()


@dataclass
class AspectRatio(Settings):
    w: float = 3.0
    h: float = 4.0
    label: str = "3:4 小红书"

    @property
    def value(self) -> float:
        return self.w / self.h


ASPECT_PRESETS = [
    AspectRatio(9, 16, "9:16 竖屏"), AspectRatio(3, 4, "3:4 小红书"), AspectRatio(4, 5, "4:5"),
    AspectRatio(1, 1, "1:1"), AspectRatio(5, 4, "5:4"), AspectRatio(4, 3, "4:3"), AspectRatio(3, 2, "3:2"),
    AspectRatio(16, 9, "16:9"), AspectRatio(1.85, 1, "1.85:1 电影"), AspectRatio(2, 1, "2:1"),
    AspectRatio(2.39, 1, "2.39:1 宽银幕"), AspectRatio(21, 9, "21:9"),
]


# ---------------------------------------------------------------------------------------------- look & selection


@dataclass
class LookSettings(Settings):
    deflicker: bool = True
    deflickerStrength: float = 1.0
    deflickerWindow: float = 8.0
    exposureEV: float = 0.0


@dataclass
class FrameSelection(Settings):
    trimStart: int = 0
    trimEnd: int = -1            # inclusive; -1 = last
    dropBlurry: bool = False
    blurThreshold: float = 0.55  # relative to the sequence median sharpness
    dropUntracked: bool = True


# ---------------------------------------------------------------------------------------------- export


@dataclass
class OverlaySettings(Settings):
    showExif: bool = False
    exifPerFrame: bool = False
    customText: str = ""
    corner: OverlayCorner = OverlayCorner.BOTTOM_LEFT
    textScale: float = 1.0
    opacity: float = 0.85


@dataclass
class FocusMarkSettings(Settings):
    enabled: bool = False
    style: FocusMarkStyle = FocusMarkStyle.BOX
    color: FocusMarkColor = FocusMarkColor.GREEN
    size: float = 1.0
    lineWidth: float = 1.0
    headWhenHidden: bool = True


@dataclass
class WatermarkSettings(Settings):
    enabled: bool = False
    imagePath: str = ""
    centerX: float = 0.84
    centerY: float = 0.88
    size: float = 0.28          # width as a fraction of the output short side
    opacity: float = 0.9

    @property
    def active(self) -> bool:
        return self.enabled and bool(self.imagePath)

    def rect(self, img_w: int, img_h: int, out_w: float, out_h: float) -> tuple[float, float, float, float]:
        """(x, y, w, h) in output pixels, top-left origin."""
        if img_w <= 0 or img_h <= 0:
            return 0, 0, 0, 0
        w = self.size * min(out_w, out_h)
        h = w * img_h / img_w
        return self.centerX * out_w - w / 2, self.centerY * out_h - h / 2, w, h


@dataclass
class AudioSettings(Settings):
    path: str = ""
    startOffset: float = 0.0
    volume: float = 1.0
    fadeIn: float = 0.3
    fadeOut: float = 1.0
    loop: bool = True

    @property
    def active(self) -> bool:
        return bool(self.path) and self.volume > 0.001


@dataclass
class ExportSettings(Settings):
    aspect: AspectRatio = field(default_factory=lambda: AspectRatio(3, 4, "3:4 小红书"))
    shortSide: int = 1440
    outputFPS: float = 30.0
    speed: float = 1.0
    interpolation: FrameInterpolation = FrameInterpolation.NEAREST
    loop: LoopMode = LoopMode.FORWARD
    repeatCount: int = 1
    codec: VideoCodec = VideoCodec.HEVC
    quality: VideoQuality = VideoQuality.HIGH
    fadeInSeconds: float = 0.0
    fadeOutSeconds: float = 0.0
    overlay: OverlaySettings = field(default_factory=OverlaySettings)
    focusMark: FocusMarkSettings = field(default_factory=FocusMarkSettings)
    useFullResolution: bool = True
    encoder: str = "auto"       # auto | software | nvenc | amf | qsv | videotoolbox

    @property
    def output_size(self) -> tuple[int, int]:
        r = self.aspect.value
        if r >= 1:
            h = float(self.shortSide)
            w = h * r
        else:
            w = float(self.shortSide)
            h = w / r
        return int(round(w / 2)) * 2, int(round(h / 2)) * 2


SHORT_SIDE_PRESETS = [720, 1080, 1440, 2160, 2880, 4320]
FPS_PRESETS = [24.0, 25.0, 30.0, 48.0, 50.0, 60.0, 120.0]
SPEED_PRESETS = [0.1, 0.2, 0.25, 1.0 / 3, 0.5, 2.0 / 3, 1.0, 1.5, 2.0]
