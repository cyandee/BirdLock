"""Build the pinned telemetry reader; does not install toolchains or publish artifacts."""
import argparse
import hashlib
import json
import os
from pathlib import Path
import shutil
import subprocess
import sys

sys.path.insert(0, str(Path(__file__).resolve().parent))
from package_checks import telemetry_source_digest

ROOT = Path(__file__).resolve().parents[1]
MANIFEST = ROOT / 'tools/telemetry/Cargo.toml'


def main():
    parser = argparse.ArgumentParser()
    parser.add_argument('--cargo', default=shutil.which('cargo'))
    parser.add_argument('--output', type=Path, required=True)
    parser.add_argument('--universal', action='store_true')
    parser.add_argument('--target')
    args = parser.parse_args()
    if not args.cargo:
        raise SystemExit('Rust/Cargo is required to build BirdLockTelemetry; pass --cargo with an installed Cargo path')
    if args.universal and (sys.platform != 'darwin' or args.target):
        raise SystemExit('--universal requires macOS and cannot be combined with --target')
    targets = ['aarch64-apple-darwin', 'x86_64-apple-darwin'] if args.universal else [args.target]
    binaries = []
    env = os.environ.copy()
    if sys.platform == 'darwin': env.setdefault('MACOSX_DEPLOYMENT_TARGET', '14.0')
    for target in targets:
        command = [args.cargo, 'build', '--locked', '--release', '--manifest-path', str(MANIFEST)]
        if target: command += ['--target', target]
        subprocess.run(command, check=True, cwd=ROOT, env=env)
        windows = (target and 'windows' in target) or (target is None and os.name == 'nt')
        binary = MANIFEST.parent / 'target'
        if target: binary /= target
        binaries.append(binary / 'release' / ('birdlock-telemetry.exe' if windows else 'birdlock-telemetry'))
    args.output.parent.mkdir(parents=True, exist_ok=True)
    if args.universal:
        subprocess.run(['lipo', '-create', *map(str, binaries), '-output', str(args.output)], check=True)
    else: shutil.copy2(binaries[0], args.output)
    args.output.chmod(0o755)
    if sys.platform == 'darwin' and not (args.target and 'windows' in args.target):
        subprocess.run(['codesign', '--force', '--sign', '-', str(args.output)], check=True)
    licenses = args.output.parent / 'Licenses'
    licenses.mkdir(exist_ok=True)
    for name in ['telemetry-parser-MIT.txt', 'telemetry-parser-Apache-2.0.txt']:
        shutil.copy2(MANIFEST.parent / 'licenses' / name, licenses / name)
    if args.target and 'windows-gnu' in args.target:
        shutil.copytree(MANIFEST.parent / 'licenses/MinGW', licenses / 'MinGW', dirs_exist_ok=True)
    target = args.target or ('aarch64-apple-darwin' if args.universal else None)
    metadata_command = [args.cargo, 'metadata', '--locked', '--format-version', '1', '--manifest-path', str(MANIFEST)]
    if target: metadata_command += ['--filter-platform', target]
    metadata = json.loads(subprocess.check_output(metadata_command, cwd=ROOT, env=env))
    packages = sorted((dict(name=p['name'], version=p['version'], license=p.get('license'), source=p.get('source')) for p in metadata['packages']), key=lambda p:(p['name'],p['version']))
    (licenses / 'dependencies.json').write_text(json.dumps(packages, indent=2)+'\n', encoding='utf-8')
    for package in metadata['packages']:
        source = Path(package['manifest_path']).parent
        texts = set()
        for pattern in ('LICENSE*', 'LICENCE*', 'COPYING*', 'NOTICE*', 'license*', 'licence*', 'copying*', 'notice*'):
            texts.update(p for p in source.glob(pattern) if p.is_file())
        if package.get('license_file'):
            texts.add(source / package['license_file'])
        if package['name'] == 'birdlock-telemetry': texts.add(ROOT / 'LICENSE')
        destination = licenses / 'Crates' / (package['name']+'-'+package['version'])
        destination.mkdir(parents=True, exist_ok=True)
        for text in texts:
            if text.is_file(): shutil.copy2(text, destination / text.name)
    rustc = env.get('RUSTC') or str(Path(args.cargo).with_name('rustc' + ('.exe' if os.name == 'nt' else '')))
    if not Path(rustc).is_file(): rustc = shutil.which('rustc') or rustc
    sysroot = Path(subprocess.check_output([rustc, '--print', 'sysroot'], env=env, text=True).strip())
    runtime = sysroot / 'share/doc/rust'
    destination = licenses / 'RustRuntime'
    destination.mkdir(exist_ok=True)
    for name in ('COPYRIGHT-library.html', 'COPYRIGHT.html', 'COPYRIGHT', 'LICENSE-MIT', 'LICENSE-APACHE'):
        if (runtime / name).is_file(): shutil.copy2(runtime / name, destination / name)
    if (runtime / 'licenses').is_dir(): shutil.copytree(runtime / 'licenses', destination / 'licenses', dirs_exist_ok=True)
    if not any(destination.iterdir()): raise SystemExit('Rust runtime license files are missing from the build toolchain')
    checks = {p.relative_to(licenses).as_posix(): dict(bytes=p.stat().st_size, sha256=hashlib.sha256(p.read_bytes()).hexdigest())
              for p in licenses.rglob('*') if p.is_file() and p.name != 'checksums.json'}
    (licenses / 'checksums.json').write_text(json.dumps(checks, indent=2)+'\n', encoding='utf-8')
    manifest = dict(schema=1, helperVersion='1.0.0', telemetryParserRevision='19bc11f8c13eaa07ec1988bf0a55884f3fcc0f96',
                    binary=args.output.name, bytes=args.output.stat().st_size,
                    sha256=hashlib.sha256(args.output.read_bytes()).hexdigest(), sourceSha256=telemetry_source_digest(ROOT),
                    target=args.target or ('universal-apple-darwin' if args.universal else sys.platform))
    (args.output.parent / 'manifest.json').write_text(json.dumps(manifest, indent=2)+'\n', encoding='utf-8')
    print('Built', args.output)


if __name__ == '__main__': main()
