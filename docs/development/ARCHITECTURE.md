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
- **更新源**。同一份 config 的 `sources` 给出默认顺序（GitHub、BirdLock 镜像），`release_download_prefix` 是签名清单里可改写的 Release 前缀。两端遵守同一[源标准](../自动更新.md#合法更新源标准)，用户的自定义列表各自保存：Mac 存在 `UserDefaults` 的 `updates.sources`（`BirdLockCore/UpdateSources.swift`、`UpdateSourceProbe.swift`，`AppUpdater` 通过 Sparkle 的 `feedURLString` 和 `willDownloadUpdate` 接入），Windows 存在 `data/updates.json` 的 `sources`（`birdlock/app/updates.py` 以 `--source` 传给 `windows/updater`）。没有自定义时字段缺省，跟随新版默认值。`scripts/stage_updater.py` 把默认值写进 Mac 的 Info.plist。

对齐用户可见的输入、默认行为、工程兼容性、输出、取消和错误反馈。识别数值、系统 UI、硬件可用性与编码器随平台变化。遇到差异，用同一份获准用于本机测试的素材检查两端的导入、编辑、导出和回退，并写明差异。[测试矩阵](TEST_MATRIX.md)

## 下一版 Windows 阶段的共享约定

继续使用 `schema: 1`。下表字段是增量扩展；旧工程无需迁移。Mac 必须实现读取和保留后才能用来重存这些新工程；现有 Swift 解码器可能忽略新字段。

| 字段 | 缺省和兼容行为 | Windows 接入 | Mac 对应位置 |
|---|---|---|---|
| `audio.enabled`，`audio.tracks[].enabled` | 缺省 `true`。禁用不改 `muted`、路径、资源 ID、音量、开始位置、时长、循环、淡入淡出或静音区间；禁用轨不进入预览或导出。既有快门和视频原声仍按各自轨道处理 | `settings.py`、`exporter.py`、`audio_tracks.py` | `Export/SoundLibrary.swift`、预览混音、导出和 `WorkspaceDocument.swift` |
| `segments[].groupID`，`segments[].name` | 新分组 UUID；旧组缺省标识 `legacy-<start>-<count>`。空名用现有序号显示；允许重名、Unicode，最多 256 字符。仍以原 `start/count/fps` 定义帧范围，`mergeGroups` 保留原索引语义；重命名、合并排序不重建标识 | `frames.py`、`workspace.py`、`project_editor.py`、`media_location.py` | `IO/SourceFrame.swift`、`IO/WorkspaceDocument.swift`、分组列表、`ProjectEditing.swift`；用 Finder 选择可用原片 |
| `frames[].raw` 与 `analyses[].frames[].raw` | JPEG 等缺省无字段。RAW 写 `{mode, source, fullWidth, fullHeight}`；`mode: camera\|raw` 是用户选择，缺省策略为 `camera`；`source: embedded\|decoded` 是实际来源。两项完整尺寸和现有 `pixelWidth/pixelHeight` 都是按方向校正后的尺寸，后者表示实际使用的图像。原 `url` 始终指向原片 | `raw_photo.py`、`frames.py`、`workspace.py`；缓存键包括路径、大小、mtime、渲染策略、实际来源、解码库与处理版本 | `IO/SourceFrame.swift`、`ImageLoader.swift`、`WorkspaceDocument.swift`；验证 ImageIO / Core Image RAW 实际能力 |

RAW 的相机模式优先使用内嵌预览并把已知的 ICC 色彩转为 sRGB；高分辨率模式用相机白平衡和 LibRaw 的 sRGB 输出，不保证复制相机厂商风格。策略不可用时尝试另一条解码路径并显示原因。内嵌图明显小于完整尺寸时显示实际尺寸并阻止以全分辨率名义导出。更改策略用于下一次导入，已保存项目重开沿用实际来源。RAW/JPEG 同目录同名且已知拍摄时间相差小于 0.51 秒（或至少一方时间未知）视为配对；默认 JPEG 优先，另可选 RAW 优先或导入两者。损坏的候选不会盖过可读取的配对文件。小图和分析代理留在缓存，不能代替原片引用。

视频导入、界面和恢复都走同一校验：至多 600 秒、18,000 帧，采样不超过 60 fps 和源帧率，短于所选长度时按实际片尾计数。Windows 抽帧前估算每帧像素数加 64 KiB 的 JPEG/代理预算，叠加音频预算和磁盘余量；过程中继续检查可用空间，取消只清理本次临时文件。限额是分批保护，不能代替磁盘检查；保持既有 SDR 及编码边界。Mac 接手调整 `VideoImporter.swift`、`VideoImportSheet.swift`、缓存恢复及原声采样，并复测相同片段。

编辑历史仅在当前会话保留最近 40 步；滑块拖动和调整位置合并，执行新编辑后改写重做分支。保存只写最终状态。重新导入、打开/关闭工程、重新识别建立新历史；导出和定位文件不写历史。菜单对照：两端「文件」提供导入、工程和导出，「编辑」提供撤销/重做，「播放」和「修片」保留现有命令；Windows 将「外观」和「显示当前原片」放「显示」，Mac 可沿用原生菜单和 Finder 命令。自定义设置保存在各自系统；Windows 旧版沿用深色，另可设浅色或跟随系统，DWM 保留原生窗口框架。
