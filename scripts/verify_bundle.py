"""Validate a Mac distribution bundle without launching it or changing its files."""
import argparse
import json
import os
import plistlib
import struct
import hashlib
import base64
from urllib.parse import urlsplit
from pathlib import Path
if __package__:
    from .package_checks import verify_telemetry
else:
    import sys
    sys.path.insert(0, str(Path(__file__).resolve().parent))
    from package_checks import verify_telemetry


def verify_aircraft(directory: Path):
    meta = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    name = meta.get("file", "")
    if not name or Path(name).name != name or "\\" in name or ".." in name:
        raise ValueError("飞机资源文件名无效")
    model = directory / name
    if not model.is_file() or model.stat().st_size != meta["bytes"]:
        raise ValueError("缺少完整飞机部位模型")
    digest = hashlib.sha256()
    with model.open("rb") as stream:
        for block in iter(lambda: stream.read(1024*1024),b""):digest.update(block)
    if digest.hexdigest() != meta["sha256"]:
        raise ValueError("飞机模型校验失败")
    if model.stat().st_mode & 0o444 != 0o444:
        raise ValueError("飞机模型必须可供其他Mac账户读取")
    licenses = directory / "Licenses"
    checksums = json.loads((licenses/"checksums.json").read_text(encoding="utf-8"))
    for license in ("Apache-2.0.txt","ONNXRuntime-MIT.txt","ONNXRuntime-Swift-MIT.txt","ONNXRuntime-ThirdPartyNotices.txt"):
        file = licenses/license
        if not file.is_file():raise ValueError("缺少飞机模型或运行库许可："+license)
        content = file.read_bytes();entry = checksums.get(license,{})
        if len(content) != entry.get("bytes") or hashlib.sha256(content).hexdigest() != entry.get("sha256"):
            raise ValueError("飞机许可文件不完整："+license)


def verify_lens_profiles(directory: Path):
    meta = json.loads((directory / "manifest.json").read_text(encoding="utf-8"))
    commit = meta.get("upstreamCommit", "")
    if (meta.get("schema") != 1 or meta.get("license") != "CC0-1.0"
            or meta.get("upstream") != "https://github.com/gyroflow/lens_profiles"
            or len(commit) != 40 or any(c not in "0123456789abcdef" for c in commit)):
        raise ValueError("镜头配置来源或许可清单无效")
    license_name = meta.get("licenseFile")
    if license_name != "CC0-1.0.txt":
        raise ValueError("缺少镜头配置 CC0 许可")
    license = directory / license_name
    if not license.is_file() or hashlib.sha256(license.read_bytes()).hexdigest() != meta.get("licenseSHA256"):
        raise ValueError("镜头配置 CC0 许可文件不完整")
    if not (directory / "README.md").is_file():
        raise ValueError("缺少镜头配置来源说明")
    entries = meta.get("profiles")
    if not isinstance(entries, list) or not entries:
        raise ValueError("内置镜头配置清单为空")
    ids, names = set(), set()
    source_prefix = f"https://github.com/gyroflow/lens_profiles/blob/{commit}/"
    for entry in entries:
        name, identifier = entry.get("file", ""), entry.get("id", "")
        if (not name or Path(name).name != name or "\\" in name or ".." in name
                or not identifier or identifier in ids or name in names):
            raise ValueError("内置镜头配置文件名或标识无效")
        ids.add(identifier); names.add(name)
        if not entry.get("sourceURL", "").startswith(source_prefix):
            raise ValueError("内置镜头配置未固定官方来源：" + name)
        file = directory / name
        if not file.is_file() or hashlib.sha256(file.read_bytes()).hexdigest() != entry.get("sha256"):
            raise ValueError("内置镜头配置校验失败：" + name)


def verify_updater(app: Path, version: str, info: dict):
    if tuple(map(int,version.split('.'))) < (1,5,0):return
    if info.get('CFBundleVersion')!=version:raise ValueError('更新版本号必须与 VERSION 一致')
    framework=app/'Contents/Frameworks/Sparkle.framework'
    if not (framework/'Sparkle').is_file() or not (app/'Contents/Resources/Sparkle-LICENSE.txt').is_file():
        raise ValueError('缺少 Sparkle 更新框架或许可')
    if 'SUFeedURL' in info:
        u=urlsplit(info['SUFeedURL'])
        if u.scheme!='https' or not u.hostname or u.username or u.password:raise ValueError('更新清单必须使用 HTTPS')
        try:valid=len(base64.b64decode(info.get('SUPublicEDKey',''),validate=True))==32
        except ValueError:valid=False
        if not valid or info.get('SURequireSignedFeed') is not True or info.get('SUVerifyUpdateBeforeExtraction') is not True:
            raise ValueError('必须验证更新清单和更新包签名')


def verify(app: Path, version: str, universal: bool = False):
    info = plistlib.loads((app / "Contents/Info.plist").read_bytes())
    if info.get("CFBundlePackageType") != "APPL":
        raise ValueError("应用包类型不是 APPL")
    if info.get("CFBundleShortVersionString") != version:
        raise ValueError("应用版本与 VERSION 不一致")
    name = info.get("CFBundleExecutable", "")
    if not name or Path(name).name != name:
        raise ValueError("应用启动入口无效")
    binary = app / "Contents/MacOS" / name
    data = binary.read_bytes()
    if not os.access(binary, os.X_OK):
        raise ValueError("启动文件缺少执行权限")
    thin = {b"\xcf\xfa\xed\xfe", b"\xfe\xed\xfa\xcf"}
    fat = data[:4] == b"\xca\xfe\xba\xbe"
    if not fat and data[:4] not in thin:
        raise ValueError("启动文件不是 Mach-O 可执行文件（可能为传输后的链接占位文件）")
    helper = app / "Contents/MacOS/BirdLockInterpolation"
    if not helper.is_file() or not os.access(helper, os.X_OK):
        raise ValueError("缺少可执行的光流辅助进程")
    header = helper.read_bytes()[:8]
    if header[:4] not in thin and header[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("光流辅助进程不是有效的 Mach-O 文件")
    if universal and header[:4] != b"\xca\xfe\xba\xbe":
        raise ValueError("光流辅助进程缺少通用架构")
    if universal:
        if not fat:
            raise ValueError("分发包必须同时包含 Intel 和 Apple 芯片架构")
        count = struct.unpack_from(">I", data, 4)[0]
        arches = {struct.unpack_from(">I", data, 8 + 20 * i)[0] for i in range(count)}
        if not {0x01000007, 0x0100000C}.issubset(arches):
            raise ValueError("通用程序缺少 Intel 或 Apple 芯片架构")
    verify_updater(app,version,info)
    resources = app / "Contents/Resources"
    verify_telemetry(app / 'Contents/MacOS/BirdLockTelemetry', resources / 'Telemetry', universal=universal)
    verify_aircraft(resources / "AircraftModels")
    verify_lens_profiles(resources / "LensProfiles")
    audio = resources / "Audio"
    entries = json.loads((audio / "library.json").read_text(encoding="utf-8"))
    if len(entries) != 12 or len({e["id"] for e in entries}) != 12 or "single-canon-rebel" not in {e["id"] for e in entries}:
        raise ValueError("内置音效清单不完整")
    for entry in entries:
        if Path(entry["file"]).name != entry["file"] or hashlib.sha256((audio / entry["file"]).read_bytes()).hexdigest() != entry["sha256"]:
            raise ValueError("内置音效校验失败：" + entry["id"])
    support = resources / "Support"
    manifest = json.loads((support / "manifest.json").read_text(encoding="utf-8"))
    if hashlib.sha256((support / "alipay-coffee.jpg").read_bytes()).hexdigest() != manifest["sha256"]:
        raise ValueError("赞赏图片校验失败")
    if not (audio / "silence.wav").is_file():
        raise ValueError("缺少混音静音资源")
    if (resources / "VERSION").read_text().strip() != version:
        raise ValueError("随包版本文件不一致")
    for name in ("BirdDetector", "BirdPose"):
        model = resources / "Models" / (name + ".mlmodelc")
        for file in ("metadata.json", "model.mil", "coremldata.bin", "weights/weight.bin"):
            if not (model / file).is_file() or (model / file).stat().st_size == 0:
                raise ValueError("缺少识别模型资源：" + name + "/" + file)
    schema = json.loads((resources / "Models/BirdPose.json").read_text(encoding="utf-8"))
    metadata = json.loads((resources / "Models/BirdPose.mlmodelc/metadata.json").read_text(encoding="utf-8"))[0]
    keypoint_shape = json.loads(metadata["userDefinedMetadata"]["kpt_shape"])
    if len(schema["keypoints"]) != keypoint_shape[0]:
        raise ValueError("关键点描述与随包模型不匹配")
    if not (resources / "Docs/使用说明.pdf").is_file():
        raise ValueError("缺少随包使用说明")


if __name__ == "__main__":
    parser = argparse.ArgumentParser()
    parser.add_argument("app", type=Path, nargs="?")
    parser.add_argument("--version")
    parser.add_argument("--aircraft-resources", type=Path)
    parser.add_argument("--lens-resources", type=Path)
    parser.add_argument("--universal", action="store_true")
    parser.add_argument("--telemetry-resources", type=Path)
    parser.add_argument("--telemetry-binary", type=Path)
    parser.add_argument("--telemetry-windows", action="store_true")
    args = parser.parse_args()
    if args.telemetry_resources:
        if not args.telemetry_binary: parser.error('需要 --telemetry-binary')
        verify_telemetry(args.telemetry_binary, args.telemetry_resources, windows=args.telemetry_windows, universal=args.universal)
        print('陀螺仪组件、架构与许可完整性检查通过')
        raise SystemExit(0)
    if args.aircraft_resources:
        verify_aircraft(args.aircraft_resources)
        print("飞机权重与许可完整性检查通过")
        raise SystemExit(0)
    if args.lens_resources:
        verify_lens_profiles(args.lens_resources)
        print("内置镜头配置、固定来源与 CC0 许可完整性检查通过")
        raise SystemExit(0)
    if args.app is None or args.version is None:parser.error("需要应用路径和--version")
    verify(args.app, args.version, args.universal)
    print("应用包结构、执行文件、版本及资源检查通过")
