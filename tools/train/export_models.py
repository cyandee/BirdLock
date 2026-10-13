"""Export YOLO models to Core ML (no NMS, raw output) and compile them into ../../Models.

Usage:
  python export_models.py --detector weights/yolo11m.pt --det-imgsz 1024 \
                          --pose weights/eye_pose_v0.pt --pose-imgsz 640 \
                          --pose-names beak,left_eye,right_eye,head_top,left_shoulder,right_shoulder
"""
import argparse, json, os, shutil, subprocess, sys
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[2]
MODELS = ROOT / "Models"


def export(weights: str, imgsz: int, name: str, half: bool):
    m = YOLO(weights)
    out = m.export(format="coreml", imgsz=imgsz, nms=False, half=half)
    pkg = Path(out)
    print("exported", pkg)
    MODELS.mkdir(exist_ok=True)
    tmp = MODELS / "_compile"
    shutil.rmtree(tmp, ignore_errors=True)
    tmp.mkdir()
    env = dict(os.environ, DEVELOPER_DIR=os.environ.get("DEVELOPER_DIR", "/Applications/Xcode.app/Contents/Developer"))
    subprocess.check_call(["xcrun", "coremlcompiler", "compile", str(pkg), str(tmp)], env=env)
    compiled = next(tmp.glob("*.mlmodelc"))
    dst = MODELS / f"{name}.mlmodelc"
    shutil.rmtree(dst, ignore_errors=True)
    shutil.move(str(compiled), dst)
    shutil.rmtree(tmp, ignore_errors=True)
    # keep the package too (useful for inspection in Xcode)
    dpkg = MODELS / f"{name}.mlpackage"
    shutil.rmtree(dpkg, ignore_errors=True)
    shutil.copytree(pkg, dpkg)
    print("compiled ->", dst)
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detector")
    ap.add_argument("--det-imgsz", type=int, default=1024)
    ap.add_argument("--pose")
    ap.add_argument("--pose-imgsz", type=int, default=640)
    ap.add_argument("--pose-names", default="")
    ap.add_argument("--half", action="store_true")
    a = ap.parse_args()
    if a.detector:
        export(a.detector, a.det_imgsz, "BirdDetector", a.half)
    if a.pose:
        m = export(a.pose, a.pose_imgsz, "BirdPose", a.half)
        names = [s for s in a.pose_names.split(",") if s]
        nk = m.model.yaml.get("kpt_shape", [len(names), 3])[0] if hasattr(m, "model") else len(names)
        if not names:
            names = [f"kp{i}" for i in range(nk)]
        assert len(names) == nk, f"{len(names)} names but model has {nk} keypoints"
        (MODELS / "BirdPose.json").write_text(json.dumps({"keypoints": names, "inputCropExpand": 1.25}, indent=2))
        print("schema:", names)


if __name__ == "__main__":
    main()
