"""Export the YOLO models to ONNX (raw output, no NMS) for the Windows version.

Usage (from tools/train, inside .venv):
  python export_onnx.py --detector weights/yolo11m.pt --det-imgsz 1024 --pose weights/eye_pose_v0.pt --pose-imgsz 640
Writes ../../windows/models/BirdDetector.onnx, BirdPose.onnx (+ BirdPose.json keypoint schema).
"""
import argparse, json, shutil
from pathlib import Path

from ultralytics import YOLO

ROOT = Path(__file__).resolve().parents[2]
OUT = ROOT / "windows" / "models"


def export(weights: str, imgsz: int, name: str):
    m = YOLO(weights)
    path = Path(m.export(format="onnx", imgsz=imgsz, nms=False, simplify=True, dynamic=False, opset=17))
    OUT.mkdir(parents=True, exist_ok=True)
    dst = OUT / f"{name}.onnx"
    shutil.copy(path, dst)
    print("->", dst, dst.stat().st_size // 1024, "KB")
    return m


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--detector", required=True)
    ap.add_argument("--det-imgsz", type=int, default=1024)
    ap.add_argument("--pose", required=True)
    ap.add_argument("--pose-imgsz", type=int, default=640)
    a = ap.parse_args()
    export(a.detector, a.det_imgsz, "BirdDetector")
    export(a.pose, a.pose_imgsz, "BirdPose")
    # same keypoint schema as the macOS app
    shutil.copy(ROOT / "Models" / "BirdPose.json", OUT / "BirdPose.json")


if __name__ == "__main__":
    main()
