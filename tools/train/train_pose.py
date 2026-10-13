"""Train the bird keypoint model on the CUB crops (Apple GPU via MPS).

Usage: python train_pose.py --model weights/yolo11s-pose.pt --epochs 60
"""
import argparse
from ultralytics import YOLO


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data/cub_pose/cub_pose.yaml")
    ap.add_argument("--model", default="weights/yolo11s-pose.pt")
    ap.add_argument("--epochs", type=int, default=60)
    ap.add_argument("--batch", type=int, default=32)
    ap.add_argument("--imgsz", type=int, default=640)
    ap.add_argument("--name", default="cub15")
    ap.add_argument("--device", default="mps")
    ap.add_argument("--workers", type=int, default=8)
    a = ap.parse_args()
    m = YOLO(a.model)
    m.train(data=a.data, epochs=a.epochs, imgsz=a.imgsz, batch=a.batch, device=a.device, workers=a.workers,
            project="runs", name=a.name, exist_ok=True,
            degrees=30, translate=0.08, scale=0.35, fliplr=0.5, mosaic=0.5, close_mosaic=12,
            hsv_h=0.015, hsv_s=0.6, hsv_v=0.4, pose=14.0, kobj=1.0,
            patience=25, cos_lr=True, plots=True, amp=False, cache=False)


if __name__ == "__main__":
    main()
