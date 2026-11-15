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
| 2026-11-15 · `a0c63d4` | GitHub 托管 Mac / Windows，fork 任务分支手动运行 | 完整构建与产物汇总 | 通过。Mac Swift 101 项、跳过 5 项（同上），打包工具 32 项、0 跳过，通用 DMG 与签名校验通过。Windows Python 162 项、0 跳过，C# 更新器 80 项断言和 8 个进程集成用例（含 `source-fallback`）、源程序及成品自检通过。Release 草稿任务跳过。[完整构建](https://github.com/Liam0205/BirdLock/actions/runs/43675465062) |
| 2026-11-15 · `a0c63d4` 源码 | Linux x64，Mono C# 编译器 | 更新器单测与进程集成测试 | 通过，80 项断言，8 个集成用例。Mono 非 Windows 目标，仅作源码佐证 |
| 2026-11-15 · `a0c63d4` 源码 | Linux x64，Swift 6.2.1 | `UpdateSourcesTests`（BirdLockCore） | 通过，5 项。地址规则、清单及包地址映射、默认与自定义列表、探测顺序、enclosure 解析。`AppUpdater` 和界面依赖 AppKit / Sparkle，Linux 上未编译 |
| 2026-11-15 · `a0c63d4` 源码 | Linux x64，Python 3.12，离屏 Qt | `windows/tests`、`scripts/tests` | `windows/tests` 162 项，1 项 `test_audio` 失败、4 项跳过。该失败在 `main` 基线的 Linux 上同样出现，与本改动无关，托管 Windows 上通过。`scripts/tests` 32 项通过、6 项跳过（需 macOS 签名工具 codesign 和 clang） |
| 2026-11-15 · `a0c63d4` | Linux x64，公网 | `scripts/check_update_source.py https://3rd.0x01.page/birdlock/update-api/ --full-limit 1000000000` | 通过，23/23。三份清单验签且与 GitHub raw 逐字节一致，全部附件 HEAD 长度、尾部 Range 206、整包内容一致（含 Windows 完整包 406823041 B、macOS 完整包 246617073 B），缺失路径返回 404 |
| 2026-11-15 · `a0c63d4` | Linux x64，Mono，公网 | CI 产物 `BirdLock-1.10.0-Windows-x64.zip` 内的 `_internal/updater/BirdLockUpdater.exe --check 1.9.0` | 通过。默认源列表取 GitHub；仅镜像、镜像优先、不可达源在前三种列表均由镜像返回 1.10.0；`/birdlock/` 根地址返回「所有更新源均不可用」 |
| 2026-11-15 · `a0c63d4` 源码 | Linux x64，Mono，公网 | 更新器下载链路（测试夹具驱动真实更新器） | 通过。清单取自镜像，增量包路由到镜像 `download/`，中断后从 1 MiB 处 Range 续传，SHA256 一致。未执行安装 |
| 2026-11-15 · `a0c63d4` 源码 | Linux x64，Swift 6.2.1，公网 | Core 探测逻辑对真实源 | 通过。GitHub、镜像可用；无效主机和 `/birdlock/` 根地址判为不可用。未经过 Sparkle |

| 2026-11-15 · `codex/audit-fixes`（代码提交 `4649f7c`） | 实体 Mac x86_64，macOS 15.7.3，Swift 6.2.4 | `swiftc -typecheck` 全部 `Sources/BirdLockCore`、`Sources/BirdLockCLI` | 通过，无新增错误，仅既有告警。本机离线，未解析 SwiftPM 依赖，**未执行 `swift test`** |
| 2026-11-15 · 同上 | 同机，Python 3.12，`.venv` 内 `cryptography==48.0.1` | `python -m unittest discover -s scripts/tests` | 通过，35 项、0 跳过，含新增的 3 项 `md2html` 用例 |
| 2026-11-15 · 同上 | 同机 | `scripts/verify_bundle.py --lens-resources SharedResources/LensProfiles` | 通过。镜头清单只改 `title`/`cameraBrand` 拼写，文件与 SHA256 未变 |
| 2026-11-15 · 同上 | 同机 | Windows 风格工程夹具：把 `locations[].path` 写成 `C:\...`、帧记录写成 `file:///C:/...`，移动素材后调用 `WorkspaceDocument.read(_:relocation:)` | 通过，6 帧全部重定位到新目录 |
| 2026-11-15 · 同上 | 同机 | 全部 34 个 Markdown 的相对链接与锚点检查 | 通过，0 个失效 |
| — · 未执行 | Windows 10 / 11 实体 | `windows/tests`、`birdlock.cli selftest`、成品自检 | 未执行 · 本机无 Windows 环境，本分支未改 Windows 行为，仅两处注释 |

PR 检查使用 GitHub 生成的合并引用，后续推送以当前任务 PR 的检查为准。多更新源任务对应 PR #5，运行记录见上表。

## 实体设备验收

以下是当前需记录的实机覆盖范围。历史验收有自己的版本和环境。[既有测试记录](../整批功能验收清单.md) · [Windows 操作步骤](../../windows/README.md)

| 平台及环境 | 功能与验收判据 | 本轮结果 |
|---|---|---|
| Windows 10 / 11 x64 实体桌面 | 源码与成品启动，真实连拍照片导入、识别、预览、固定选眼、重开工程、H.264 / HEVC 导出 | 未执行 · Windows Codex |
| Windows x64 实体显卡，优先 RTX 3080 | 同批鸟类及飞机素材比较 CPU 和 DirectML，重新识别并记录机头节点分配、回退和总分析耗时 | 未执行 · Windows Codex |
| Windows x64 实体桌面 | 真实动物或昆虫的框选、双向跟踪、失锁补关键帧、保存恢复和导出 | 未执行 · Windows Codex |
| Windows x64 实体桌面 | 短 SDR 视频导入、镜头配置、缓存重建、原声混音和导出。改动陀螺仪功能时补带有效 IMU 的素材 | 未执行 · Windows Codex |
| Mac / Windows 实体设备 | 同一份工程跨平台互开、定位原片、保留编辑结果并导出。使用相同设置核对可见差异 | 未执行 · 双端 Codex |
| 实体 Mac，1.10.0 之后的测试版本 | 「更新源…」排序、添加、删除、恢复默认；把镜像排第一后检查更新，Sparkle 经镜像下载、验签、安装并重启，菜单显示当前可用源 | 未执行 · Mac Codex |
| Windows 10 / 11 x64 实体桌面，1.10.0 之后的测试版本 | 「更新源…」对话框操作；把镜像排第一后完成增量或完整更新、健康检查通过；断网或不可达源在前时回退到下一源 | 未执行 · Windows Codex |
| 支持光流的实体 Mac | 实际 VideoToolbox 光流的长序列成品导出、输出颜色和异常回退，涉及光流/导出变更时执行 | 未执行 · Mac Codex。源码光流颜色单测见上表 |

回填示例字段为「日期 · SHA · 设备及 OS/架构 · GPU/驱动（如相关） · 源码或包 · 命令/操作 · 素材类型及数量 · 结果和证据」。Windows ARM 模拟、托管 runner、离屏 Qt 或模拟推理需要单列。证据用 Actions 链接或脱敏摘要，私有素材和原始日志留在设备上。
