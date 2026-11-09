# BirdLock 双平台架构

两个桌面程序各自构建和运行，面向同一套 BirdLock 工作流。Mac 版最低 macOS 14，分发 arm64 / x86_64 通用包。Windows 版面向 Windows 10 / 11 x64，Python 3.12 x64 + PySide6，经 PyInstaller 生成便携目录和 ZIP。构建版本以根目录的 [VERSION](../../VERSION) 为准。[工具链、打包与依赖](../构建与发布.md)

## 模块映射

| 工作流 | macOS | Windows |
|---|---|---|
| 界面、预览、项目操作 | `Sources/BirdLockApp/`，SwiftUI、AppKit、`AppState.swift`、`ProjectEditing.swift` | `windows/BirdLock.pyw`、`windows/birdlock/app/`，Qt、`state.py`、`project_actions.py`、`project_workspace.py` |
| 导入、分组和缓存 | `BirdLockCore/IO/` 与 `Analysis/ClipOrder.swift`，ImageIO、AVFoundation | `birdlock/core/frames.py`、`video_import.py`、`clip_order.py`、`cache_policy.py`，Pillow、OpenCV、FFmpeg |
| 鸟体、鸟头和选眼 | `BirdLockCore/Vision/`、`Analysis/`、`Models/`，Core ML | `birdlock/core/models.py`、`analysis.py`、`head.py`、`windows/models/`，ONNX Runtime，DirectML 或 CPU |
| 飞机和自定义目标 | `Sources/BirdLockAircraftRuntime/` 用 ONNX Runtime。`BirdLockCore/Analysis/CustomTracking.swift` 用 Vision 和局部相位配准 | `birdlock/core/aircraft*.py` 用 ONNX Runtime，机头支持 DirectML 与 CPU 回退。`custom_tracking.py` 用 OpenCV 局部特征和模板搜索 |
| 构图、取景、特写和导出 | `BirdLockCore/Render/`、`Export/`，Core Image、AVFoundation、VideoToolbox。`BirdLockInterpolation` 是独立光流进程 | `birdlock/core/planner.py`、`render.py`、`exporter.py`，OpenCV、FFmpeg，支持可用的 OpenCL 和硬件编码回退 |
| 工程与版本说明 | `BirdLockCore/IO/WorkspaceDocument.swift`、`ReleaseNotice.swift` | `birdlock/core/workspace.py`、`release_notice.py` |
| 成品、更新 | `scripts/build_app.sh`、`scripts/make_dmg.sh`、`BirdLockApp/AppUpdater.swift`，Sparkle | `windows/build_windows.py`、`windows/BirdLock.spec`、`birdlock/app/updates.py`、`windows/updater/`，独立 .NET 更新器 |
| CLI 和测试 | `Sources/BirdLockCLI/`、`Tests/BirdLockCoreTests/`、`scripts/tests/` | `windows/birdlock/cli.py`、`windows/tests/`、`windows/birdlock/app/*regression.py` |

表中 `BirdLockCore/`、`BirdLockApp/` 在 `Sources/` 下，`birdlock/` 在 `windows/` 下。

## 共享契约和平台差异

- **工程**。`.birdlock` 是 `format: BirdLockProject`、`schema: 1` 的 JSON。它记录素材引用、分组、分析和编辑状态、固定选眼及自定义目标参考帧、音轨、水印、视频重建参数和防抖数据。原片和自加音轨等素材在工程外。工程保存原路径及相对位置，迁移时保留相对目录或重新定位。分析缓存和设置是各平台本地数据。涉及工程格式的改动，按两端实现和实测结果核对。[工程与缓存管理](../工程与缓存管理.md)
- **模型和资源**。鸟类模型有 Core ML / ONNX 两套产物，改动权重、关键点定义或坐标转换时同时核对两端。音效及 ID、支持资源、镜头 JSON 和飞机模型来源清单位于 `SharedResources/`。飞机权重由现有脚本按清单固定的版本和 SHA256 获取。[飞机模型清单](../../SharedResources/AircraftModels/manifest.json) · [音效](../../SharedResources/Audio/README.md) · [视频和镜头](../视频导入与镜头配置.md)
- **遥测**。两端调用 `tools/telemetry/` 中的同一 Rust 源码，通过 schema 1 JSON 接收秒、rad/s 和 IMU 到相机坐标映射。原生二进制、架构和装包路径分别校验。更改单位或字段时同时检查 `TelemetryIO.swift` 和 `telemetry_io.py`。[遥测协议](../../tools/telemetry/README.md)
- **版本和更新**。`SharedResources/Updates/config.json` 包含公开更新配置和验签公钥。`updates/macos.xml` 是 Sparkle 清单，Windows 使用 `updates/windows.json` 和 `updates/windows-stable.json`。安装升级和签名链按平台分别验收，发布审批以维护者为准。[自动更新](../自动更新.md)

对齐用户可见的输入、默认行为、工程兼容性、输出、取消和错误反馈。识别数值、系统 UI、硬件可用性与编码器随平台变化。遇到差异，用同一份获准用于本机测试的素材检查两端的导入、编辑、导出和回退，并写明差异。[测试矩阵](TEST_MATRIX.md)
