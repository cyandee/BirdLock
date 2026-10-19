# BirdLock 鸟眼锁定

把飞鸟连拍照片自动对齐到鸟眼，合成为鸟头稳定、翅膀运动的视频。支持原生 macOS 版（SwiftUI / Core ML）和 Windows 版（Python / Qt / ONNX Runtime），照片识别、编辑和视频合成在本地完成。

## 版本、下载与反馈

当前源码版本为 **1.4.0**，由根目录 [VERSION](VERSION) 统一管理。**源码同步与安装包发布分开进行：本次更新源码和文档，尚未创建1.4.0标签或Release；下载安装包请核对Releases中的实际版本。**

- [下载安装包 / 查看历史测试版](https://github.com/cyandee/BirdLock/releases)
- [报告问题](https://github.com/cyandee/BirdLock/issues) · [反馈邮箱](mailto:cyanodee@gmail.com)：`cyanodee@gmail.com`
- [macOS 使用说明](docs/使用说明.md) · [Windows 使用说明](docs/windows/使用说明.md) · [文档导航](docs/README.md)

macOS 版支持 macOS 14+、Apple 芯片和 Intel；Windows 便携版面向 Windows 10/11 x64。macOS 15.4+ 可使用系统 AI 光流补帧。通用构建已完成，但实体 Intel Mac、Windows 实体显卡和低内存设备仍需补测。macOS 当前为临时签名，尚未进行 Developer ID 签名和 Apple 公证，详见[构建与发布](docs/构建与发布.md)。

## 1.4.0 更新

- **连拍组排序**：导入多组照片后选择合并，上移/下移调整片段播放顺序；手动修正、排除标记和特写跟随原照片，组内保留拍摄顺序和各组连拍速度，不跨组补帧。
- **特写单次快门声**：选择照片替换原时段，独立调时长、放大、构图和动态框；新增特写开始时可播放一次快门声，支持开关和独立音量，与背景音乐共存。
- **相机 → fps / 录音**：使用维护者提供的完整原录音循环，不变速模拟其他档位。
- **联系与支持**：统一邮箱 `cyanodee@gmail.com`，提供自愿[请作者喝杯咖啡](docs/赞赏.md)页面。全部功能免费，赞赏不影响使用。

| 相机菜单 | 录音档位 |
|---|---|
| 索尼 A1 II（A1M2） | 5 / 10 / 15 / 20 / 30 fps |
| 索尼 A9 III（A93） | 60 / 120 fps |
| 索尼 A7 V（A7M5） | Hi+ 30 fps / Mid 15 fps |
| 索尼 A7R VI（A7R6） | 原录音，fps尚未确认 |
| 尼康 Z8 | 20 fps |

单张快门使用另行标注来源的通用 Canon Digital Rebel 单拍声（CC0），不是上述各型号专用单拍录音。详见[音效资源说明](SharedResources/Audio/README.md)。旧A1 II保存选择会迁移到新录音；旧缓存特写保持无声，可手动开启。

## 功能

| 类别 | 功能 |
|---|---|
| 导入与组片 | JPG、HEIF/HEIC、PNG、TIFF；按拍摄时间排序；归为一组或按快门间隔分组；单组切换、多组合并和顺序调整；不导入外部视频作为片段 |
| 鸟类锁定 | 鸟眼 / 鸟头；遮挡时推算；可手动修正、选择主体、排除照片和裁剪起止范围 |
| 虚拟对焦框 | 鸟眼、鸟头、含展开翅膀的鸟身分别启用和配色；鸟身大小独立调整；方框 / 四角框 |
| 快门模拟 | 鸟身闪烁与画面内侧边框；边框大小、颜色和1—120次/秒；实际视觉效果受视频帧率采样限制 |
| 飞机（试验） | 机身与自动机头定位、序列跟踪、独立设置/缓存、机头修正及导出；机头/机身框分别配色、调大小，保留快门模拟 |
| 构图 | 主体居中、前方留白、特写、全身/全机、柔和跟随等预置；缩放、移动、旋转、平移取景、模糊延展或黑边 |
| 特写 | 替换所选照片时段，调整展示秒数、缩放、横纵构图、动态框、单拍声和音量 |
| 音频 | 背景音乐与多条独立音轨、内置快门及自行上传；音量、静音、起点、长度、循环、淡入淡出；预览与导出共用混音 |
| 卡点辅助 | 离线音乐节拍/能量高潮候选、画面候选和时点对齐；需人工试听确认，不宣称理解音乐语义 |
| 输出 | 多种横竖比例、自定义比例、短边720—4320、24—120fps、速度、正放/倒放/往返、重复及淡入淡出 |
| 导出与水印 | H.264、HEVC；macOS另有ProRes；GIF、对齐图片序列；图片/文字水印与拍摄参数 |

飞机模型是通用文字区域检测器与图像跟踪组合，复杂倒置视角可能将翼尖误认为机头；受控变换测试不等于真实连拍精度。请逐帧检查并按需修正，详见[飞机模型与限制](docs/飞机识别调研.md)。

## 快速开始

从Releases下载并完整解压Windows ZIP，或从完整Mac DMG复制整个.app。先核对随版本提供的SHA256，再导入连拍照片、选择主体与构图、试听预览并导出。请保留原始照片和需要的成片。

macOS 从源码构建：

```zsh
zsh scripts/build_app.sh       # dist/BirdLock.app
zsh scripts/make_dmg.sh        # dist/BirdLock-1.4.0.dmg，Apple芯片+Intel通用版
```

Windows 构建与自检见 [windows/README.md](windows/README.md)。飞机权重由构建脚本按固定版本和SHA256准备，约204MB，不提交普通Git；分发包内已包含，应用运行时不联网下载。[统一构建流程](docs/构建与发布.md)支持手动构建，以及经批准推标签后创建含双平台、源码、校验值的同一个Release草稿。

## 目录与模型

```text
Sources/BirdLockCore/          识别、跟踪、构图、渲染、混音和导出
Sources/BirdLockAircraftRuntime/  独立飞机部位推理运行库
Sources/BirdLockApp/           macOS SwiftUI界面
Sources/BirdLockCLI/           macOS命令行工具
windows/                      Windows Qt界面、算法和打包
Models/                       现有Core ML鸟类模型
SharedResources/Audio/        双平台音效及来源/哈希
SharedResources/AircraftModels/  飞机固定模型清单与完整许可
SharedResources/Support/      维护者提供的自愿赞赏图片
docs/                         使用、维护、验收和许可说明
scripts/                      构建、分发完整性检查与辅助脚本
Tests/、windows/tests/        自动回归
```

鸟类检测保留原YOLO11m；随包姿态为eye-pose-v0六关键点模型（喙、双眼、头顶、双肩），没有替换为训练目录中的十五关键点实验。模型来源和许可见[第三方许可](docs/第三方许可.md)。

macOS 缓存在 `~/Library/Caches/BirdLock`；Windows 优先保存在应用目录的 `data/cache`，不可写时回退到用户数据目录。缓存包含手动修正、排除和特写，清空前请保存需要的成片。目前尚未提供独立可迁移的工程文件。

## 文档、验证与支持

[版本记录](docs/迭代记录.md) · [验收清单](docs/整批功能验收清单.md) · [构建与发布](docs/构建与发布.md) · [用户协议](docs/用户协议.md) · [Windows第三方许可](docs/windows/第三方许可.md)

1.4.0本地验证包括Swift44项、Mac/Windows各62项、资源/分发11项，以及Windows成品80次布局、H.264/HEVC导出和短音频回归。验证范围与待测设备详见验收清单；云端workflow另以实际运行结果为准。

BirdLock依据[AGPL-3.0](LICENSE)开源。如果愿意，可[请作者喝杯咖啡](docs/赞赏.md)，5、10、20元或任意金额均随意。反馈邮箱：`cyanodee@gmail.com`。
