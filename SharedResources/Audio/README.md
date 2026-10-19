# 内置快门音效

1.4源码使用维护者提供的相机录音，按「相机 → fps / 录音」选择：A1 II 5/10/15/20/30 fps、A9 III 60/120 fps、A7 V Hi+ 30 fps / Mid 15 fps、尼康 Z8 20 fps。A7R VI 未确认 fps，显示「原录音」。不通过变速模拟其他档位，连拍轨道直接循环对应原文件。library.json 记录来源、原音频时长和 SHA256。

新 A1 II 各档使用对应完整原录音；旧 sony-10 / sony-20 保存 ID 分别迁移到 A1 II 10 / 30 fps（旧 sony-20 的菜单曾显示30）。旧派生录音和上传归档由维护者本地保留，不上传开发归档目录，也不出现在当前菜单；当前公开清单和构建使用本目录的12项有效资源。

## 单张快门

特写使用 `single-canon-rebel.wav`：benjohansen 的 **dslr-shutter.wav**，Canon Digital Rebel 单次快门，原作品约0.232秒，CC0 1.0。

- 作品与许可：https://freesound.org/people/benjohansen/sounds/87149/
- 官方公开预览：https://cdn.freesound.org/previews/87/87149_1409877-hq.mp3
- CC0：https://creativecommons.org/publicdomain/zero/1.0/
- 处理：公开预览转换为48kHz单声道PCM16，不变速。来源不是维护者自有相机录音，也不声称是上述相机的单张快门。

特写开始时播放一次，不循环；可单独关闭或调音量。旧缓存特写默认保持无声，新增特写默认启用。所有混音均在本地完成。

当前来源与哈希见 [library.json](library.json)，使用方法见[macOS说明](../../docs/使用说明.md)与[Windows说明](../../docs/windows/使用说明.md)。反馈：cyanodee@gmail.com。
