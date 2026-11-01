"""Validated subset of Gyroflow JSON profiles. No gyro or rolling-shutter correction."""
from __future__ import annotations

import json
from dataclasses import dataclass
from pathlib import Path

import cv2
import numpy as np


@dataclass
class LensProfile:
    name: str
    width: int
    height: int
    matrix: np.ndarray
    coefficients: np.ndarray
    model: str
    raw: bytes

    @classmethod
    def load(cls, path):
        if Path(path).suffix.lower() == '.xml':
            from .lens_catalog import import_xml
            match = import_xml(path)
            if not match.selected_url:
                raise ValueError('已读取索尼 XML。' + match.message)
            return cls.load(match.selected_url)
        raw = Path(path).read_bytes()
        if len(raw) > 1_048_576:
            raise ValueError('镜头配置文件过大（上限 1 MB）')
        try:
            d = json.loads(raw)
            model = d.get('distortion_model') or 'opencv_fisheye'
            if model not in ('opencv_fisheye', 'opencv_standard'):
                raise ValueError('暂不支持此镜头畸变模型：' + str(model))
            if d.get('digital_lens') or d.get('interpolations') or any(
                    d.get(key, 1) not in (None, 0, 1) for key in ('input_horizontal_stretch', 'input_vertical_stretch')):
                raise ValueError('暂不支持数字镜头、变焦插值或非等比拉伸配置')
            w, h = d['calib_dimension']['w'], d['calib_dimension']['h']
            if type(w) is not int or type(h) is not int or not (1 < w <= 32768 and 1 < h <= 32768):
                raise ValueError('镜头标定尺寸无效')
            k = np.asarray(d['fisheye_params']['camera_matrix'], dtype=np.float64)
            c = np.asarray(d['fisheye_params']['distortion_coeffs'], dtype=np.float64)
            if (k.shape != (3, 3) or c.ndim != 1 or not np.isfinite(k).all() or not np.isfinite(c).all()
                    or not np.allclose(k[2], [0, 0, 1], atol=1e-9) or abs(k[0, 1]) > 1e-9
                    or abs(k[1, 0]) > 1e-9 or min(k[0, 0], k[1, 1]) <= 0
                    or not (0 <= k[0, 2] < w and 0 <= k[1, 2] < h)
                    or len(c) not in ((4,) if model == 'opencv_fisheye' else (4, 5, 8))):
                raise ValueError('镜头矩阵或畸变系数无效 / 暂不支持')
            name = d.get('name') or ' '.join(str(d.get(key, '')) for key in ('camera_brand', 'camera_model', 'lens_model')).strip() or Path(path).stem
            return cls(str(name), w, h, k, c, model, raw)
        except (KeyError, TypeError, json.JSONDecodeError) as error:
            raise ValueError('不是有效的 Gyroflow 镜头 JSON 配置') from error

    def maps(self, width, height):
        if abs((width / height) / (self.width / self.height) - 1) > .002:
            raise ValueError('镜头配置与视频宽高比不一致；请选择相同拍摄模式的配置')
        k = self.matrix.copy()
        k[0] *= width / self.width
        k[1] *= height / self.height
        # Same output camera on both platforms. Lens calibration precedes subject tracking.
        if self.model == 'opencv_fisheye':
            return cv2.fisheye.initUndistortRectifyMap(k, self.coefficients, np.eye(3), k, (width, height), cv2.CV_32FC1)
        return cv2.initUndistortRectifyMap(k, self.coefficients, None, k, (width, height), cv2.CV_32FC1)

    def correct(self, image, maps=None):
        h, w = image.shape[:2]
        x, y = maps if maps is not None else self.maps(w, h)
        if not np.isfinite(x).all() or not np.isfinite(y).all():
            raise ValueError('镜头配置生成了无效坐标')
        return cv2.remap(image, x, y, cv2.INTER_LINEAR, borderMode=cv2.BORDER_CONSTANT)
