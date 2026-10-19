# 飞机模型资源



飞机模式使用固定版本的 [Grounding DINO tiny](https://huggingface.co/IDEA-Research/grounding-dino-tiny)，权重来自 [ONNX Community 的转换](https://huggingface.co/onnx-community/grounding-dino-tiny-ONNX)。两个模型页标注 Apache-2.0。

这是通用文字区域检测模型，没有专门训练飞机机头，小目标、倒置和遮挡时可能找错。具体测试情况见[飞机识别](../../docs/飞机识别调研.md)。

## 准备权重



`manifest.json` 保存固定版本、下载地址、大小、SHA256、查询词和输入参数。权重约 204 MB，不提交普通 Git，两端打包脚本会准备并复制到安装包。

```sh
python3 scripts/fetch_aircraft_model.py
```

`--source-file <模型文件>` 可以复用已经下载的文件，`--directory <目录>` 可以指定另一个含 manifest 的资源目录。脚本只从固定 HTTPS 版本下载，检查大小和完整 SHA256，再安装文件；已有有效文件直接复用，不符时保留并报错，中断时清理本次临时文件。新文件设为普通可读权限。

应用使用包内模型，启动分析前再次检查大小和 SHA256，不会联网下载模型或上传照片。

## 运行库和内存



Mac 的独立库 `BirdLockAircraftRuntime` 使用微软官方 ONNX Runtime Swift 1.24.2，固定源码提交为 `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`，Package.resolved 记录依赖，官方包声明二进制校验值。

CPU 线程最多 4 个，每项分析使用串行会话，完成或取消后释放。飞机分析会排队，机身检测器先释放，再进入机头模型阶段，避免同时加载多份模型。鸟类仍走原来的 Core ML 模型。

Mac 完整测试进程的内存峰值约 3.53 GB，低内存设备还需要补测。开发时请保留单任务限制，别把多张照片的大模型推理并行展开。

## 许可文件



`Licenses/` 包含 Apache-2.0、ONNX Runtime 和 Swift 绑定的 MIT 声明，以及 [ONNX Runtime 1.24.2 的完整第三方声明](https://github.com/microsoft/onnxruntime/blob/v1.24.2/ThirdPartyNotices.txt)。完整声明为 325054 字节，已核对官方内容的 Git blob SHA1。

`Licenses/checksums.json` 记录各许可文件的大小和 SHA256。两端构建前会检查，缺失或截断时停止；打包后还要检查这些文件是否完整复制。

联系我：cyanodee@gmail.com。
