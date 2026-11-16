"""Read camera previews or render RAW to sRGB without editing the original."""
from contextlib import contextmanager
from datetime import timezone
from io import BytesIO
from pathlib import Path
from threading import BoundedSemaphore

import cv2
import numpy as np
from PIL import Image, ImageCms

RAW_EXT = {'.arw', '.nef', '.nrw', '.cr2', '.cr3', '.raf', '.dng', '.rw2', '.orf', '.pef', '.srw'}
RAW_MODES = ('camera', 'raw')
_decode_slots = BoundedSemaphore(2)
_raw_orientation = {0: 1, 3: 3, 5: 8, 6: 6}


@contextmanager
def _opened(path):
    try:
        import rawpy
    except ImportError as error:
        raise ValueError('缺少 RAW 解码组件；请使用完整安装包，或先在相机软件中转换为 JPEG。') from error
    try:
        with _decode_slots, rawpy.imread(str(path)) as raw:
            yield rawpy, raw
    except (rawpy.LibRawError, OSError) as error:
        raise ValueError('无法读取该 RAW 或压缩格式；可尝试相机内直出 JPEG 或转换为 DNG。') from error


def _preview(rawpy, raw):
    try:
        thumb = raw.extract_thumb()
    except rawpy.LibRawError:
        return None
    if thumb.format == rawpy.ThumbFormat.JPEG:
        try:
            with Image.open(BytesIO(thumb.data)) as image:
                exif = Image.Exif()
                if encoded_exif := image.info.get('exif'):
                    exif.load(encoded_exif)
                profile = image.info.get('icc_profile')
                rgb = image.convert('RGB')
                if profile:
                    rgb = ImageCms.profileToProfile(rgb, BytesIO(profile), ImageCms.createProfile('sRGB'), outputMode='RGB')
                return np.asarray(rgb), exif
        except (ImageCms.PyCMSError, OSError, ValueError, SyntaxError):
            return None
    if thumb.format == rawpy.ThumbFormat.BITMAP:
        return thumb.data, None
    return None


def inspect(path, id, mode):
    from .frames import SourceFrame, clean_exif_text, exif_metadata

    if mode not in RAW_MODES:
        raise ValueError('无效的 RAW 渲染策略')
    with _opened(path) as (rawpy, raw):
        sizes = raw.sizes
        orientation = _raw_orientation.get(sizes.flip, 1)
        full_w, full_h = sizes.width, sizes.height
        preview = _preview(rawpy, raw)
        exif = preview[1] if preview is not None else None
        info, captured = exif_metadata(exif or Image.Exif())
        if exif and exif.get(0x0112) in range(1, 9):
            orientation = int(exif[0x0112])
        try:
            with Image.open(path) as container:
                outer = container.getexif()
                if outer:
                    metadata, date = exif_metadata(outer)
                    for key, value in vars(metadata).items():
                        if value is not None:
                            setattr(info, key, value)
                    if date is not None:
                        captured = date
                    if outer.get(0x0112) in range(1, 9):
                        orientation = int(outer[0x0112])
        except (OSError, ValueError, SyntaxError):
            pass
        other = raw.other
        if captured is None and other.timestamp and other.timestamp.year > 1970:
            captured = other.timestamp.replace(tzinfo=timezone.utc).timestamp()
            info.dateTimeOriginal = other.timestamp.strftime('%Y:%m:%d %H:%M:%S')
        if not info.lens:
            info.lens = clean_exif_text(raw.lens.model)
        for field, source in (('iso', 'iso_speed'), ('focalLength', 'focal_length'),
                              ('exposureTime', 'shutter_speed'), ('fNumber', 'aperture')):
            value = getattr(other, source)
            if not getattr(info, field) and value and np.isfinite(value) and value > 0:
                setattr(info, field, int(value) if field == 'iso' else float(value))
        if mode == 'camera' and preview is not None:
            h, w = preview[0].shape[:2]
            source = 'embedded'
        else:
            try:
                # Metadata access may already have unpacked this handle.
                _ = raw.raw_image.shape
                w, h, source = full_w, full_h, 'decoded'
            except rawpy.LibRawError:
                if preview is None:
                    raise
                h, w = preview[0].shape[:2]
                source = 'embedded'
        if orientation >= 5:
            w, h, full_w, full_h = h, w, full_h, full_w
    st = Path(path).stat()
    return SourceFrame(id, str(Path(path).absolute()), w, h, orientation, captured, st.st_size,
                       st.st_mtime, info, dict(mode=mode, source=source, fullWidth=full_w, fullHeight=full_h))


def pixels(frame, scale, gray):
    from .frames import _apply_orientation

    with _opened(frame.path) as (rawpy, raw):
        if frame.raw['source'] == 'embedded':
            embedded = _preview(rawpy, raw)
            if embedded is None:
                raise ValueError('RAW 机内预览不可用，请重新导入并选择高分辨率解码。')
            rgb = embedded[0]
        else:
            rgb = raw.postprocess(use_camera_wb=True, output_color=rawpy.ColorSpace.sRGB,
                                  output_bps=8, user_flip=0, half_size=scale <= .5)
    image = _apply_orientation(cv2.cvtColor(rgb, cv2.COLOR_RGB2GRAY if gray else cv2.COLOR_RGB2BGR), frame.orientation)
    if scale < .999:
        target = (max(1, round(frame.pixelWidth*scale)), max(1, round(frame.pixelHeight*scale)))
        if target[0] < image.shape[1] or target[1] < image.shape[0]:
            image = cv2.resize(image, target, interpolation=cv2.INTER_AREA)
    return image


def fingerprint_suffix(frame):
    try:
        import rawpy
        version = '.'.join(map(str, rawpy.libraw_version))
    except ImportError:
        version = 'unavailable'
    return f"|raw-v1:{version}:{frame.raw['mode']}:{frame.raw['source']}"


def has_preview_limit(frame):
    if not frame.raw or frame.raw.get('source') != 'embedded':
        return False
    width, height = frame.raw['fullWidth'], frame.raw['fullHeight']
    return (width == 0 or height == 0 or
            frame.pixelWidth < width * .95 or frame.pixelHeight < height * .95)


def quality_notices(frames):
    limited = [f for f in frames if has_preview_limit(f)]
    fallback = sum(bool(f.raw and ((f.raw['mode']=='camera') != (f.raw['source']=='embedded'))) for f in frames)
    notices = []
    if fallback:
        notices.append(f'{fallback} 张 RAW 按可用图像降级')
    if limited:
        w, h = limited[0].pixelWidth, limited[0].pixelHeight
        notices.append(f'{len(limited)} 张 RAW 的机内预览有分辨率限制（首张 {w}×{h}）；全分辨率导出需重新导入并选择高分辨率 RAW。')
    return notices
