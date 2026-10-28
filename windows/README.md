# BirdLock Windows 版

Windows 版使用 Python 3.12 x64、Qt/PySide6 和 ONNX Runtime。日常使用请看[使用说明](../docs/windows/使用说明.md)，这里放开发和打包的方法。

[下载 1.4.3 测试版](https://github.com/cyandee/BirdLock/releases/tag/v1.4.3-beta.1) · 联系我：cyanodee@gmail.com

## 从源码运行

在项目根目录打开 PowerShell：

```powershell
py -3.12 -m venv windows/.venv
windows/.venv/Scripts/python -m pip install -r windows/requirements.txt pyinstaller
windows/.venv/Scripts/python windows/BirdLock.pyw
$env:PYTHONPATH = "windows"
windows/.venv/Scripts/python -c "from build_windows import fetch_ffmpeg; fetch_ffmpeg()"
windows/.venv/Scripts/python -m unittest discover -s windows/tests -p "test_*.py"
windows/.venv/Scripts/python -m birdlock.cli selftest
windows/.venv/Scripts/python windows/build_windows.py
```

版本读取根目录的 [VERSION](../VERSION)，当前为 1.4.3，显式传入的 `--version` 必须相同。打包输出为 `windows/dist/BirdLock/` 和 `windows/dist/BirdLock-1.4.3-Windows-x64.zip`。首次构建会下载依赖、FFmpeg 和固定飞机权重，成品运行时不用下载模型。

## 显卡加速

- 鸟类识别使用 ONNX Runtime DirectML，支持 DirectX 12 的 NVIDIA / AMD / Intel 设备，不可用时回退 CPU。
- 图像重采样可以使用 OpenCL；视频编码优先 NVENC / AMF / Quick Sync，失败时回退 x264 / x265。
- 飞机机头使用独立 CPU 模型。鸟类姿态模型保持不变，复杂角度的机头仍需要检查和手动修正。

目标环境是 Windows 10 / 11 x64。测试中也用过 Parallels Windows ARM 的 x64 模拟，但不同实体显卡还需要继续测试。

## 开发测试

先把 `BIRDLOCK_DATA` 指向临时目录，避免改到平时的设置和缓存。项目与主体回归没有设置这个目录时会拒绝运行。

| 命令 | 检查内容 |
|---|---|
| `BirdLock.exe --selftest` | 算法、模型、音效和赞赏资源 |
| `BirdLock.exe --smoketest` | 离屏启动 |
| `BirdLock.exe --gui-regression <照片目录> <报告目录> --export` | 窗口布局和编码导出 |
| `BirdLock.exe --project-regression <照片目录> <报告目录>` | 分组、排序、编辑、缓存、特写、音轨等，至少 12 张照片 |
| `BirdLock.exe --subject-regression <鸟类目录> <飞机目录> <报告目录>` | 主体切换、取消、独立设置和飞机导出 |

测试只读照片，分组时间在内存里构造。结束后记得关闭测试程序及它留下的控制台，避免虚拟机一直占用资源。

1.4.3 本地 Windows 89 项测试和成品回归已通过，详细结果见[测试记录](../docs/整批功能验收清单.md)。Qt 源码也可以在 Mac 上用于开发，发布的 Mac 版则使用 SwiftUI / Core ML。

## 自动构建

[统一 workflow](../.github/workflows/release.yml)复用 [Windows workflow](../.github/workflows/windows.yml)，配置为双平台、源码和校验值汇总到一个 Release 草稿。单独运行 Windows workflow 只产生 Windows 产物。

1.4.0 云端构建曾因隔离子进程的中文输出编码失败，当前脚本已显式使用 UTF-8。1.4.3 云端运行已越过该步骤，但在飞机许可文件校验处停止；本地受测安装包已单独发布。当前状态和 Mac 问题见[构建说明](../docs/构建与发布.md)。

## 1.4.2 本地测试

修复 Qt 下拉框将字符串枚举转成普通字符串，导致切换编码或质量后不能导出的问题。色彩增益改用小查表，减少高分辨率的临时数组。帮助菜单新增导出诊断日志。这些修复已包含在公开的 1.4.3 测试包中。

1.4.3 与 Mac 同步版本号，Windows 功能沿用 1.4.2 的修复；新增的长序列光流进程回收在 Mac 版。
