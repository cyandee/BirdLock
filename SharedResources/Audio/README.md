# 快门音效

我把内置快门声整理成了「先选相机，再选档位」，以后增加相机时也比较好找。连拍声使用各档对应的完整录音，按原速循环播放。

| 相机 | 档位 |
|---|---|
| 索尼 A1 II（A1M2） | 5 / 10 / 15 / 20 / 30 fps |
| 索尼 A9 III（A93） | 60 / 120 fps |
| 索尼 A7 V（A7M5） | Hi+ 30 fps / Mid 15 fps |
| 索尼 A7R VI（A7R6） | 原录音，帧率暂未确认 |
| 尼康 Z8 | 20 fps |

添加音轨后仍可以更换相机和档位，也可以导入自己的音频。内置录音共 11 条，加上下面的单张快门声，一共 12 条。每条音频的来源、时长和 SHA256 都列在 [library.json](library.json)。

## 特写的单张快门声

特写开始时用的是 benjohansen 在 Freesound 发布的 **dslr-shutter.wav**，录制设备为 Canon Digital Rebel，约 0.232 秒，采用 CC0 1.0 许可。

- [原作品](https://freesound.org/people/benjohansen/sounds/87149/)
- [官方公开预览](https://cdn.freesound.org/previews/87/87149_1409877-hq.mp3)
- [CC0 1.0](https://creativecommons.org/publicdomain/zero/1.0/)

软件内的 `single-canon-rebel.wav` 由官方公开预览转成 48 kHz、单声道、PCM16 的 WAV，未变速。这是一个通用单拍音效，与上表相机的连拍录音分开使用。

新建特写默认响一次，可以关闭或单独调音量。延长特写不会重复播放，旧版本保存的无声特写也不会自动加声音。

## 旧设置

旧的 `sony-10` 对应现在 A1 II 的 10 fps；`sony-20` 对应现在的 30 fps（旧菜单已显示为 30 fps）。其他失效的旧声音会提示重新选择。旧派生文件不再放进当前菜单。

操作方法见 [Mac 说明](../../docs/使用说明.md)和 [Windows 说明](../../docs/windows/使用说明.md)。有问题请联系我：cyanodee@gmail.com。
