"""Evaluate head keypoint accuracy on the CUB validation crops.

Reports, per model, the eye / beak / crown error normalised by the bird box diagonal and PCK@0.05.
For models with other schemas, keypoints are matched by name.

Usage: python eval_pose.py --data data/cub_pose --model a.pt:names_csv --model b.pt
"""
import argparse, math
from pathlib import Path
import numpy as np
from ultralytics import YOLO

CUB = ["back", "beak", "belly", "breast", "crown", "forehead", "left_eye", "left_leg", "left_wing",
       "nape", "right_eye", "right_leg", "right_wing", "tail", "throat"]


def load_gt(lbl):
    v = list(map(float, lbl.read_text().split()))
    box = v[1:5]
    k = np.array(v[5:]).reshape(-1, 3)
    return box, k


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--data", default="data/cub_pose")
    ap.add_argument("--model", action="append", required=True)
    ap.add_argument("--limit", type=int, default=1500)
    a = ap.parse_args()
    imgs = sorted((Path(a.data) / "images" / "val").glob("*.jpg"))[: a.limit]
    for spec in a.model:
        path, *names = spec.split(":")
        names = names[0].split(",") if names else CUB
        m = YOLO(path)
        errs = {"eye": [], "beak": [], "crown": []}
        for p in imgs:
            box, gt = load_gt(Path(a.data) / "labels" / "val" / (p.stem + ".txt"))
            diag = math.hypot(box[2], box[3]) * 640
            r = m.predict(str(p), imgsz=640, verbose=False, conf=0.1)[0]
            if r.keypoints is None or len(r.keypoints) == 0:
                for k in errs: errs[k].append(np.inf)
                continue
            kp = r.keypoints.data[0].cpu().numpy()  # (K,3)
            pred = {n: kp[i] for i, n in enumerate(names)}
            pred.setdefault("crown", pred.get("head_top"))

            def g(n):
                i = CUB.index(n)
                return gt[i] if gt[i][2] > 0 else None

            # eye: gt visible eye(s); prediction = more confident eye
            ge = [e for e in (g("left_eye"), g("right_eye")) if e is not None]
            pe = max([pred[n] for n in ("left_eye", "right_eye") if n in pred], key=lambda x: x[2])
            if ge:
                d = min(math.hypot((pe[0] / 640 - e[0]), (pe[1] / 640 - e[1])) for e in ge) * 640 / diag
                errs["eye"].append(d)
            for n in ("beak", "crown"):
                e = g(n)
                if e is not None and pred.get(n) is not None:
                    q = pred[n]
                    errs[n].append(math.hypot(q[0] / 640 - e[0], q[1] / 640 - e[1]) * 640 / diag)
        print(f"== {path}")
        for k, v in errs.items():
            v = np.array(v)
            if len(v) == 0: continue
            fin = v[np.isfinite(v)]
            print(f"  {k:6s} n={len(v)}  median {np.median(fin):.4f}  mean {fin.mean():.4f}  PCK@0.03 {np.mean(v < 0.03):.3f}  PCK@0.05 {np.mean(v < 0.05):.3f}")


if __name__ == "__main__":
    main()
