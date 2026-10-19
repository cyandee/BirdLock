"""Hardware acceleration: which GPU runs the neural networks, image processing and video encoding.

- Neural networks: ONNX Runtime with DirectML on Windows (any DirectX 12 GPU: NVIDIA, AMD, Intel),
  Core ML on macOS (development), CPU as fallback.
- Image warping / resizing: OpenCV's OpenCL path on the discrete GPU (optional).
- Video encoding: FFmpeg hardware encoders (NVENC, AMF, Quick Sync, VideoToolbox) with software fallback.

On laptops with both integrated and discrete graphics, "auto" picks the adapter with the most dedicated
video memory, i.e. the discrete GPU.
"""
from __future__ import annotations

import ctypes
import functools
import os
import subprocess
from dataclasses import dataclass

from .paths import IS_MAC, IS_WINDOWS, ffmpeg_path


@dataclass
class Adapter:
    index: int            # DXGI enumeration index (= DirectML device_id)
    name: str
    vendor_id: int
    dedicated_mb: int
    software: bool

    @property
    def vendor(self) -> str:
        return {0x10DE: "NVIDIA", 0x1002: "AMD", 0x1022: "AMD", 0x8086: "Intel"}.get(self.vendor_id, "")

    @property
    def discrete(self) -> bool:
        return not self.software and self.dedicated_mb >= 1024


@functools.lru_cache(maxsize=1)
def list_adapters() -> tuple[Adapter, ...]:
    """Enumerate DXGI adapters (Windows only; empty elsewhere or on failure)."""
    if not IS_WINDOWS:
        return ()
    try:
        return tuple(_dxgi_adapters())
    except Exception:
        return ()


def _dxgi_adapters():
    from ctypes import wintypes

    class LUID(ctypes.Structure):
        _fields_ = [("LowPart", wintypes.DWORD), ("HighPart", wintypes.LONG)]

    class DXGI_ADAPTER_DESC1(ctypes.Structure):
        _fields_ = [("Description", wintypes.WCHAR * 128), ("VendorId", wintypes.UINT), ("DeviceId", wintypes.UINT),
                    ("SubSysId", wintypes.UINT), ("Revision", wintypes.UINT), ("DedicatedVideoMemory", ctypes.c_size_t),
                    ("DedicatedSystemMemory", ctypes.c_size_t), ("SharedSystemMemory", ctypes.c_size_t),
                    ("AdapterLuid", LUID), ("Flags", wintypes.UINT)]

    class GUID(ctypes.Structure):
        _fields_ = [("Data1", wintypes.DWORD), ("Data2", wintypes.WORD), ("Data3", wintypes.WORD), ("Data4", ctypes.c_ubyte * 8)]

    # IID_IDXGIFactory1 = 770aae78-f26f-4dba-a829-253c83d1b387
    iid = GUID(0x770AAE78, 0xF26F, 0x4DBA, (ctypes.c_ubyte * 8)(0xA8, 0x29, 0x25, 0x3C, 0x83, 0xD1, 0xB3, 0x87))
    dxgi = ctypes.WinDLL("dxgi")
    factory = ctypes.c_void_p()
    if dxgi.CreateDXGIFactory1(ctypes.byref(iid), ctypes.byref(factory)) != 0:
        return []

    def method(obj, index, restype, *argtypes):
        vtbl = ctypes.cast(ctypes.cast(obj, ctypes.POINTER(ctypes.c_void_p))[0], ctypes.POINTER(ctypes.c_void_p))
        return ctypes.WINFUNCTYPE(restype, ctypes.c_void_p, *argtypes)(vtbl[index])

    out = []
    i = 0
    try:
        while True:
            adapter = ctypes.c_void_p()
            # IDXGIFactory1::EnumAdapters1 is vtable slot 12
            hr = method(factory, 12, ctypes.c_long, wintypes.UINT, ctypes.POINTER(ctypes.c_void_p))(factory, i, ctypes.byref(adapter))
            if hr != 0:
                break
            desc = DXGI_ADAPTER_DESC1()
            # IDXGIAdapter1::GetDesc1 is vtable slot 10
            if method(adapter, 10, ctypes.c_long, ctypes.POINTER(DXGI_ADAPTER_DESC1))(adapter, ctypes.byref(desc)) == 0:
                out.append(Adapter(i, desc.Description, desc.VendorId, desc.DedicatedVideoMemory // (1 << 20), bool(desc.Flags & 2)))
            method(adapter, 2, ctypes.c_ulong)(adapter)   # Release
            i += 1
    finally:
        method(factory, 2, ctypes.c_ulong)(factory)
    return out


def best_adapter() -> Adapter | None:
    # vendor 0x1414 = Microsoft (Basic Render Driver / WARP): not a real GPU
    hw = [a for a in list_adapters() if not a.software and a.vendor_id != 0x1414]
    return max(hw, key=lambda a: a.dedicated_mb) if hw else None


# ---------------------------------------------------------------------------------------------- ONNX Runtime


def onnx_providers(device: str = "auto"):
    """Execution providers for onnxruntime. device: 'auto' | 'cpu' | 'gpu:<index>'."""
    import onnxruntime as ort
    avail = ort.get_available_providers()
    if device == "cpu":
        return ["CPUExecutionProvider"]
    if "DmlExecutionProvider" in avail:
        if device.startswith("gpu:"):
            idx = int(device.split(":")[1])
        else:
            a = best_adapter()
            if a is None and list_adapters():      # only a software adapter: use the CPU directly
                return ["CPUExecutionProvider"]
            idx = a.index if a else 0
        return [("DmlExecutionProvider", {"device_id": idx}), "CPUExecutionProvider"]
    if "CUDAExecutionProvider" in avail:
        return ["CUDAExecutionProvider", "CPUExecutionProvider"]
    if "CoreMLExecutionProvider" in avail and IS_MAC:
        return [("CoreMLExecutionProvider", {"MLComputeUnits": "ALL"}), "CPUExecutionProvider"]
    return ["CPUExecutionProvider"]


def describe_device(providers_in_use: list[str], device: str = "auto") -> str:
    """Human readable name of where inference runs."""
    if "DmlExecutionProvider" in providers_in_use:
        idx = int(device.split(":")[1]) if device.startswith("gpu:") else (best_adapter().index if best_adapter() else 0)
        a = next((x for x in list_adapters() if x.index == idx), None)
        return f"显卡加速：{a.name}" if a else "显卡加速（DirectML）"
    if "CUDAExecutionProvider" in providers_in_use:
        return "显卡加速（CUDA）"
    if "CoreMLExecutionProvider" in providers_in_use:
        return "Apple 神经网络引擎 / GPU"
    return "CPU"


# ---------------------------------------------------------------------------------------------- OpenCV OpenCL


def setup_opencl(enabled: bool) -> bool:
    """Use OpenCL (GPU) for OpenCV resize / warp. Prefers the discrete GPU. Returns True if active."""
    import cv2
    if not enabled or not cv2.ocl.haveOpenCL():
        cv2.ocl.setUseOpenCL(False)
        return False
    a = best_adapter()
    if a is not None and a.discrete and "OPENCV_OPENCL_DEVICE" not in os.environ:
        os.environ["OPENCV_OPENCL_DEVICE"] = ":dGPU:"
    cv2.ocl.setUseOpenCL(True)
    try:
        return cv2.ocl.useOpenCL() and cv2.ocl.Device.getDefault().available()
    except Exception:
        cv2.ocl.setUseOpenCL(False)
        return False


def opencl_device_name() -> str | None:
    import cv2
    try:
        if cv2.ocl.useOpenCL():
            return cv2.ocl.Device.getDefault().name()
    except Exception:
        pass
    return None


# ---------------------------------------------------------------------------------------------- FFmpeg encoders

ENCODERS = {
    # family: {codec: ffmpeg encoder}
    "nvenc": {"h264": "h264_nvenc", "hevc": "hevc_nvenc"},
    "amf": {"h264": "h264_amf", "hevc": "hevc_amf"},
    "qsv": {"h264": "h264_qsv", "hevc": "hevc_qsv"},
    "videotoolbox": {"h264": "h264_videotoolbox", "hevc": "hevc_videotoolbox"},
    "software": {"h264": "libx264", "hevc": "libx265"},
}
ENCODER_TITLES = {"auto": "自动（优先显卡）", "nvenc": "NVIDIA NVENC", "amf": "AMD AMF", "qsv": "Intel Quick Sync",
                  "videotoolbox": "Apple VideoToolbox", "software": "软件编码（CPU）"}


def _hidden_startupinfo():
    if IS_WINDOWS:
        si = subprocess.STARTUPINFO()
        si.dwFlags |= subprocess.STARTF_USESHOWWINDOW
        return {"startupinfo": si, "creationflags": 0x08000000}  # CREATE_NO_WINDOW
    return {}


@functools.lru_cache(maxsize=64)
def encoder_works(name: str, w: int = 256, h: int = 256) -> bool:
    """Actually encodes a few frames at the requested size: a listed encoder may still lack a
    driver / GPU, or reject large / portrait resolutions (seen with some QSV driver builds)."""
    ff = ffmpeg_path()
    if not ff:
        return False
    cmd = [ff, "-hide_banner", "-loglevel", "error", "-f", "lavfi",
           "-i", f"color=black:s={w}x{h}:r=30:d=0.3", "-c:v", name, "-pix_fmt", "yuv420p", "-f", "null", "-"]
    try:
        return subprocess.run(cmd, capture_output=True, timeout=30, **_hidden_startupinfo()).returncode == 0
    except Exception:
        return False


def available_encoder_families(w: int = 256, h: int = 256) -> list[str]:
    fams = []
    order = ["nvenc", "amf", "qsv"] if IS_WINDOWS else ["videotoolbox"] if IS_MAC else ["nvenc", "amf", "qsv"]
    for f in order:
        if encoder_works(ENCODERS[f]["h264"], w, h):
            fams.append(f)
    fams.append("software")
    return fams


def pick_encoder(codec: str, preference: str = "auto", w: int = 256, h: int = 256) -> str:
    """ffmpeg encoder name for codec 'h264' / 'hevc', validated at the real output size."""
    if preference not in ("auto", "software") and preference in ENCODERS:
        enc = ENCODERS[preference][codec]
        if encoder_works(enc, w, h):
            return enc
    if preference == "auto":
        for fam in available_encoder_families(w, h):
            enc = ENCODERS[fam][codec]
            if fam == "software" or encoder_works(enc, w, h):
                return enc
    return ENCODERS["software"][codec]
