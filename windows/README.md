# BirdLock 鸟眼锁定 — Windows 版

Python + Qt 实现，算法与 macOS 原生版（`Sources/BirdLockCore`）一致：

| 模块 | 说明 |
|---|---|
| `birdlock/core` | 照片读取、ONNX 模型推理、分析（检测 / 跟踪 / 关键点 / 亚像素配准 / 轨迹融合）、构图规划、渲染、FFmpeg 导出 |
| `birdlock/app` | Qt 界面（成片预览、原图+识别、时间轴与音乐轨道、设置面板、导出、用户协议） |
| `birdlock/cli.py` | 命令行：`selftest` / `devices` / `analyze` / `export` |
| `models/` | ONNX 模型（由 `tools/train/export_onnx.py` 从 YOLO 权重导出） |

## 显卡加速

- AI 识别：ONNX Runtime **DirectML**（NVIDIA / AMD / Intel，DirectX 12），笔记本自动选独显
- 图像重采样：OpenCV **OpenCL**（优先独显）
- 视频编码：FFmpeg **NVENC / AMF / Quick Sync**，没有时用 x264 / x265

## 开发与打包

```powershell
py -3.12 -m venv .venv
.venv\Scripts\pip install -r requirements.txt pyinstaller
.venv\Scripts\python BirdLock.pyw                      # 运行
.venv\Scripts\python -m birdlock.cli selftest          # 自检
.venv\Scripts\python build_windows.py --version 1.0    # 打包 → dist\BirdLock-1.0-Windows-x64.zip（绿色版）
```

推送 `v*` 标签或手动运行 GitHub Actions 的 “Windows build” 时会自动打包、自检，并把压缩包附到对应的 Release。

在 macOS 上也能运行这套代码（用 Core ML 推理、VideoToolbox 编码），方便开发调试。
