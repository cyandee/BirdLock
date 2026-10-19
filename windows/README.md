# BirdLock 鸟眼锁定 — Windows 版

当前源码1.4.0，Python 3.12 x64 + Qt/PySide6 + ONNX Runtime。鸟类算法与macOS原生版对应；支持照片组片排序、独立眼/头/身框、快门模拟、机头/机身试验识别、特写单拍声、相机/fps两级音效、多轨音乐和自愿赞赏。

使用方法见[Windows使用说明](../docs/windows/使用说明.md)，最新源代码与Releases安装包版本可能不同，请核对下载标签。[反馈邮箱](mailto:cyanodee@gmail.com)：cyanodee@gmail.com。

## 加速与回退

- 识别使用ONNX Runtime DirectML（支持DirectX12的NVIDIA/AMD/Intel设备），失败时回退CPU。
- 图像重采样可使用OpenCV OpenCL；视频编码优先NVENC/AMF/Quick Sync，不可用时回退x264/x265。
- 飞机部位网络为独立CPU推理，不替换鸟类姿态模型。复杂视角需逐帧检查机头；真实连拍、低内存及实体显卡精度仍待补测。
- Windows 10/11 x64为目标环境；Parallels Windows ARM中的x64模拟已用于本地回归，不能替代实体显卡验证。

## 开发和打包

在项目根目录的Windows PowerShell中执行：

```powershell
py -3.12 -m venv windows/.venv
windows/.venv/Scripts/python -m pip install -r windows/requirements.txt pyinstaller
windows/.venv/Scripts/python windows/BirdLock.pyw
$env:PYTHONPATH = "windows"
windows/.venv/Scripts/python -c "from build_windows import fetch_ffmpeg; fetch_ffmpeg()"
windows/.venv/Scripts/python -m unittest discover -s windows/tests -p "test_*.py"
windows/.venv/Scripts/python -m birdlock.cli selftest
windows/.venv/Scripts/python windows/build_windows.py
```

打包输出 `windows/dist/BirdLock/` 和 `windows/dist/BirdLock-1.4.0-Windows-x64.zip`。版本统一读取根目录[VERSION](../VERSION)；显式`--version`必须与它一致。首次构建需要联网取得固定飞机权重、FFmpeg和依赖，运行成品时不联网下载模型。

## 自动构建

统一入口为[release.yml](../.github/workflows/release.yml)，复用[windows.yml](../.github/workflows/windows.yml)。手动运行产生构建产物；经批准推送与VERSION匹配的`v*`标签后，汇总macOS DMG、Windows ZIP、同提交源码和SHA256SUMS，创建同一个Release草稿，仍需审核后发布。windows.yml单独手动运行只构建Windows产物，不直接发布Release。

## 回归与数据隔离

普通用户无需运行内部回归。开发测试前把`BIRDLOCK_DATA`指向一次性目录，避免修改正常用户偏好与缓存。

- `BirdLock.exe --selftest`：算法、模型、音效与赞赏资源自检。
- `BirdLock.exe --smoketest`：离屏启动检查。
- `BirdLock.exe --gui-regression <照片目录> <报告目录> --export`：真实窗口、布局与编码回归。
- `BirdLock.exe --project-regression <照片目录> <报告目录>`：多组照片、排序、编辑/缓存、特写单拍声、相机菜单、赞赏页、短音频延迟与静音回归，至少12张照片。
- `BirdLock.exe --subject-regression <鸟类目录> <飞机目录> <报告目录>`：主体切换、取消恢复、独立设置/缓存和飞机导出。

项目与主体回归入口未指定隔离目录会拒绝运行。照片只读，分组时间仅在内存构造。测试结束应关闭测试程序，回收测试产生的孤立控制台；不要按进程名无差别终止用户程序。

1.4本地Windows62项与成品回归已通过，具体范围见[验收清单](../docs/整批功能验收清单.md)。macOS上可运行Qt源码做开发回归，正式macOS版本使用独立SwiftUI/Core ML实现。
