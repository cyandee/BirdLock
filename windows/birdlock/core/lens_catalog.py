"""A small verified offline Gyroflow profile catalogue with conservative camera/mode matching."""
from __future__ import annotations

from dataclasses import dataclass
from pathlib import Path
import hashlib
import json
import os
import unicodedata
from functools import lru_cache

from .camera_metadata import CameraMetadata, metadata_for_video, read_sony_xml, from_telemetry
from .paths import resource_dir

DATABASE_URL = 'https://github.com/gyroflow/lens_profiles'
CALIBRATION_URL = 'https://docs.gyroflow.xyz/app/getting-started/lens-calibration'
HELP_TEXT = ('先在 Gyroflow 的「镜头配置」中搜索相机、镜头、焦距和拍摄模式，选中对应配置后导出 JSON。'
             '数据库没有时，可按官方镜头标定教程创建配置。索尼相机的同名 XML 可直接导入，用于读取机身、镜头及拍摄模式。')


def _normalized(value):
    return ''.join(c for c in unicodedata.normalize('NFKD', str(value or '')).casefold() if c.isalnum())


@dataclass
class LensCatalogEntry:
    id: str
    title: str
    url: Path
    sourceURL: str
    cameraBrand: str
    cameraModels: list[str]
    lensModels: list[str]
    width: int
    height: int
    fps: float
    focalLength: float | None
    fixedFocalLength: bool
    fixedLens: bool
    settings: list[str]
    stabilizationModes: list[str]
    autoMatch: bool = True


@dataclass
class LensMatch:
    metadata: CameraMetadata
    candidates: list[LensCatalogEntry]
    selected: LensCatalogEntry | None = None
    message: str = ''

    @property
    def selected_url(self):
        return self.selected.url if self.selected else None


def directory():
    if os.environ.get('BIRDLOCK_LENS_PROFILES'):
        return Path(os.environ['BIRDLOCK_LENS_PROFILES'])
    for root in (resource_dir() / 'lens_profiles', Path(__file__).resolve().parents[3] / 'SharedResources/LensProfiles'):
        if (root / 'manifest.json').is_file(): return root
    return None


def entries(root=None):
    resolved=Path(root) if root else directory()
    if resolved is None:return []
    stat=(resolved/'manifest.json').stat()
    return list(_cached_entries(str(resolved.resolve()),stat.st_mtime_ns,stat.st_size))


@lru_cache(maxsize=4)
def _cached_entries(folder,modified,size):
    root=Path(folder)
    manifest = json.loads((root / 'manifest.json').read_text(encoding='utf-8'))
    result = []
    for value in manifest['profiles']:
        name = value['file']
        if Path(name).name != name or '..' in name:
            raise ValueError('内置镜头配置路径无效')
        path = root / name
        raw = path.read_bytes()
        if hashlib.sha256(raw).hexdigest() != value['sha256']:
            raise ValueError('内置镜头配置校验失败：' + value['title'])
        result.append(LensCatalogEntry(value['id'], value['title'], path, value['sourceURL'], value.get('cameraBrand',''), value['cameraModels'],
            value.get('lensModels', []), value['width'], value['height'], value['fps'], value.get('focalLength'),
            value.get('fixedFocalLength', False), value.get('fixedLens', False), value.get('settings', []),value.get('stabilizationModes',[]),value.get('autoMatch',True)))
    return result


def match(metadata: CameraMetadata, width, height, fps, root=None) -> LensMatch:
    if width <= 0 or height <= 0:
        return LensMatch(metadata, [], message='请先导入可读取尺寸的视频。')
    if not metadata.cameraModel:
        return LensMatch(metadata, [], message='未识别到相机型号，可选择内置组合或导入配置。')
    if metadata.width and metadata.height and (metadata.width != width or metadata.height != height):
        return LensMatch(metadata, [], message='XML 与视频的尺寸不同，请检查是否为对应文件。')
    camera, lens, mode = map(_normalized, (metadata.cameraModel, metadata.lensModel, metadata.cameraSetting))
    candidates, exact = [], []
    for entry in entries(root):
        if metadata.cameraBrand and entry.cameraBrand and not _normalized(metadata.cameraBrand).startswith(_normalized(entry.cameraBrand)): continue
        if camera not in [_normalized(v) for v in entry.cameraModels]: continue
        if abs((width / height) / (entry.width / entry.height) - 1) > .002: continue
        if fps and entry.fps and abs(fps - entry.fps) / entry.fps > .015: continue
        known_lenses = [_normalized(v) for v in entry.lensModels]
        if lens and known_lenses and lens not in known_lenses: continue
        if metadata.focalLength and entry.focalLength and abs(metadata.focalLength / entry.focalLength - 1) > .015: continue
        candidates.append(entry)
        lens_matches = (entry.fixedLens and not entry.lensModels) or (bool(lens) and lens in known_lenses)
        focal_matches = entry.focalLength is None or entry.fixedFocalLength or (metadata.focalLength is not None and abs(metadata.focalLength / entry.focalLength - 1) <= .015)
        mode_matches = ((not entry.settings and mode in ('','normal','default','fullframe'))
                        or (bool(mode) and mode in [_normalized(v) for v in entry.settings]))
        stabilization = _normalized(metadata.stabilizationMode)
        # Unspecified calibration settings cannot establish compatibility with a known EIS crop.
        stabilization_matches = (stabilization in [_normalized(v) for v in entry.stabilizationModes]
                                 if entry.stabilizationModes else stabilization in ('','off','false','0','noeis'))
        if (entry.autoMatch and lens_matches and focal_matches and mode_matches and stabilization_matches and not metadata.variableFocalLength
                and fps and fps > 0 and width == entry.width and height == entry.height):
            exact.append(entry)
    selected = exact[0] if len(exact) == 1 else None
    message = ('已匹配 ' + selected.title) if selected else ('找到候选，请确认镜头和拍摄模式。' if candidates else '没有精确匹配的内置组合，可导入配置或查看查找方法。')
    return LensMatch(metadata, candidates, selected, message)


def detect(video, width, height, fps, embedded=None, root=None):
    if embedded is None:
        try:
            from .telemetry_io import read_telemetry
            embedded=from_telemetry(read_telemetry(video,probe=True,timeout=30))
        except (OSError,ValueError,RuntimeError,TimeoutError):
            pass
    metadata = metadata_for_video(video).merged(embedded)
    return match(metadata, width, height, fps, root)


def import_xml(path, width=None, height=None, fps=None, root=None):
    metadata = read_sony_xml(path)
    width, height = width or metadata.width, height or metadata.height
    if not width or not height:
        return LensMatch(metadata, [], message='已读取索尼机身与镜头信息；请导入对应视频后选择配置。')
    return match(metadata, width, height, fps or metadata.fps, root)


def search(query, catalog=None):
    text=query.casefold()
    for local,brand in [('索尼','sony'),('佳能','canon'),('尼康','nikon'),('松下','panasonic'),('富士','fujifilm'),('大疆','dji'),('适马','sigma'),('腾龙','tamron')]:text=text.replace(local,brand)
    tokens=[_normalized(x) for x in text.split() if _normalized(x)]
    return [e for e in (entries() if catalog is None else catalog) if all(token in _normalized(' '.join([e.title,e.cameraBrand]+e.cameraModels+e.lensModels+e.settings)) for token in tokens)]
