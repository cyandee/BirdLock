# 双平台测试矩阵

按被测提交记录。结果使用 **通过 / 失败 / 跳过 / 未执行**。跳过注明原因，未执行注明负责人或所需设备。对单测套件同时记录运行数和跳过数。CI 链接与实机摘要分别存放。结论以当次环境及覆盖范围为准。

## 自动检查

| 环境 | 检查 | 证据 |
|---|---|---|
| PR · GitHub 托管 macOS | `swift test`、Swift CLI 自检、`scripts/tests` 打包及更新工具单测。托管环境允许现有光流硬件测试条件跳过，未构建遥测辅助程序时相应测试跳过 | PR 的 `macOS checks` |
| PR · GitHub 托管 Windows x64 | Python 单测、现有 FFmpeg 下载入口、CLI 源码自检、Qt 离屏启动。不构建原生遥测辅助程序时相应测试跳过 | PR 的 `Windows checks` |
| main 或分支手动运行 · GitHub 托管双平台 | 完整 Mac 通用 DMG 与签名校验、Windows ZIP 和原生更新器单测/集成测试及成品自检、对应源码和 SHA256 | `Unified macOS and Windows packages` 的 Actions 运行及产物 |
| 正式版本 · 授权后使用 `v*` 标签 | 上述完整构建，版本核对后按现有流程创建草稿。正式附件与签名更新另行验收 | 对应标签的 Actions 运行及维护者发布记录 |

[PR 工作流](../../.github/workflows/pr-checks.yml) · [构建与发布](../构建与发布.md)

## 本轮验证

| 日期与提交 | 环境 | 检查 | 结果与证据 |
|---|---|---|---|
| 2026-11-04 · `c15aa97` | GitHub 托管 Mac / Windows | 1.10.0 双平台、源码及汇总，含 Windows 158 项、更新器和源程序/成品自检 | 通过。[1.10.0 运行](https://github.com/cyandee/BirdLock/actions/runs/41801582228) · [发布核验](../工作进度.md#发布核验) |
| 2026-11-09 · `3610102` 源码 | 实体 Mac arm64，macOS 27.2，Xcode 27.2 | `swift test`、`swift run birdlock-cli selftest` | 通过，96 项、0 跳过，CLI 自检通过。核验并复用既有原生遥测辅助程序，两项光流颜色测试通过 |
| 2026-11-09 · `3610102` 源码 | 同一实体 Mac，Python 3.12 | `python -m unittest discover -v -s scripts/tests` | 通过，28 项、0 跳过 |
| 2026-11-09 · `3610102` 源码 | Mac 上的 Qt，Python 3.12，FFmpeg 和原生 Mac 遥测辅助程序 | `windows/tests`、`birdlock.cli selftest`、源码 `--smoketest` | 通过，158 项、0 跳过，源码自检和离屏截图检查通过 |
| 2026-11-09 · `d33860b`（PR 头提交） | GitHub 托管 macOS 15 | PR 快速检查首轮 | Swift 91 项通过，5 项跳过（2 项光流硬件、3 项需遥测辅助程序）。CLI 自检与打包工具 28 项通过。[首轮运行](https://github.com/cyandee/BirdLock/actions/runs/42544350396) |
| 2026-11-09 · `d33860b`（PR 头提交） | GitHub 托管 Windows x64 | PR 快速检查首轮 | Python 154 项通过，4 项需遥测辅助程序而跳过。CPU 源码自检和离屏启动通过。[首轮运行](https://github.com/cyandee/BirdLock/actions/runs/42544350396) |
| 2026-11-09 · `d33860b` | GitHub 托管 Mac / Windows，任务分支手动运行 | 完整构建与产物汇总 | 通过。Mac Swift 91 项、跳过 5 项（同上），打包工具 28 项、通用 DMG 与应用签名校验通过。Windows Python 158 项、0 跳过，C# 更新器单测和集成测试、源程序及成品自检通过。源码归档、SHA256 汇总通过，Release 草稿任务跳过。[完整构建](https://github.com/cyandee/BirdLock/actions/runs/42544366246) |

PR 检查使用 GitHub 生成的合并引用。后续推送以 [PR #2 的当前检查](https://github.com/cyandee/BirdLock/pull/2/checks) 为准。

## 实体设备验收

以下是当前需记录的实机覆盖范围。历史验收有自己的版本和环境。[既有测试记录](../整批功能验收清单.md) · [Windows 操作步骤](../../windows/README.md)

| 平台及环境 | 功能与验收判据 | 本轮结果 |
|---|---|---|
| Windows 10 / 11 x64 实体桌面 | 源码与成品启动，真实连拍照片导入、识别、预览、固定选眼、重开工程、H.264 / HEVC 导出 | 未执行 · Windows Codex |
| Windows x64 实体显卡，优先 RTX 3080 | 同批鸟类及飞机素材比较 CPU 和 DirectML，重新识别并记录机头节点分配、回退和总分析耗时 | 未执行 · Windows Codex |
| Windows x64 实体桌面 | 真实动物或昆虫的框选、双向跟踪、失锁补关键帧、保存恢复和导出 | 未执行 · Windows Codex |
| Windows x64 实体桌面 | 短 SDR 视频导入、镜头配置、缓存重建、原声混音和导出。改动陀螺仪功能时补带有效 IMU 的素材 | 未执行 · Windows Codex |
| Mac / Windows 实体设备 | 同一份工程跨平台互开、定位原片、保留编辑结果并导出。使用相同设置核对可见差异 | 未执行 · 双端 Codex |
| 支持光流的实体 Mac | 实际 VideoToolbox 光流的长序列成品导出、输出颜色和异常回退，涉及光流/导出变更时执行 | 未执行 · Mac Codex。源码光流颜色单测见上表 |

回填示例字段为「日期 · SHA · 设备及 OS/架构 · GPU/驱动（如相关） · 源码或包 · 命令/操作 · 素材类型及数量 · 结果和证据」。Windows ARM 模拟、托管 runner、离屏 Qt 或模拟推理需要单列。证据用 Actions 链接或脱敏摘要，私有素材和原始日志留在设备上。

## 2026-11-09 · Windows 实体 x64 复测

Windows 11 Pro x64 26H2，构建 26300.9818；i7-10700K（8 核 / 16 线程），可见内存 63.72 GiB。RTX 3060 12 GiB，NVIDIA 驱动 610.88 / WDDM 3.2；Intel UHD 630，驱动 31.0.101.2141。DirectX 12，RTX 功能级别 12_2。Python 3.12.10 x64、Qt 6.12.0、ONNX Runtime DirectML 1.24.4、OpenCV 5.0.0.93；FFmpeg n9.0.2-48 的发布 ZIP 已对照上游 SHA256 校验。

| 被测提交及环境 | 检查 | 实际结果 |
|---|---|---|
| [`90ddbf9`](https://github.com/cyandee/BirdLock/commit/90ddbf930a4e09bc5743bdd75b2a1ab47c4882e2) · Windows 实体机源码 | `windows/acceptance.py --mode full` | **通过** 16/16 步骤，0 失败、0 跳过。Python 单测 159/159（含 4 项原生遥测）；CLI 自检 5/5；设备枚举、FFmpeg、原生和离屏窗口自检均通过。真实 Windows 窗口记录 DPR 1.75，另外用 Qt 缩放倍率 1.5 重跑布局。 |
| 同一提交及实体机 · 合成照片和视频 | 四个 Qt 回归入口，H.264 / HEVC / ProRes 导出及解码 | **通过**。两轮 GUI 各 80 次布局检查；H.264 和 HEVC 实际使用 RTX 的 NVENC。工程保存重开恢复手动修正、裁切和音轨；两种取消入口均保留原目标文件并可重试。飞机回归覆盖 8 张照片和 12 帧视频的机头轨迹；合成鸟图与鸟视频均无识别命中，保留未跟踪帧验证导出，未验收真实鸟眼。 |
| 同一提交及实体机 · 同批 12 张合成鸟图，单张合成飞机图 | 两次全新分析进程，CPU 与 RTX 3060 DirectML | **通过**。鸟体/姿态分别有 12/1 个 DirectML 执行事件，没有 CPU 节点或整模型回退；姿态为独立探测。飞机部位首轮有 189 个 DirectML、4 个 CPU 节点，混合执行且未整模型回退。Quick Sync 通过 H.264 编码探测；OpenCL 独立枚举。 |
| [`7944e30`](https://github.com/cyandee/BirdLock/commit/7944e30a3263e81fc170dcc6ce2e41f5e162559c) · Windows 实体机本地构建 | `windows/build_windows.py`，全新目录解压 ZIP 并执行成品 | **通过**。MSVC 14.44、SDK 26100、Rust 1.99.1 x64 MSVC、PyInstaller 6.22.3。ZIP 431,129,184 字节；核对清单 884 个文件（105 个 DLL、46 个 PYD），含模型、FFmpeg、遥测组件及 DirectML。成品 `--selftest`、`--smoketest`、`--desktop-smoketest` 均退出 0；离屏和真实窗口截图均可读取。C# 更新器 41 项断言和 7 个隔离进程集成场景通过。 |
| [`a724f8c`](https://github.com/cyandee/BirdLock/commit/a724f8cfdf2649e6caea5b57ffa9ae88aea72fd9) · Windows 实体机 | 路径别名修复后的快速验收、工程回归、重建成品 | **通过**。Python 159/159，0 失败、0 跳过；包含真实 NTFS 联接的工程重开和既有素材重定位用例。合成工程回归通过。最新 ZIP 431,131,277 字节，解压后三个成品自检均退出 0。 |
| Windows 实体桌面 · 12 张合成照片 | 自定义目标额外探测 | **通过**。从界面进入框选，设置锁定点，12 帧全部跟踪；保存和重开后恢复参考框。 |
| [PR #4 首轮检查](https://github.com/cyandee/BirdLock/actions/runs/42576325108) · GitHub 托管 Mac / Windows | 源码检查 | macOS **通过**；Windows **失败**，工程重开解析了原路径的别名，导致缓存键改变。实体机已用 NTFS 联接复现并修复，更新结果见 [PR #4 的当前检查](https://github.com/cyandee/BirdLock/pull/4/checks)。 |
| GitHub Actions Windows 成品构建 | 同一提交的补充包验收 | **未执行**。本轮使用上述实体机本地构建；托管 PR 源码检查和既往 GitHub 构建记录分开看。 |
| Windows / macOS 实机 · 真实素材 | 实拍鸟眼、飞机、动物/昆虫、真实 SDR / IMU、工程互开和重定位 | **未执行**。工作区没有符合条件的真实素材；等待授权测试目录，再由双端用相同素材复测。固定选眼和自定义目标的现有合成单测已通过。 |

同批合成鸟图的模型初始化 / 完整分析分别为 CPU **0.41 / 10.14 秒**、DirectML **1.02 / 0.72 秒**。本机首次 DirectML 初始化另测得约 65 秒；不能用之后的重复启动时间代表冷启动。飞机部位的模型初始化 / 单张固定 ROI 四次推理总耗时为 CPU **2.11 / 21.17 秒**、DirectML **3.39 / 5.22 秒**。耗时仅反映这些输入和该设备，节点数不是利用率。

复现与修复：基线缓存测试在普通用户下遇到 WinError 1314；改用真实目录联接后复现清理会删除外部夹具，修复后不遍历联接。工程保存重开曾因 Windows 路径分隔符改变而产生不同缓存键，现有工程回归已验证修复。旧 Qt 回归会停在保存对话框，取消导出曾与编码完成竞态。首次成品 GUI 加载到打包器从 PATH 选入的 ICU，QtCore 导入失败；排除同名 ICU 后，全新 ZIP 解压成品的两种窗口自检通过。原始日志、诊断包、素材、工程和产物只存于本机。
