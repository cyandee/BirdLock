"""Build or stage a complete telemetry component for local distribution packaging."""
import argparse
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_checks import verify_telemetry

ROOT = Path(__file__).resolve().parents[1]


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--directory', type=Path, required=True)
    parser.add_argument('--platform', choices=['macos', 'windows'], required=True)
    parser.add_argument('--universal', action='store_true')
    args = parser.parse_args()
    windows = args.platform == 'windows'
    name = 'BirdLockTelemetry.exe' if windows else 'BirdLockTelemetry'
    destination = args.directory.resolve()
    explicit = os.environ.get('BIRDLOCK_TELEMETRY_HELPER')
    if explicit:
        source = Path(explicit).resolve()
        verify_telemetry(source, source.parent, windows=windows, universal=args.universal, source_root=ROOT)
        if source.parent != destination:
            destination.mkdir(parents=True, exist_ok=True)
            shutil.copy2(source, destination / name)
            shutil.copy2(source.parent / 'manifest.json', destination / 'manifest.json')
            shutil.copytree(source.parent / 'Licenses', destination / 'Licenses', dirs_exist_ok=True)
    else:
        try:
            verify_telemetry(destination / name, destination, windows=windows, universal=args.universal, source_root=ROOT)
        except (OSError, ValueError):
            cargo = os.environ.get('BIRDLOCK_CARGO') or shutil.which('cargo')
            if not cargo:
                raise SystemExit('请先安装 Rust/Cargo 构建陀螺仪组件，或用 BIRDLOCK_TELEMETRY_HELPER 指定完整预构建组件')
            if windows != (os.name == 'nt'):
                raise SystemExit('跨平台打包请用 BIRDLOCK_TELEMETRY_HELPER 指定对应平台的预构建组件')
            command = [sys.executable, '-I', str(ROOT / 'scripts/build_telemetry_helper.py'), '--cargo', cargo, '--output', str(destination / name)]
            if args.universal: command.append('--universal')
            subprocess.run(command, check=True, cwd=ROOT)
    verify_telemetry(destination / name, destination, windows=windows, universal=args.universal, source_root=ROOT)
    print('陀螺仪组件、架构与许可检查通过：', destination)


if __name__ == '__main__': main()
