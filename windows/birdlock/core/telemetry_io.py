"""Read-only bridge to the bundled, fixed-revision telemetry-parser helper."""
from __future__ import annotations

import json
import math
import os
from pathlib import Path
import subprocess
import tempfile
import time

from .gpu import _hidden_startupinfo
from .paths import resource_dir


class TelemetryCancelled(Exception):
    pass


def helper_path():
    explicit = os.environ.get('BIRDLOCK_TELEMETRY_HELPER')
    if explicit and Path(explicit).is_file():
        return str(Path(explicit).resolve())
    executable = 'BirdLockTelemetry.exe' if os.name == 'nt' else 'BirdLockTelemetry'
    root = Path(__file__).resolve().parents[3]
    candidates = [resource_dir() / 'telemetry' / executable,
                  root / 'dist' / 'telemetry' / ('windows' if os.name == 'nt' else 'macos') / executable,
                  root / 'dist' / 'telemetry' / executable,
                  root / 'tools' / 'telemetry' / 'target' / 'release' / ('birdlock-telemetry.exe' if os.name == 'nt' else 'birdlock-telemetry')]
    return next((str(p) for p in candidates if p.is_file()), None)


def validate_report(report):
    if not isinstance(report, dict) or report.get('schema') != 1 or report.get('gyroUnit') != 'rad/s' or report.get('timestampUnit') != 's':
        raise ValueError('陀螺仪数据格式或单位无效')
    if (report.get('orientation') != 'XYZ' or report.get('imuFrame') != 'gyroflow-x-up-y-left-z-back'
            or report.get('cameraFrame') != 'opencv-x-right-y-down-z-forward'
            or report.get('imuToCamera') != [[0, -1, 0], [-1, 0, 0], [0, 0, -1]]):
        raise ValueError('陀螺仪坐标系无效')
    samples = report.get('samples')
    if not isinstance(samples, list) or len(samples) > 2_000_000:
        raise ValueError('陀螺仪数据量无效')
    previous = -math.inf
    for sample in samples:
        if not isinstance(sample, dict):
            raise ValueError('陀螺仪样本无效')
        t, gyro = sample.get('t'), sample.get('gyro')
        if not isinstance(t, (int, float)) or not math.isfinite(t) or t <= previous or not isinstance(gyro, list) or len(gyro) != 3 or not all(isinstance(v, (int, float)) and math.isfinite(v) for v in gyro):
            raise ValueError('陀螺仪时间戳或角速度无效')
        previous = t
    return report


def read_telemetry(source, *, probe=False, cancelled=lambda: False, timeout=120):
    """Returns schema-1 JSON, with t in seconds and gyro in rad/s on Gyroflow IMU axes.

    IMU X up, Y left, Z toward viewer; use imuToCamera for X right, Y down, Z forward.
    `timestampsAccurate` describes available source clocks. It is not proof of video synchronization.
    No telemetry is represented by samples=[]; unsupported input raises a visible error.
    """
    helper = helper_path()
    if not helper:
        raise RuntimeError('陀螺仪读取组件缺失，请重新安装完整应用')
    if cancelled():
        raise TelemetryCancelled()
    with tempfile.TemporaryDirectory(prefix='birdlock-telemetry-') as temporary:
        output = Path(temporary) / 'telemetry.json'
        command = [helper, '--input', str(Path(source).resolve()), '--output', str(output)]
        if probe:
            command.append('--probe')
        with tempfile.TemporaryFile() as errors:
            process = subprocess.Popen(command, stdout=subprocess.DEVNULL, stderr=errors, **_hidden_startupinfo())
            try:
                deadline = time.monotonic() + timeout
                while process.poll() is None:
                    if cancelled():
                        process.terminate()
                        raise TelemetryCancelled()
                    if time.monotonic() >= deadline:
                        process.kill()
                        raise TimeoutError('读取陀螺仪数据超时')
                    time.sleep(.04)
                if cancelled():
                    raise TelemetryCancelled()
                if process.returncode != 0 or not output.is_file():
                    errors.seek(0)
                    detail = errors.read(4096).decode('utf-8', errors='replace').strip()
                    try:
                        detail = json.loads(detail).get('error', detail)
                    except ValueError:
                        pass
                    raise ValueError('无法读取陀螺仪数据：' + detail)
                if output.stat().st_size > 256 * 1024 * 1024:
                    raise ValueError('陀螺仪数据超过支持范围')
                return validate_report(json.loads(output.read_text(encoding='utf-8')))
            finally:
                if process.poll() is None:
                    process.kill()
                process.wait()
