# 内置镜头配置

383 份静态配置原样来自 Gyroflow 官方 `lens_profiles` 仓库，固定提交 `886fc616c9c2c788856f54c21d451b9cb7fc4f44`，遵循仓库 CC0-1.0 许可（随目录附全文）。每个文件的上游路径、作者、标定误差和 SHA256 在 `manifest.json` 中，数据没有修改。

原有 8 份经过别名与模式核对的自动匹配组合：

- Sony A7 IV + Sigma 28–70mm F2.8 @28mm，4K25。
- Sony FX3 + FE 24mm F1.4 GM，4K25。
- Sony FX3 + FE 16–35mm F2.8 GM II @16mm，4K59.94。
- Sony α6700 + E PZ 10–20mm F4 G @20mm，4K59.94。
- GoPro HERO11 Black Wide，4K119.88 16:9 / 5.3K29.97 4:3，HyperSmooth 关闭。
- DJI Mini 3 Pro，1080p29.97。
- DJI Osmo Action 3，155°超广角 4K59.94。

本轮另加入 375 份可搜索配置：Sony 110、DJI 50、GoPro 40、Canon 35、Nikon 35、Panasonic 30、Fujifilm 25、Blackmagic 20、Insta360 15、Olympus 15。均通过当前静态镜头模型解析，保留上游原始字节；这些新增条目的 `autoMatch` 为 false，需要用户核对机身、镜头、焦距、模式后手动选择，不把扩大数据库等同于全部自动识别。

搜索支持型号、镜头、尺寸/模式及常见品牌中文名，多个词同时匹配。

别名仅用于匹配型号；不会跨相机、镜头或焦距套用。变焦镜头必须有明确焦距；尺寸变化、帧率未知、机内裁切或已知电子防抖模式不匹配时保留候选供用户确认。GoPro 的 HyperSmooth 状态必须明确关闭才自动匹配。Sony A7 IV + Sigma 的28mm匹配标签取自上游文件名；其他数值均可在配置正文的焦距字段核对。原配置不包含本机/用户视频信息。

索尼 M01.XML 以 `NonRealTimeMeta` 保存机身、镜头、尺寸、帧率等信息。读取它可以帮助匹配；普通 XML 没有的畸变系数与陀螺仪样本不会被补造。实际 Sony ILCE-1M2 + FE600mm F4、4K119.88 原片需要优先使用其视频 RTMD 中的镜头数据，不能改套上述其他相机标定。

来源：[镜头库](https://github.com/gyroflow/lens_profiles/tree/886fc616c9c2c788856f54c21d451b9cb7fc4f44)、[官方标定教程](https://docs.gyroflow.xyz/app/getting-started/lens-calibration)、[Sony XML 官方解析实现](https://github.com/AdrianEddy/telemetry-parser/blob/master/src/sony/xml_metadata.rs)。
