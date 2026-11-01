"""Camera/lens identity from Sony's real NonRealTimeMeta XML, without inventing calibration."""
from __future__ import annotations

from dataclasses import asdict, dataclass
from pathlib import Path
import math
import re
import xml.etree.ElementTree as ET


@dataclass
class CameraMetadata:
    cameraBrand: str = ''
    cameraModel: str = ''
    lensModel: str = ''
    focalLength: float | None = None
    width: int | None = None
    height: int | None = None
    fps: float | None = None
    captureFPS: float | None = None
    cameraSetting: str = ''
    stabilizationMode: str = ''
    variableFocalLength: bool = False
    source: str = ''

    def to_dict(self):
        return asdict(self)

    @classmethod
    def from_dict(cls, value):
        if not isinstance(value, dict): return cls()
        return cls(**{k: v for k, v in value.items() if k in cls.__dataclass_fields__})

    def merged(self, preferred):
        """Prefer actual telemetry fields; preserve XML identity when a field is absent."""
        if preferred is None: return CameraMetadata.from_dict(self.to_dict())
        values = self.to_dict()
        for key, value in preferred.to_dict().items():
            if value is not None and value != '' and value is not False:
                values[key] = value
        return CameraMetadata.from_dict(values)

    @property
    def display_name(self):
        return ' · '.join(s for s in [self.cameraModel, self.lensModel] if s)


def _number(value):
    import math
    match = re.search(r'[-+]?(?:\d+(?:\.\d*)?|\.\d+)', str(value or ''))
    if not match: return None
    number = float(match[0])
    return number if math.isfinite(number) and number > 0 else None


def parse_sony_xml(data: bytes, source='sony-xml') -> CameraMetadata:
    if len(data) > 2_097_152:
        raise ValueError('索尼 XML 文件过大（上限 2 MB）')
    if any(token in data.replace(b'\0', b'').upper() for token in (b'<!DOCTYPE', b'<!ENTITY')):
        raise ValueError('XML 不支持 DTD 或外部实体')
    try: root = ET.fromstring(data)
    except ET.ParseError as error: raise ValueError('无法读取索尼 XML，请选择相机生成的原始 XML 文件') from error
    local = lambda name: name.rsplit('}', 1)[-1].rsplit(':', 1)[-1]
    if local(root.tag) != 'NonRealTimeMeta':
        raise ValueError('这不是索尼视频的 NonRealTimeMeta XML 文件')
    result = CameraMetadata(source=source)
    focal = []
    for element in root.iter():
        name = local(element.tag)
        attrs = element.attrib
        if name == 'Device':
            result.cameraBrand = attrs.get('manufacturer', '')[:256]
            result.cameraModel = attrs.get('modelName', '')[:256]
        elif name == 'Lens':
            result.lensModel = attrs.get('modelName', '')[:512]
            number = _number(attrs.get('focalLength'))
            if number: focal.append(number)
        elif name == 'VideoLayout':
            width, height = _number(attrs.get('pixel')), _number(attrs.get('numOfVerticalLine'))
            if width and height and width <= 32768 and height <= 32768:
                result.width, result.height = int(width), int(height)
        elif name == 'VideoFrame':
            result.fps = _number(attrs.get('formatFps'))
            result.captureFPS = _number(attrs.get('captureFps'))
        elif name == 'Item':
            key, value = attrs.get('name', '').lower(), attrs.get('value', '')
            if key in ('lensmodel', 'lensname', 'lensmodelname') and not result.lensModel:
                result.lensModel = value[:512]
            elif key in ('focallength', 'focallengthmm'):
                number = _number(value)
                if number: focal.append(number)
            elif key in ('shootingmode', 'sensorcropmode', 'videocapturemode'):
                result.cameraSetting = value[:256]
            elif key in ('imagestabilizer', 'steadyshot', 'stabilizationmode'):
                result.stabilizationMode = value[:256]
    if result.cameraBrand and 'sony' not in result.cameraBrand.casefold():
        raise ValueError('XML 的相机制造商不是 Sony')
    if not result.cameraModel:
        raise ValueError('索尼 XML 中没有相机型号')
    result.cameraBrand = result.cameraBrand or 'Sony'
    if focal:
        result.variableFocalLength = max(focal) > min(focal) * 1.002
        if not result.variableFocalLength: result.focalLength = focal[0]
    return result


def read_sony_xml(path) -> CameraMetadata:
    path = Path(path)
    if path.stat().st_size > 2_097_152:
        raise ValueError('索尼 XML 文件过大（上限 2 MB）')
    return parse_sony_xml(path.read_bytes())


def sony_sidecar(video):
    video = Path(video)
    names = {(video.stem + suffix).casefold() for suffix in ('M01.XML', '.XML')}
    try:
        candidates = [p for p in video.parent.iterdir() if p.is_file() and p.name.casefold() in names]
    except OSError: return None
    return next((p for p in sorted(candidates, key=lambda p: (not p.stem.casefold().endswith('m01'), p.name))), None)


def metadata_for_video(video) -> CameraMetadata:
    """Read a matching sidecar first, else a complete embedded XML document in bounded bytes."""
    video = Path(video)
    sidecar = sony_sidecar(video)
    if sidecar:
        # A malformed same-name XML is reported instead of silently loading a different camera.
        return read_sony_xml(sidecar)
    try:
        with video.open('rb') as file:
            size = video.stat().st_size
            chunks = [file.read(min(size, 8_388_608))]
            if size > 8_388_608:
                file.seek(max(8_388_608, size - 8_388_608))
                chunks.append(file.read(8_388_608))
        for chunk in chunks:
            start = chunk.find(b'<NonRealTimeMeta')
            if start < 0: continue
            end = chunk.find(b'</NonRealTimeMeta>', start)
            if end >= 0:
                return parse_sony_xml(chunk[start:end + len(b'</NonRealTimeMeta>')], 'embedded-sony-xml')
    except OSError:
        pass
    return CameraMetadata()


def from_telemetry(report) -> CameraMetadata:
    """Read explicit camera/FOV fields; missing stabilization mode stays unknown."""
    video=report.get('video') or {}
    result=CameraMetadata(cameraBrand=report.get('cameraBrand') or '',cameraModel=report.get('cameraModel') or '',source='embedded-telemetry')
    rate=video.get('fps')
    if isinstance(rate,(int,float)) and math.isfinite(rate) and rate>0:result.fps=rate
    lenses=set();modes=set();focals=[]
    fov={'W':'Wide','S':'Superview','H':'Hyperview','L':'Linear','N':'Narrow','M':'Medium','X':'Max SuperView'}
    for frame in report.get('rawMetadataFrames',[]):
        lens=frame.get('Lens') or {};default=frame.get('Default') or {};profile=lens.get('Data') or {}
        name=lens.get('DisplayName') or (profile.get('lens_model') if isinstance(profile,dict) else '')
        if isinstance(name,str) and name.strip():lenses.add(name.strip()[:512])
        focal=lens.get('FocalLength')
        if isinstance(focal,(int,float)) and math.isfinite(focal) and focal>0:focals.append(float(focal))
        if result.cameraBrand.casefold()=='gopro':
            value=default.get('0x56464f56',default.get('VFOV'))
            if isinstance(value,str) and value in fov:lenses.add(fov[value])
            eis=default.get('0x45495341',default.get('EISA'))
            if eis=='N':modes.add('off')
            elif eis=='Y':modes.add('on')
    if len(lenses)==1:result.lensModel=next(iter(lenses))
    elif len(lenses)>1:result.cameraSetting='mixed-modes'
    if len(modes)==1:result.stabilizationMode=next(iter(modes))
    elif len(modes)>1:result.stabilizationMode='mixed'
    if focals:
        result.variableFocalLength=max(focals)>min(focals)*1.002
        if not result.variableFocalLength:result.focalLength=focals[0]
    return result
