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
