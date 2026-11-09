# BirdLock Windows 开发与验收

Windows 版面向 Windows 10 / 11 x64，使用 Python 3.12 x64、PySide6、ONNX Runtime 和 FFmpeg。日常使用与下载见[Windows 使用说明](../docs/windows/使用说明.md)及 [GitHub Releases](https://github.com/cyandee/BirdLock/releases)。当前任务、提交和待测项见[双端开发交接](../docs/development/HANDOFF.md)。

## 1. 安装环境

1. 安装 Git for Windows。在安装器中保留 Git Credential Manager，首次推送时用有仓库写权限的 GitHub 账号登录。只有读取权限时可先克隆，提交用自己的 fork 开 PR。[Git for Windows](https://git-scm.com/install/windows)
2. 安装 Python 3.12 的 64 位 Windows 发行版，确保 `py` 可用。重新打开 PowerShell 后检查版本和架构，应看到 Python 3.12 及 AMD64。[Python 安装说明](https://docs.python.org/3.12/using/windows.html)
3. 实机 GPU 验收使用支持 DirectX 12 的显卡及其厂商驱动。打包或测试原生遥测组件时，再按第 6 节安装构建工具。[ONNX Runtime DirectML](https://onnxruntime.ai/docs/execution-providers/DirectML-ExecutionProvider.html)

```powershell
git --version
py -3.12 -c "import platform, sys; print(sys.version, platform.machine())"
```

## 2. 克隆并选择分支

```powershell
git clone https://github.com/cyandee/BirdLock.git
Set-Location BirdLock
git fetch origin
git switch main
git pull --ff-only origin main
```

接手现有任务时，从交接记录或 PR 复制分支名和 SHA。第一次检出远程任务分支可用下列命令，已有同名本地分支时用 `git switch $branch` 后 `git pull --ff-only`。核对 `git rev-parse HEAD` 与交接 SHA。接手写入前先在 PR 中与 Mac 端确认。并行开发从约定 SHA 创建各自的分支。

```powershell
$branch = 'codex/example-task'  # 按本次交接替换
git fetch origin
git switch --track "origin/$branch"
git status --short --branch
git rev-parse HEAD
```

新任务用 `git switch -c codex/<任务名> origin/main` 创建分支。仅验证某次交接时，可以用 `git switch --detach <交接SHA>` 检出该提交。切换前检查工作区是否干净。用 Windows Codex 打开克隆后的仓库根目录，读取 `AGENTS.md` 和交接记录后再开始工作。

## 3. 准备源码环境并启动

以下命令在仓库根目录执行。以后每次新开 PowerShell，从设置 `$python` 开始恢复环境，为验收创建新的临时目录。直接调用虚拟环境中的解释器即可。

```powershell
py -3.12 -m venv windows\.venv
$python = (Resolve-Path .\windows\.venv\Scripts\python.exe).Path
& $python -m pip install -r windows/requirements.txt -c windows/constraints-release.txt
$env:PYTHONPATH = (Resolve-Path .\windows).Path
$env:PYTHONUTF8 = '1'
$testRoot = Join-Path ([IO.Path]::GetTempPath()) ("birdlock-" + [guid]::NewGuid())
$env:BIRDLOCK_DATA = Join-Path $testRoot 'data'
New-Item -ItemType Directory -Force $env:BIRDLOCK_DATA | Out-Null
& $python -c "from build_windows import fetch_ffmpeg; fetch_ffmpeg()"
& $python .\windows\BirdLock.pyw
```

`fetch_ffmpeg()` 准备导出所需的 `windows\ffmpeg\ffmpeg.exe`。已有兼容的 FFmpeg 时，也可以将 `BIRDLOCK_FFMPEG` 指向该 exe 的绝对路径，替代下载步骤。鸟类模型随源码检出。飞机模式和对应回归需先运行 `& $python scripts/fetch_aircraft_model.py` 准备固定权重，再启动程序。保留日常设置和缓存，用上面的临时数据目录接收测试日志。

## 4. 单测、源码自检与 GUI 回归

```powershell
& $python -m unittest discover -v -s windows/tests -p 'test_*.py'
& $python -m birdlock.cli devices
& $python -m birdlock.cli selftest
& $python .\windows\BirdLock.pyw --smoketest
Get-Content (Join-Path $env:BIRDLOCK_DATA 'smoketest.log')
Test-Path (Join-Path $env:BIRDLOCK_DATA 'smoketest.png')
```

检查每条命令的 `$LASTEXITCODE`、单测跳过项和离屏截图。没有遥测辅助程序时，调用原生进程的单测会跳过。源码自检包含算法、资源、空白图推理和 FFmpeg 编码。`devices` 用于枚举适配器、执行提供器与编码器。真实识别和 GPU 验收见下节。

GUI 回归在登录到 Windows 的桌面会话执行。用获准在本机使用的素材，替换以下示例路径。鸟类连拍目录至少准备 12 张，另备飞机照片和各一段短 SDR 鸟类、飞机视频。用独立报告目录保留每次运行结果。

```powershell
Remove-Item Env:QT_QPA_PLATFORM -ErrorAction SilentlyContinue
$birds = 'D:\BirdLock-Test\birds'
$aircraft = 'D:\BirdLock-Test\aircraft'
$birdVideo = 'D:\BirdLock-Test\bird.mp4'
$aircraftVideo = 'D:\BirdLock-Test\aircraft.mp4'
& $python .\windows\BirdLock.pyw --gui-regression $birds (Join-Path $testRoot 'gui') --export
& $python .\windows\BirdLock.pyw --project-regression $birds (Join-Path $testRoot 'project')
& $python .\windows\BirdLock.pyw --subject-regression $birds $aircraft (Join-Path $testRoot 'subject')
& $python .\windows\BirdLock.pyw --video-regression $birdVideo $aircraftVideo (Join-Path $testRoot 'video')
```

依次检查退出码、对应报告目录的 JSON、窗口截图、输出视频以及数据目录的回归日志。四个入口以 CPU 识别，分别覆盖布局/编码、分组/工程/混音、主体切换/飞机、视频导入/镜头配置/导出。已有源码回归入口也支持成品 `BirdLock.exe`。成品测试以 `Start-Process -Wait -PassThru` 取得退出码，路径含空格时给各个参数保留引号。回归只读源照片，报告、导出和原始日志留在本机。

## 5. 实体显卡与真实素材

1. 在实体 Windows x64 桌面记录被测 SHA、系统版本、GPU 型号、驱动版本和 `devices` 的摘要。首次复测 1.10 后续改动时优先覆盖 RTX 3080。
2. 启动源码或成品。用同一批鸟类照片、再用同一批飞机照片分别比较两种设置。先在「输出 → 硬件加速 → AI 识别」选「仅用 CPU」，再选目标显卡。每次点击「重新识别」，确认发生真实推理并计时。保持同批素材、分析选项和范围，分别记录首轮加载与后续完整分析耗时。
3. 检查当前识别设备和数据目录的 `birdlock.log`。记录模型实际使用的 provider，飞机机头检查 `aircraft inference summary` 的节点分配、调用耗时及 `fallback`。单独记录 GPU、混合或 CPU 回退。无法确认执行分配时记待验证。显卡枚举、软件模拟、OpenCL 重采样和硬件编码各有独立含义。可从「帮助 → 导出诊断日志」取证，交接时仅记录脱敏摘要。[固定选眼、跟踪与飞机加速](../docs/自定义目标与固定选眼.md)
4. 用真实鸟类连拍检查导入、分组、识别、固定选眼、撤销及预览。用飞机素材检查机身和机头定位。用真实动物或昆虫连续照片手动框选、点锁定位置并给失锁处加参考帧。保存工程，重开并检查编辑和定位，最后用 H.264 / HEVC 导出并回放，核对帧序、构图、时长、声画及回退提示。
5. 用短 SDR 视频检查抽帧、镜头配置、原声混音和清理后的缓存重建。涉及陀螺仪改动时，用确认含有效 IMU 的原片或本地 GCSV，检查同步与回退。双端工程验证用同一套获准素材在两端互开和导出，必要时重新定位原片。[视频和镜头](../docs/视频导入与镜头配置.md) · [工程与缓存](../docs/工程与缓存管理.md)
6. 将环境、提交、操作、素材类型和数量、通过/失败/跳过/未执行及原因写进[测试矩阵](../docs/development/TEST_MATRIX.md)。托管 Windows、Mac Qt、ARM 模拟、离屏或 mock 结果各自记录。

## 6. 本地成品构建

安装支持 Rust 2024 edition 的 x64 MSVC Rust 工具链、Visual Studio Build Tools 的「使用 C++ 的桌面开发」工作负载与 Windows SDK。确认 `rustc -vV` 的 host 为 `x86_64-pc-windows-msvc`，且可访问系统 `%WINDIR%\Microsoft.NET\Framework64\v4.0.30319\csc.exe`。原生更新器运行需要 .NET Framework 4.8。已有符合清单和校验要求的原生遥测组件时可按工具文档复用。[Rust 安装](https://rust-lang.org/tools/install/) · [MSVC 安装](https://learn.microsoft.com/en-us/cpp/build/vscpp-step-0-installation) · [遥测构建](../tools/telemetry/README.md)

```powershell
& $python -m pip install -r windows/requirements.txt -c windows/constraints-release.txt pyinstaller
& $python .\windows\build_windows.py
```

脚本会准备遥测组件、飞机模型、FFmpeg、手册与更新器。输出为 `windows/dist/BirdLock/` 和 `windows/dist/BirdLock-<VERSION>-Windows-x64.zip`。版本读取根目录的 [VERSION](../VERSION)，显式传入的 `--version` 必须匹配。也可从目标 SHA 的完整 Actions 运行下载 `package-windows` 产物，解压其中的 ZIP，并在独立临时数据目录执行同一套成品验收。报告注明运行链接和 SHA。

```powershell
$exe = (Resolve-Path .\windows\dist\BirdLock\BirdLock.exe).Path  # 下载的成品请替换路径
foreach ($check in @('--selftest', '--smoketest')) {
    $process = Start-Process -FilePath $exe -ArgumentList $check -Wait -PassThru
    if ($process.ExitCode -ne 0) { throw "$check failed ($($process.ExitCode))" }
}
```

复核 `selftest.log`、`smoketest.log` 和新生成的 `smoketest.png`。托管的 [Windows 完整工作流](../.github/workflows/windows.yml)还编译并执行独立更新器的 C# 单测和集成测试。发布及签名步骤由维护者授权。[构建与发布](../docs/构建与发布.md) · [自动更新](../docs/自动更新.md)

## 7. 提交与交接

1. 修改对应平台的代码。涉及共享契约时核对两端实现并在 PR 中说明。同步远端后先看 `git status`，有分歧或另一端仍在写入时先协调。
2. 运行相关测试，更新[交接记录](../docs/development/HANDOFF.md)和[测试矩阵](../docs/development/TEST_MATRIX.md)。分开列出 Windows 实机、云端、离屏和其他环境结果。
3. 用 `git add -- <改动文件>` 显式暂存，检查 `git diff --cached` 与 `git diff --cached --check` 后执行 `git commit`。获交接写入权后，用 `git -c push.followTags=false push -u origin HEAD:refs/heads/<分支名>` 推送该分支。fork 协作者推送到自己的远端。
4. 创建或更新 PR，注明范围、环境、结果和未完成验证。跨平台并行子分支先进入约定的任务分支，由维护者审核最终 PR。[项目规范](../AGENTS.md)
