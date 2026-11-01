# BirdLock telemetry reader

本辅助进程只读取遥测数据并输出 JSON，不修改相机原片，不访问网络，不替代画面与陀螺仪的同步校验。程序随 BirdLock 一起分发，使用者无需安装 Gyroflow 或 Rust。

解析库为 [telemetry-parser](https://github.com/AdrianEddy/telemetry-parser)，固定提交 `19bc11f8c13eaa07ec1988bf0a55884f3fcc0f96`（MIT OR Apache-2.0）；依赖版本由 Cargo.lock 固定。Sony MP4/MOV RTMD、GoPro GPMF、受解析库支持的 DJI 遥测及外部 GCSV/JSONL 由该库读取。不是每台相机、每种拍摄模式或每个 MP4 都含有陀螺仪；存在数据轨本身不能证明有 IMU。

## 构建与打包

需要 Rust 2024 edition 编译工具链。Mac 分发包使用两个目标并合并为通用程序：

```sh
rustup target add aarch64-apple-darwin x86_64-apple-darwin
python3 scripts/build_telemetry_helper.py --universal --output dist/telemetry/macos/BirdLockTelemetry
```

Windows 可在安装原生 MSVC Rust 工具链及 Visual C++ Build Tools 的环境中构建：

```powershell
python scripts/build_telemetry_helper.py --output windows/telemetry/BirdLockTelemetry.exe
```

构建脚本同时生成 manifest.json、依赖许可清单及校验值。Mac 主构建脚本与 Windows PyInstaller 构建会检查组件的格式、架构、解析库版本、源码摘要、二进制及许可文件，组件缺失时尝试使用本机 Cargo 构建；也可设置 `BIRDLOCK_TELEMETRY_HELPER` 指向完整预构建目录中的同名可执行文件，旁边必须有对应 manifest.json 与 Licenses。源码更改后必须重新构建组件。

运行时放置位置为 Mac `Contents/MacOS/BirdLockTelemetry`、许可与清单在 `Contents/Resources/Telemetry/`；Windows 为 `_internal/telemetry/BirdLockTelemetry.exe` 及同目录清单、许可。Swift/Python 桥接读取本机文件，支持取消和超时。

## 输出协议（schema 1）

```sh
BirdLockTelemetry --input video.MP4 --output telemetry.json
BirdLockTelemetry --input motion.gcsv --probe
```

`samples[].t` 单位为秒，`samples[].gyro` 为 rad/s，`accel` 存在时为 m/s²。输出按时间递增，重复时间戳保留第一条，非有限时间/角速度会报错。GCSV 使用 tscale 与 gscale/ascale，非数字输入会报错，不会替换成零。GCSV 的时间起点沿用官方解析器归零规则；外部陀螺仪仍需相对当前视频求同步偏移。

`orientation: "XYZ"` 指 **Gyroflow 的 IMU 坐标**，X 向画面上、Y 向画面左、Z 朝观察者。它不是图像相机的 XYZ。映射标记 `imuFrame`、`cameraFrame` 和矩阵 `imuToCamera` 明确给出：

```text
Gyroflow IMU (up, left, back) → OpenCV camera (right, down, forward)
camera_gyro = (-imu_y, -imu_x, -imu_z)
imuToCamera = [[0,-1,0],[-1,0,0],[0,0,-1]]
```

依据为固定上游 `src/motioncam/mod.rs` 对 IMU frame 的明确说明，以及 Gyroflow `src/core/imu_integration/mod.rs` 把 IMU 向量转换为 `(-y, x, z)` 后积分。画面旋转（视频 display matrix）及用户安装角度还需由调用方处理。

`timestampsAccurate` 仅描述源格式是否提供可靠时钟，**不表示已与画面同步**。Sony 有可用 offset/frequency 标签时按数据包自身的频率、时钟单位重新排列采样时间，`sonyPacketTimed` 标识是否成功；同时尊重显式 rad/s 标志和有效零偏。缺少可用 gyro 时输出空数组和提示；识别到格式但解析失败会报错，避免误报“没有陀螺仪”。

`metadataFrameCount`、`gyroscopeFrameCount` 分别统计解析帧与含 Gyroscope 组的帧。`rawMetadataFrames` 导出有用的逐帧 Imager、Lens、IBIS、LensOSS、畸变、呼吸补偿等原始解码数据及时间，供动态焦距和内参处理；只导出存在的字段，不补造标定。默认组仅保留尺寸/帧率/稳像标志，跳过设备序列号和 GPS。`frameReadoutSeconds` 和读出方向同样仅在来源提供时输出。

`.gyroflow` 支持旧 JSON raw_imu 数组、base91/zlib/bincode raw_imu、新 base91/zlib/CBOR file_metadata 中的 raw_imu，以及本地 filepath 引用。项目 IMU 方向会应用；同步偏移、用户零偏、额外旋转和滤波保留为项目设置，调用方应明确处理并重新核验视频同步。仅含四元数而没有 raw_imu 的项目不转成虚构 gyro。拒绝网络引用与嵌套项目引用。

`--probe` 的 `partial` 为 true，只用于发现格式与可用数据；调用方不得把它当成完整稳像输入。最多支持 2,000,000 条 IMU 数据，项目及解压数据各不超过 128 MiB。

## 验证

```sh
cargo test --locked --manifest-path tools/telemetry/Cargo.toml
PYTHONPATH=windows python -m unittest windows.tests.test_telemetry_io
python -m unittest scripts.tests.test_telemetry_bundle
```

受控 GCSV fixture 的原始读数 `[100,-200,300] × gscale 0.01` 必须输出 `[1,-2,3] rad/s`；以实际进程同时检查时间、加速度、项目内嵌/相对引用与损坏输入。压缩项目格式另有 Rust 回归测试。

本轮真实 Sony ILCE-1M2 的 C0320.MP4（4K/119.88p）成功读取 840 帧 RTMD，含 FE 600mm F4 GM OSS 镜头与呼吸元数据；所有帧均没有标准 Gyroscope 组，故 IMU=0。与配套 XML 的 Gyroscope status=none 一致。不能用这段素材声称已验证 Sony 陀螺仪同步；它可用于视觉稳像验证。

本轮 Windows GNU x64 产物可在 Mac 交叉编译，PE 导入表只依赖 Windows 系统库。Windows 真机运行检查需在恢复可启动的测试虚拟机后补齐。
