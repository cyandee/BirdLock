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

## 1.11.0 本地候选复验

2026-11-16，代码提交 `2246d67`。实测平台为 Apple 芯片 Mac，macOS 27.2.1。Windows Python 结果和 Windows EXE 实机结果分别列出。

| 环境 | 检查 | 结果 |
|---|---|---|
| macOS 原生 | Swift 单测、CLI 自检、打包工具 | 107 项 Swift 单测与 35 项打包工具单测通过，CLI 自检通过 |
| macOS 原生 | 1.11.0 通用 DMG | 打包、包内签名和模拟安装后签名检查通过；本机启动并打开 1.11.0 更新说明 |
| Mac 上的 Windows Python 和 Qt 源码 | Windows 单测、CLI 自检、Qt 离屏启动 | 169 项单测、CLI 自检和离屏启动通过。LibRaw 0.22.2 |
| Mac 原生与 Mac 上的 Windows Python 源码 | 双向工程与导出 | 六份公开 RAW 在机内预览和高分辨率两种策略下完成跨端读取与导出，Windows 格式路径重定位、Unicode 组名和音轨开关通过 |
| Mac 上的 Windows Python 源码 | 防抖和视频缓存重建 | 从原视频在新缓存重建 12 帧，核对防抖记录采用工程镜头配置 `[50, 52, 32, 24]` |
| Windows x64 实体机 | 1.11.0 EXE 启动、RAW 打开与跨系统工程回读、硬件编码 | 待维护者验收 |

## 1.11.0 发版前 Issue 整改复验

2026-11-16，代码提交 `2907ff8`。Apple 芯片 Mac，macOS 27.2.1。

| 环境 | 检查 | 结果 |
|---|---|---|
| macOS 原生 | Swift 全套（含遥测辅助程序）及 CLI 自检 | 109 项通过。验证取消视频后保留原目标并可重试，缺帧时图片序列和 GIF 正确失败并保留旧输出 |
| macOS 原生 | 带音轨 RAW 工程回读与视频输出 | 6 帧工程保留分组与轨道开关，实际成品包含 H.264 和 AAC |
| macOS 原生 | Apple 芯片及 Intel 通用 DMG | 打包、应用包和模拟安装后的临时签名检查通过 |
| Mac 上的 Windows Python 代码与离屏 Qt | 全套单测、源码 CLI 自检、GUI 离屏启动 | 173 项通过。两种头部自动旋转、初始化失败后重试、视频/GIF/图片遇坏帧保留旧输出均有回归 |
| Windows x64 | 便携 EXE 启动、导出修复、GPU 编码及跨端回读 | 待实机验收；本地候选 ZIP 基于已校验的 Windows x64 构建产物组装 |
| Windows 正式成品 | 第三方声明与分发清单 | 构建配置已加入 PyInstaller 许可文本。正式原生构建时需按实际成品复核许可证与运行 |

## 1.11.0 macOS 上级文件夹导入

2026-11-16，代码提交 `c0f7d39`。Apple 芯片 Mac，macOS 27.2.1。

| 环境 | 检查 | 结果 |
|---|---|---|
| macOS 原生 | Swift 全套（含遥测辅助程序） | 110 通过，0 失败，0 跳过。新用例覆盖混合目录深度、同名照片、重复输入、包内容、隐藏目录、符号链接及扫描取消，核对 EXIF 连拍范围 |
| macOS 原生 | CLI 上级文件夹导入及自检 | 读取顶层和多层子目录的 5 张带拍摄时间的合成 JPEG，得到 2 组并完成分析；CLI 自检通过 |
| macOS 原生 | 通用 DMG、安装签名、应用的原生打开入口 | 应用包和模拟安装后签名检查通过；通过 macOS 打开带 .mov 后缀的上级文件夹，应用完成深层子目录 3 张照片的连拍组分析 |

## 下一版 Windows 阶段

2026-11-15，代码验收提交 `fcc576ea9c668d4d683b97e7179b9a83a8b21344`。实机 Windows 11 Pro x64 build 26300，i7-10700K（16 线程），64 GiB，RTX 3060 12 GB，Python 3.12.10 / Qt 6.12 / ONNX Runtime DirectML 1.24.4，原生桌面 DPR 1.75。以下是公开的结果摘要，不附原始日志或用户素材。

| 执行命令或操作 | 结果 |
|---|---|
| `python -m unittest discover -s windows/tests`（离屏 Qt、有本地遥测工具） | 167 通过、0 失败、0 跳过。含 20×160 张图片、组标识/名称/旧默认、保存重开、音轨、拖动合并历史、长片参数和磁盘拒绝。主分支初跑 157 通过、1 失败（Windows 符号链接权限）、4 跳过（无遥测工具） |
| `python -m birdlock.cli selftest` | 6 组通过、0 失败：资源哈希、RAW 动态库、相位、轨迹、模型实际推理、NVENC |
| `python windows/acceptance.py --mode full`，中间代码，合成素材 | 首跑 14 通过、2 失败（新增上限测试的源帧率设置，及本机验收进程覆盖了 RAW 的临时依赖路径）。分别用最终代码的 167 项套件及源码/成品自检重跑通过；未把首跑结果记为全过 |
| 同一首轮实机的 `--gui-regression`、`--project-regression`、`--subject-regression`、`--video-regression` | 通过。Issue #1 的构图/画面/输出反复切换和两种窗宽各 80 检查/轮；QT_SCALE_FACTOR=1、1.5（最终代码补跑 2，各 80 检查）。预览、工程保存重开、缓存、取消或关导出窗后重试、H.264/HEVC NVENC、GIF/图片均有结果。短视频飞机 12/12 跟踪、视频失败/取消保留旧工程 |
| 实机 CPU/DirectML 推理证据（合成与模板） | 鸟体实际采样；鸟头模型单独运行；飞机部件 DirectML 189 个、CPU 4 个节点事件。未用此结果证明真实 RAW 鸟眼或用户飞机案例；回退覆盖来自 Windows 单测 |
| Windows 原生窗口和定点音频/诊断检查 | 深浅主题标题栏像素匹配 Qt 面板，跟随系统的 Qt 色彩通知可即时刷新；真实 Windows 设置跨屏切换未测。两个独立 WAV 的实际预览和 AAC 导出：禁用时 880 Hz 消失、440 Hz 保持；重新启用后两者都存在。独占锁住 `app.log` 和 `app.log.1` 都成功回退，原日志内容保留。用工程状态验证改名、轨道撤销/重做及损坏水印拒绝 |
| `python -X utf8 -m unittest discover -s scripts/tests`（安装工具依赖后） | 25 通过、1 失败（Mac 的 chmod 账户权限断言在 Windows 不适用，断言及权限检查均来自主分支）、6 跳过（Mac 签名工具不可用） |
| `python windows/build_windows.py`；解压后 `BirdLock.exe --selftest`、`--smoketest`、`--desktop-smoketest` | 3 项通过。ZIP 432,970,040 B，SHA256 `57f25c0ad6b3973fafee52ce4108927e8fd34169b0b1f777830ce97c0783ed50`。比本机上轮存档 431,131,277 B 多 1,838,763 B（0.43%，非同基线构建比较）。脱机包中 RAW 原生文件共 2,346,624 B（LibRaw DLL、OpenMP DLL、Python 扩展）；两份许可证与两张赞赏码哈希校验通过 |
| 尚未执行或未复现 | Win10、真实 100/150/200% OS 缩放切换、多显示器/Snap、Windows 实机镜像升级、Explorer 实际批量选中、报告里的水印选择器闪退和特定编码器崩溃、同工程 1440p/4K 的 30/60/120 fps 对照、真实连拍鸟眼、Mac 原生和双向工程验收 |

RAW 下表为已验证哈希的 [CC0 样本集](https://github.com/tellodaniel/revelraw-sample-raw-files/releases/tag/v1) 与 [raw.pixls.us](https://raw.pixls.us/) 富士样本的结果。两组均以六种文件完成元数据/解码、CPU 分析、分析记录往返和软件 H.264 导出（114,826 B / 230,072 B）。测试图无鸟，未做真实鸟眼验收、相机配对 JPEG 的定量色差或其他未列出的机型/压缩模式。

| 相机/格式 | 相机模式 | 高分辨率模式 |
|---|---|---|
| Sony A7 III ARW（14-bit 压缩） | 内嵌 1616×1080，提示分辨率限制 | 解码 6024×4024 |
| Nikon Z6 NEF（压缩样本） | 内嵌 6048×4024 | 解码 6064×4040 |
| Canon 5D Mark IV CR2 | 内嵌 6720×4480 | 解码 6744×4502 |
| Canon EOS R CR3 | 内嵌 6720×4480 | 解码 6742×4498 |
| Fujifilm X-T2 RAF（14-bit 无损压缩） | 内嵌 1920×1280，提示分辨率限制 | 解码 6032×4028 |
| Ricoh GR III DNG | 内嵌 6000×4000 | 解码 6020×4024 |
| Nikon Z8 NEF（高效率低，raw.pixls.us 样本 6616） | 哈希正确；当前 LibRaw 无法打开容器，因此未取得内嵌预览 | 拒绝并提示相机直出 JPEG 或转 DNG |
| Fujifilm X-T4 RAF（下载不完整，哈希不符） | 拒绝坏文件，有可操作提示 | 同左；不能据此判为该模式或机型不支持 |

1080p/4K 长视频实际抽帧（统一 3 fps 源，SDR H.264，低复杂度合成画面，无音轨）。表中大小是实际写出的 JPEG 合计；未测进程内存峰值。未执行 18,000 帧满载、真实 4K 高帧率素材、长视频音频同步或全链路分析/重开/导出。短视频另有源码套件和实机操作覆盖取消、音频、缓存、重试。

| 尺寸 | 片段 · 采样率 | 结果：帧数 / 时间 / JPEG |
|---|---|---|
| 1080p | 3 分钟 · 1 fps | 180 / 2.1 秒 / 6.0 MB |
| 1080p | 5 分钟 · 2 fps | 600 / 6.7 秒 / 20.0 MB |
| 1080p | 10 分钟 · 3 fps | 1,800 / 18.9 秒 / 59.9 MB |
| 4K | 3 分钟 · 1 fps | 180 / 9.3 秒 / 23.4 MB |
| 4K | 5 分钟 · 1 fps | 300 / 15.0 秒 / 39.1 MB |
| 4K | 10 分钟 · 1 fps | 600 / 31.5 秒 / 78.1 MB |

## Mac 适配验证

被测代码 `81eae24521efb087fd32304569fb2f380574e652`。本机 arm64，macOS 27.2.1，Xcode 27.2。Windows 交接原生结果在上节。

| 检查 | 实际结果 |
|---|---|
| Apple SwiftPM 和 CLI | `swift test` 104 项通过、0 跳过，使用已核验的 Mac 遥测辅助程序。覆盖 125 秒抽帧、途中取消清理、重试、工程重建、空间预算边界和旧字段缺省。CLI 合成自检通过 |
| 包与工具 | 打包/更新工具 32 项通过。按现有脚本生成通用 App，主程序、光流进程、遥测进程均含 arm64 / x86_64 切片，包资源校验和 `codesign --verify --deep --strict` 通过。支持图片均可解码并在窗口加载。实际启动平台为 arm64 |
| 原生窗口 | Canon EOS R CR3 从文件选择器导入。重命名分组，⌘Z 回到默认名、⇧⌘Z 恢复，Finder 选中原片。关闭音轨后静音字段保留，保存工程可重开。操作三种外观选项并确认浅色界面。单独开/关同一音轨的导出由 ffprobe 复核，启用时有 AAC，禁用时仅有视频 |
| 长视频（SDR 合成源，3 fps） | 1080p 600 秒以 1 fps 生成 600 张 JPEG，约 20.2 MB，带 PCM。清理后由工程及原视频重建画面和原声。4K 180 秒以 1 fps 生成 180 张 JPEG，约 23.6 MB。未负载测试 18,000 帧、真实长 RAW/视频混合工作流或物理磁盘写满 |
| 双向工程（Mac + Mac 上 Python/Qt 代码） | ARW、NEF、CR2、CR3、RAF、DNG 共六种，各测两种策略。Swift 保存 → Python 读取、还原并导出。Python 保存并换成 Windows 盘符及相对路径 → Swift 重定位、保留分组名、RAW 策略、禁用音轨，重存并导出。待实体 Windows 对同一工程复测 |
| Python/Qt 补测（Mac） | 167 项通过、0 跳过，使用实际目录作为 `TMPDIR`。Mac 默认目录经过 `/var` 符号链接时，Windows 套件有 1 项工程指纹断言失败。带短循环音源的 FFmpeg 导出在 Mac 的 Python 路径中出现等待，终止进程后非循环对照通过。Windows 行为待实机核对 |
| 真实鸟眼识别 | 两张公开 CC0 鸟类 JPEG 均检出目标和可见鸟眼（2/2）。RAW 样本用于验证解码、EXIF、分析流水线和导出，真实 RAW 鸟眼连拍待复测。[样本 1](https://commons.wikimedia.org/wiki/File:A_Mallard.jpg) · [样本 2](https://commons.wikimedia.org/wiki/File:Mallard_duck.11.jpg) |

七份 RAW 来自 [raw.pixls.us](https://raw.pixls.us/) 的公开 CC0 样本，下载逐文件核对目录 SHA256。实际读到 EXIF 机型和拍摄日期，两种渲染策略分别完成分析和 H.264 导出。另用同名 RAW/JPEG 校验 JPEG 优先、RAW 优先、两者保留和损坏 JPEG 的配对行为。内嵌预览缩到 300×200 后与 Mac 上 LibRaw 预览的平均 RGB 绝对差为 0.54–0.86 / 255，含测试 JPEG 再编码误差。此结果只覆盖这些样本。

| 相机及压缩样本 | ImageIO 内嵌预览 | CIRAWFilter 解码 |
|---|---:|---:|
| Sony A7 III ARW，14-bit 压缩（2414） | 1616×1080 | 6000×4000 |
| Nikon Z6 NEF，14-bit 压缩（3581） | 6048×4024 | 6048×4024 |
| Canon 5D Mark IV CR2（983） | 6720×4480 | 6720×4480 |
| Canon EOS R CR3（4515） | 6720×4480 | 6720×4480 |
| Fujifilm X-T2 RAF，14-bit 无损压缩（865） | 1920×1280 | 6000×4000 |
| Ricoh GR III DNG（3115） | 6000×4000 | 6000×4000 |
| Nikon Z8 NEF，高效率低（6616） | 8256×5504 | 8256×5504 |

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
| 2026-11-15 · 同上 | 同机 | 照片导入排序夹具：混合有无 EXIF 拍摄时间与接近时间戳 | 通过，有时间的按时间在前、无时间的按文件名排最后，结果确定 |
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
