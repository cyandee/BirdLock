# 双端开发交接

这里记录当前任务和下一步。版本历史、已上线状态和历史验收沿用原文档。当前开发验证集中在 [测试矩阵](TEST_MATRIX.md)。[版本记录](../迭代记录.md) · [项目近况](../工作进度.md) · [历史验收](../整批功能验收清单.md)

## 当前任务：下一版双平台集成

| 字段 | 内容 |
|---|---|
| 分支及 PR | `codex/windows-next-release` → `main`，沿用 [PR #6](https://github.com/cyandee/BirdLock/pull/6)。Windows 交接 SHA `704cac5a6e04c30be17803c17d38738c904bd062`，Mac 原生实现 SHA `81eae24521efb087fd32304569fb2f380574e652` |
| 写入权 | Windows 在 PR 正文交出写入权。Mac 在 PR 确认接手并完成适配。回填实机结果前在 PR 确认下一次接手，或从约定 SHA 开单独分支 |
| Windows 已实现 | RAW、配对去重、长视频磁盘预算、音轨开关、分组、编辑历史、外观与 DWM。吸收 [PR #4](https://github.com/cyandee/BirdLock/pull/4) 的缓存、工程路径、本地验收及 ICU 修复 |
| Mac 已实现 | Apple ImageIO 和 Core Image RAW、音轨启用和混音、分组命名与 Finder 定位、⌘Z / ⇧⌘Z、三种 AppKit 外观、支持窗口资源、600 秒 / 18,000 帧选择和缓存预算。schema 1 工程可恢复已选 RAW 来源，按原记录分组和保存。Mac 可以重新定位 Windows 盘符路径并重存 |
| 双向回归 | 实体 Mac 上的原生 Swift 与 Python/Qt 代码对六种共同 RAW 样本执行了两种策略的双向读取、保存或导出。相关证据和实机范围见 [TEST_MATRIX.md](TEST_MATRIX.md) |
| Windows 接手 | 在实际 Windows x64 上打开 Mac 保存的工程并回存给 Mac，覆盖两种 RAW、关闭的背景音乐/独立轨、Unicode 分组和视频缓存重建。Nikon Z8 高效率低样本在此次 Mac 上可解码，仍以 Windows 已记录的失败为准。Mac 上运行 Windows Python 代码时，带循环音轨的 FFmpeg 导出曾停滞，非循环对照通过，请在实体 Windows 对照 |
| 其他复测 | 两端真实 RAW 鸟眼连拍、Windows 10 和高 DPI/Snap、不同 RAW 压缩、18,000 帧负载、真实长视频全链路和镜像实机升级。Windows 端仍需原报告的水印选择器闪退、特定硬件编码和异常连拍时间戳。Mac 飞机预览卡顿与成片短时横跳需用获授权原片分别定位 |

验收完毕由维护者在 PR 审核合并。正式版本说明只覆盖对外功能变更，发布另行授权。

## 上一轮：多更新源

| 字段 | 内容 |
|---|---|
| 任务 | 全仓审计整改：修复 Mac 端缺陷与冗余代码、过期文档和构建脚本问题；Windows 端问题只记录待办，不改代码 |
| 分支与基线 | `codex/audit-fixes`，基于 `main` 的 `96e047d`。分支尚未推送，推送后向 `main` 提 PR |
| 评审与检出 | 检出该分支即可复核。文件级改动见提交记录，逐项审查清单由提交信息与 PR 说明给出 |
| 分支写入负责人 | 本轮同一会话在 Mac 端（`Sources/`、`Tests/`、`docs/`、`scripts/`、`README.md`）写入。`windows/` 只改了两处注释，未改行为 |
| 已完成 | Mac：单独拖入音频的误报、跟踪参考 patch 重复重采样、EXIF 时间解析共享格式化器、音效库重复读盘、工程重定位对 Windows 路径不匹配、若干未使用符号与未使用参数、音频时长非有限时的崩溃路径、视频轨道缺失的强制解包。工具：`md2html` 转换 Markdown 链接（含单测）。文档：README 更新段、交接、测试矩阵、Windows 使用说明的机头设备表述、版本标注、Windows 许可页音频章节。资源：镜头清单 Fujifilm 品牌拼写 |
| 已知限制 | Windows 代码（`windows/birdlock/`、`windows/updater/`、CI）只做只读审计，未在本机执行 Windows 单测或实机验证；`swift test` 未运行（本机离线无法解析 Sparkle 与 onnxruntime 依赖） |
| 剩余验证 | 在 Mac 与 Windows 上分别跑完整 `swift test`、`windows/tests` 与成品自检；跨平台工程互开（Windows 保存、Mac 重新定位）需实机确认；打包后文档链接可用性需检查 |
| 下一步 | 分支已推送，PR #7 待维护者审核。本分支未改的问题已逐条登记为上游 issue #8–#66（带 [高]/[中]/[低] 重要性前缀），由对应端的负责人按 issue 处理 |

此前任务：多更新源（`codex/update-sources`）已随 PR #5 于 `96e047d` 合入 `main`，其剩余实机验收仍见[测试矩阵](TEST_MATRIX.md)。

## 接力方式

1. **Mac 交出**。从 `origin/main` 的当前提交开任务分支。完成 Mac 实现后，列出 Windows 对应模块、需要保持一致的输入输出、测试素材类型和复测入口。把代码和交接记录提交到任务分支，在 PR 留下交接 SHA，明确让出写入权。
2. **Windows 接手**。先 `git fetch origin`，核对交接 SHA，再按指南检出任务分支。仅验证时可检出该提交进行只读复测。要接续修改时先在 PR 确认接手。若 Mac 同时开发，从交接 SHA 开 Windows 子分支，目标设为任务分支。
3. **Windows 回传**。完成本地修复和验证后，记录被测 SHA、系统、设备、真实素材类型和结果。推送自己的分支，更新交接和测试矩阵。原片、工程、导出和原始诊断文件留在设备上。
4. **合并评审**。集成双方改动后，复跑受影响的检查，核对两端行为和工程兼容性。维护者根据 PR 的 CI 及分别记录的设备验收结果审核合并。发版另行授权。[项目规范](../../AGENTS.md) · [Windows 开发指南](../../windows/README.md)

下一次交接更新「当前任务」表即可。并行任务各自在自己的分支记录，集成时保留仍待执行的事项。用 PR 或提交链接追溯已结束任务。
