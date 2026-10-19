# 飞机部位模型开发资源

1.4源码已接入「飞机（试验）」模式，支持机头/机身、分组跟踪、独立缓存、构图、修正、预览与导出。双平台本地成品回归通过；模型语义误判、真实飞机连拍精度、低内存和实体显卡仍待补测。

`manifest.json` 固定模型版本、下载来源、大小、SHA256、查询词和输入参数。模型来自 [IDEA-Research Grounding DINO tiny](https://huggingface.co/IDEA-Research/grounding-dino-tiny) 的 [ONNX Community 转换](https://huggingface.co/onnx-community/grounding-dino-tiny-ONNX)，两者模型页均标注 Apache-2.0。模型是通用文字区域检测器，没有经过专用飞机机头数据微调；多方向一致也可能错到翼尖。

权重约204MB，受Git忽略，不直接提交普通Git。两平台构建脚本按固定清单准备该模型并随包复制，Mac还检查哈希、其他账户可读权限和许可资源。应用读取本地模型，运行前验证大小和SHA256；运行时不联网、不上传照片、不自动下载或覆盖文件。

本地构建资源入口为 `python3 scripts/fetch_aircraft_model.py`，可用 `--source-file <已下载模型>` 复用本地下载，或用 `--directory <含manifest的独立目录>` 做隔离验证。脚本核对固定HTTPS版本、大小和完整SHA256，再以不覆盖的方式安装；已有模型若不匹配会保留并报错，已有有效模型直接复用。中断或错误只清理本次临时文件。新文件保持普通可读权限，避免拷到其他Mac账户后读不了资源。Mac/Windows构建已调用此入口；不会自动改变旧交付包。

Mac独立库 `BirdLockAircraftRuntime` 使用微软官方 ONNX Runtime Swift 1.24.2 源码提交 `b7fb7f7dea8a2469e6335d95a61b8f36d0dc83b2`，Package.resolved固定版本，二进制依赖由官方包声明校验。CPU线程最多4个，每个分析任务使用一个串行会话，完成/取消后释放；不要把多张照片的大模型推理并行展开。该库已链接BirdLockApp，飞机任务通过单任务队列避免多份大模型重叠。机身检测器先释放再进入部位阶段；完整Mac进程峰值仍约3.53GB，低内存设备尚未验。鸟类分析保持原有Core ML模型。

`Licenses/` 保留Apache-2.0标准文本以及已取得的ONNX Runtime和Swift绑定的MIT声明。验证范围、已知失败和待测项见 [飞机识别与限制](../../docs/飞机识别调研.md)；同目录ONNXRuntime-ThirdPartyNotices.txt保留官方1.24.2完整声明，来源为 https://github.com/microsoft/onnxruntime/blob/v1.24.2/ThirdPartyNotices.txt 。Licenses/checksums.json记录各许可的大小与SHA256，两平台构建前核对，拒绝缺失或截断文本。官方完整声明为325054字节，已与GitHub内容接口的Git blob SHA1核对。实际分发包仍需核查完整性。

反馈邮箱：cyanodee@gmail.com
