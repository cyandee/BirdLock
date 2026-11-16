"""Run BirdLock's existing Windows checks and retain local evidence for each step."""
from __future__ import annotations

import argparse
import hashlib
import json
import os
from pathlib import Path
import platform
import re
import shutil
import subprocess
import sys
import time
from datetime import datetime
from uuid import uuid4

from acceptance_media import create_media, inference_evidence

WINDOWS = Path(__file__).resolve().parent
ROOT = WINDOWS.parent
APP = WINDOWS / "BirdLock.pyw"
SCRIPT = Path(__file__).resolve()
DML = "DmlExecutionProvider"
CPU = "CPUExecutionProvider"


def git(*args):
    return subprocess.check_output(["git", *args], cwd=ROOT, text=True, timeout=30).strip()


def inventory():
    import ctypes
    from importlib.metadata import version
    import winreg
    import onnxruntime as ort
    from birdlock.core import gpu, paths

    def registry(key, name):
        with winreg.OpenKey(winreg.HKEY_LOCAL_MACHINE, key) as handle:
            return winreg.QueryValueEx(handle, name)[0]

    def hash_file(path):
        with path.open("rb") as stream:
            return dict(bytes=path.stat().st_size, sha256=hashlib.file_digest(stream, "sha256").hexdigest())

    models = {}
    for path in sorted((WINDOWS / "models").glob("*.onnx")):
        relative = path.relative_to(ROOT).as_posix()
        details = hash_file(path)
        if git("hash-object", "--", relative) != git("rev-parse", f"HEAD:{relative}"):
            raise ValueError(f"Model differs from the checked out commit: {relative}")
        models[path.name] = details
    if set(models) != {"BirdDetector.onnx", "BirdPose.onnx"}:
        raise FileNotFoundError("Missing tracked bird models")
    from birdlock.core.aircraft import model_directory, verify_model
    aircraft_dir = model_directory()
    aircraft = aircraft_dir / "AircraftParts.onnx"
    if aircraft.exists():
        meta = verify_model(aircraft_dir)
        models[meta["file"]] = {k: meta[k] for k in ("bytes", "sha256", "revision")}
    memory_kib = ctypes.c_ulonglong()
    memory_gib = (round(memory_kib.value / 1024**2, 2)
                  if ctypes.windll.kernel32.GetPhysicallyInstalledSystemMemory(ctypes.byref(memory_kib)) else None)
    ffmpeg = paths.ffmpeg_path()
    ffmpeg = str(Path(ffmpeg).resolve()) if ffmpeg else None
    return dict(
        os=platform.platform(), release=registry(r"SOFTWARE\Microsoft\Windows NT\CurrentVersion", "DisplayVersion"),
        cpu=registry(r"HARDWARE\DESCRIPTION\System\CentralProcessor\0", "ProcessorNameString"),
        logical_processors=os.cpu_count(), installed_memory_gib=memory_gib,
        python=sys.version, architecture=platform.machine(), version=(ROOT / "VERSION").read_text().strip(),
        packages={k: version(k) for k in ("PySide6-Essentials", "numpy", "opencv-python-headless",
                                         "onnxruntime-directml", "pillow", "pillow-heif")},
        providers=ort.get_available_providers(), adapters=[vars(a) for a in gpu.list_adapters()],
        preferred_adapter=vars(gpu.best_adapter()) if gpu.best_adapter() else None,
        tools={name: shutil.which(name) for name in ("git", "gh", "winget", "rustc", "cargo", "cl", "msbuild")},
        models=models, ffmpeg=ffmpeg, ffmpeg_file=hash_file(Path(ffmpeg)) if ffmpeg else None,
    )


def worker(args):
    kind, *values = args
    if kind == "inventory":
        result = inventory()
    elif kind == "fixtures":
        result = {k: str(v) for k, v in create_media(Path(values[0]), values[1]).items()}
    elif kind == "inference":
        result = inference_evidence(values[0], *(Path(p) for p in values[1:]))
        provider = CPU if values[0] == "cpu" else DML
        models = result["bird"]["models"]
        if len(models) != 2 or any(not m["kernel_events"].get(provider) for m in models.values()):
            print(json.dumps(result, ensure_ascii=False, indent=2))
            raise SystemExit(f"Both bird models must execute kernels on {provider}")
        parts = result.get("aircraft_parts")
        if parts and (parts["fallback"] or provider not in parts["provider_list"] or
                      (provider == DML and not parts["kernel_events"].get(DML))):
            print(json.dumps(result, ensure_ascii=False, indent=2))
            raise SystemExit(f"Aircraft parts inference did not complete on {provider}")
    else:
        raise ValueError(f"Unknown worker: {kind}")
    print(json.dumps(result, ensure_ascii=False, indent=2))


def unit_counts(_directory, log):
    output = log.read_text(encoding="utf-8", errors="replace")
    ran = re.search(r"^Ran (\d+) tests? in ", output, re.M)
    summary = re.search(r"^(OK|FAILED)(?: \(([^)]*)\))?\s*$", output, re.M)
    if not ran or not summary:
        raise ValueError("No unittest summary")
    values = {key: int(n) for key, n in re.findall(r"([\w ]+?)=(\d+)", summary[2] or "")}
    values = {key.strip(): n for key, n in values.items()}
    total = int(ran[1])
    skipped = values.get("skipped", 0)
    expected = values.get("expected failures", 0)
    failed = sum(values.get(k, 0) for k in ("failures", "errors", "unexpected successes"))
    return dict(total=total, passed=total - failed - skipped - expected, failed=failed,
                skipped=skipped, expected_failures=expected, details=values)


def selftest_counts(_directory, log):
    output = log.read_text(encoding="utf-8", errors="replace")
    passed = len(re.findall(r" PASS\s*$", output, re.M))
    failed = len(re.findall(r" FAIL\s*$", output, re.M))
    return dict(total=passed + failed, passed=passed, failed=failed, skipped=0)


def verify_png(path):
    from PIL import Image
    with Image.open(path) as image:
        if image.format != "PNG" or min(image.size) <= 0:
            raise ValueError(f"Invalid screenshot: {path.name}")
        size = list(image.size)
        image.verify()
    return size


def smoke_artifacts(directory, _log):
    if "smoketest ok" not in (directory / "data" / "smoketest.log").read_text(encoding="utf-8"):
        raise ValueError("Missing smoketest completion marker")
    return dict(screenshot_size=verify_png(directory / "data" / "smoketest.png"))


class Acceptance:
    def __init__(self, mode):
        start = datetime.now().astimezone()
        self.root = ROOT / "local-tests" / "windows-acceptance" / (start.strftime("%Y%m%d-%H%M%S") + "-" + uuid4().hex[:8])
        self.root.mkdir(parents=True)
        self.report = dict(mode=mode, started=start.isoformat(), sha=git("rev-parse", "HEAD"),
                           dirty=bool(git("status", "--porcelain")), steps=[])
        self.write()
        print(f"Report: {self.root / 'report.json'}", flush=True)

    def write(self):
        self.report["summary"] = {status: sum(s["status"] == status for s in self.report["steps"])
                                  for status in ("passed", "failed", "skipped", "not_run")}
        pending = self.root / "report.tmp"
        pending.write_text(json.dumps(self.report, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
        pending.replace(self.root / "report.json")

    def note(self, name, status, reason):
        self.report["steps"].append(dict(name=name, status=status, reason=reason))
        self.write()
        print(f"{name}: {status} ({reason})", flush=True)

    def step(self, name, args, *, timeout=240, native=False, scale=None, media=None, inspect=None):
        directory = self.root / name
        directory.mkdir()
        data = directory / "data"
        data.mkdir()
        temp = directory / "temp"
        temp.mkdir()
        log = directory / "command.log"
        env = dict(os.environ, PYTHONPATH=str(WINDOWS), PYTHONUTF8="1",
                   PYTHONUNBUFFERED="1", BIRDLOCK_DATA=str(data), TEMP=str(temp), TMP=str(temp))
        if native:
            env["QT_QPA_PLATFORM"] = "windows"
        if scale:
            env["QT_SCALE_FACTOR"] = str(scale)
        command = list(map(str, args))
        start = time.monotonic()
        result = dict(name=name, status="running", command=command, exit_code=None,
                      cwd=str(ROOT), log=str(log.relative_to(self.root)),
                      data=str(data.relative_to(self.root)), native_qt=native, scale=scale, media=media)
        self.report["steps"].append(result)
        self.write()
        print(f"{name}: running", flush=True)
        try:
            with log.open("wb") as stream:
                proc = subprocess.run(command, cwd=ROOT, env=env, stdout=stream,
                                      stderr=subprocess.STDOUT, timeout=timeout)
            result.update(exit_code=proc.returncode, status="passed" if proc.returncode == 0 else "failed")
            if inspect:
                result["evidence"] = inspect(directory, log)
        except (OSError, ValueError, subprocess.SubprocessError) as error:
            result.update(status="failed", error=str(error))
        if result["status"] == "failed":
            logs = [log] + [p for p in data.glob("*.log") if p.name != "birdlock.log"]
            result["error_tail"] = {p.name: p.read_text(encoding="utf-8", errors="replace")[-2500:]
                                    for p in logs if p.is_file() and p.stat().st_size}
        result["seconds"] = round(time.monotonic() - start, 3)
        self.write()
        print(f"{name}: {result['status']} ({result['seconds']} s, exit {result['exit_code']})", flush=True)
        return result

    def regression(self, name, flag, inputs, report_name, ffmpeg, *, scale=1, export=False,
                   allow_untracked=False, media):
        out = self.root / name / "output"

        def inspect(_directory, _log):
            result = json.loads((out / report_name).read_text(encoding="utf-8"))
            result["screenshots"] = {p.name: verify_png(p) for p in sorted(out.glob("*.png"))}
            if not result["screenshots"]:
                raise ValueError("Regression generated no screenshots")
            preserved = {c["action"] + ".mp4" for c in result.get("export_recovery", {}).get("cancellations", [])}
            decoded = []
            with (out / "decode.log").open("wb") as stream:
                for video in sorted(p for p in out.iterdir() if p.suffix in (".mp4", ".mov") and p.name not in preserved):
                    command = [ffmpeg, "-nostdin", "-v", "error", "-xerror", "-i", str(video), "-f", "null", "-"]
                    stream.write((subprocess.list2cmdline(command) + "\n").encode("utf-8"))
                    stream.flush()
                    subprocess.run(command, stdout=stream, stderr=subprocess.STDOUT, check=True, timeout=120)
                    decoded.append(video.name)
            result["decoded_videos"] = decoded
            return result

        options = (["--export"] if export else []) + (["--allow-untracked"] if allow_untracked else [])
        return self.step(name, [sys.executable, APP, flag, *inputs, out, *options],
                         native=True, scale=scale, timeout=1200, media=media, inspect=inspect)


def main():
    if sys.argv[1:2] == ["--worker"]:
        worker(sys.argv[2:])
        return 0
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--mode", choices=("quick", "full"), default="quick")
    for name in ("birds", "aircraft", "birds-video", "aircraft-video"):
        parser.add_argument("--" + name, type=lambda p: Path(p).resolve())
    args = parser.parse_args()
    if sys.platform != "win32" or sys.version_info[:2] != (3, 12) or platform.machine() != "AMD64":
        parser.error("Run with the Windows x64 Python 3.12 virtual environment")
    media_args = {k: getattr(args, k) for k in ("birds", "aircraft", "birds_video", "aircraft_video")}
    for key, path in media_args.items():
        if path and not (path.is_file() if key.endswith("_video") else path.is_dir()):
            parser.error(f"Invalid input for --{key.replace('_', '-')}: {path}")
    if args.mode == "quick" and any(media_args.values()):
        parser.error("Media options require --mode full")
    run = Acceptance(args.mode)
    py = sys.executable
    probe = [py, SCRIPT, "--worker"]
    cli = [py, "-m", "birdlock.cli"]
    report_json = lambda _dir, log: json.loads(log.read_text(encoding="utf-8"))
    env = run.step("environment", [*probe, "inventory"], inspect=report_json)
    info = env.get("evidence", {})
    ffmpeg = info.get("ffmpeg")
    run.step("dependency-check", [py, "-m", "pip", "check"])
    run.step("unit-tests", [py, "-m", "unittest", "discover", "-v", "-s", WINDOWS / "tests",
                           "-p", "test_*.py"], timeout=900, inspect=unit_counts)
    run.step("devices", [*cli, "devices"])
    if ffmpeg:
        run.step("ffmpeg-version", [ffmpeg, "-version"])
    else:
        run.note("ffmpeg-version", "failed", "FFmpeg unavailable; see windows/README.md")
    run.step("selftest", [*cli, "selftest"], inspect=selftest_counts)
    run.step("offscreen-smoke", [py, APP, "--smoketest"], inspect=smoke_artifacts)
    if args.mode == "full":
        run.step("desktop-smoke", [py, APP, "--desktop-smoketest"], native=True, inspect=smoke_artifacts)
    if args.mode == "full" and ffmpeg:
        fixtures = run.step("synthetic-fixtures", [*probe, "fixtures", run.root / "synthetic", ffmpeg],
                            inspect=report_json)
        if fixtures["status"] == "passed":
            media = {k: media_args[k] or Path(v) for k, v in fixtures["evidence"].items()}
            origins = {k: "user-provided" if media_args[k] else "synthetic" for k in media}
            aircraft_model = "AircraftParts.onnx" in info.get("models", {})
            for device, name in (("cpu", "cpu-inference"), ("auto", "directml-inference")):
                if device != "cpu" and not info.get("preferred_adapter"):
                    run.note(name, "skipped", "No hardware adapter detected")
                    continue
                output = run.root / name / "profile"
                run.step(name, [*probe, "inference", device, media["birds"], media["aircraft"], output],
                         timeout=900, media={k: origins[k] for k in ("birds", "aircraft")},
                         inspect=lambda _d, _l, p=output: json.loads((p / "inference.json").read_text(encoding="utf-8")))
            synthetic_birds = origins["birds"] == "synthetic"
            run.regression("gui", "--gui-regression", [media["birds"]], "ui-regression.json", ffmpeg,
                           export=True, allow_untracked=synthetic_birds, media={"birds": origins["birds"]})
            run.regression("gui-dpi-150", "--gui-regression", [media["birds"]], "ui-regression.json", ffmpeg,
                           scale=1.5, media={"birds": origins["birds"]})
            run.regression("project", "--project-regression", [media["birds"]], "project-regression.json",
                           ffmpeg, allow_untracked=synthetic_birds, media={"birds": origins["birds"]})
            if aircraft_model:
                run.regression("subject", "--subject-regression", [media["birds"], media["aircraft"]],
                               "subject-regression.json", ffmpeg, media={k: origins[k] for k in ("birds", "aircraft")})
                run.regression("video", "--video-regression", [media["birds_video"], media["aircraft_video"]],
                               "video-regression.json", ffmpeg,
                               allow_untracked=all(origins[k] == "synthetic" for k in ("birds_video", "aircraft_video")),
                               media={k: origins[k] for k in ("birds_video", "aircraft_video")})
            else:
                for name in ("subject", "video"):
                    run.note(name, "not_run", "Aircraft model not installed; see windows/README.md")
        else:
            run.note("full-regressions", "not_run", "Synthetic fixture preparation failed")
    else:
        run.note("full-regressions", "not_run", "Quick mode" if args.mode == "quick" else "FFmpeg unavailable")
    run.report["finished"] = datetime.now().astimezone().isoformat()
    run.write()
    return int(bool(run.report["summary"]["failed"] or
                    (args.mode == "full" and run.report["summary"]["not_run"])))


if __name__ == "__main__":
    raise SystemExit(main())
