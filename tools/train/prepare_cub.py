"""Convert CUB-200-2011 (15 part keypoints) into an Ultralytics YOLO-pose dataset of bird-centred crops.

The crops mimic what the app feeds the pose model at inference time: a square around the detected bird box,
expanded by ~1.25x (randomised here for robustness), letterboxed/padded, resized to 640.

Usage: python prepare_cub.py --cub data/CUB_200_2011 --out data/cub_pose --size 640 --copies 2
"""
import argparse, random
from pathlib import Path
from PIL import Image, ImageFile

ImageFile.LOAD_TRUNCATED_IMAGES = True

PARTS = ["back", "beak", "belly", "breast", "crown", "forehead", "left_eye", "left_leg", "left_wing",
         "nape", "right_eye", "right_leg", "right_wing", "tail", "throat"]
FLIP_IDX = [0, 1, 2, 3, 4, 5, 10, 11, 12, 9, 6, 7, 8, 13, 14]


def read_table(p):
    out = {}
    for line in Path(p).read_text().splitlines():
        if line.strip():
            k, *v = line.split()
            out.setdefault(int(k), []).append(v)
    return out


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--cub", default="data/CUB_200_2011")
    ap.add_argument("--out", default="data/cub_pose")
    ap.add_argument("--size", type=int, default=640)
    ap.add_argument("--copies", type=int, default=2, help="random crops per training image")
    ap.add_argument("--seed", type=int, default=0)
    ap.add_argument("--val-limit", type=int, default=0, help="keep only N random validation images (faster validation)")
    a = ap.parse_args()
    random.seed(a.seed)
    cub = Path(a.cub)
    images = {k: v[0][0] for k, v in read_table(cub / "images.txt").items()}
    split = {k: int(v[0][0]) for k, v in read_table(cub / "train_test_split.txt").items()}
    boxes = {k: list(map(float, v[0])) for k, v in read_table(cub / "bounding_boxes.txt").items()}
    parts = read_table(cub / "parts" / "part_locs.txt")  # id -> [[part, x, y, vis], ...]
    out = Path(a.out)
    for s in ("train", "val"):
        (out / "images" / s).mkdir(parents=True, exist_ok=True)
        (out / "labels" / s).mkdir(parents=True, exist_ok=True)
    S = a.size
    n_written = 0
    missing = 0
    # image roots: the official layout (images/) or the train/val split layout of some mirrors
    roots = [cub / "images", cub.parent / "training", cub.parent / "validation", cub / "training", cub / "validation"]
    val_keep = None
    if a.val_limit:
        vids = [k for k in images if split[k] != 1]
        random.shuffle(vids)
        val_keep = set(vids[: a.val_limit])
    for iid, rel in images.items():
        is_train = split[iid] == 1
        if not is_train and val_keep is not None and iid not in val_keep:
            continue
        sub = "train" if is_train else "val"
        src = None
        for root in roots:
            if (root / rel).exists():
                src = root / rel; break
        if src is None:
            missing += 1
            continue
        try:
            img = Image.open(src).convert("RGB")
        except Exception as e:
            print("skip", src, e)
            missing += 1
            continue
        W, H = img.size
        bx, by, bw, bh = boxes[iid]
        kps = [(0.0, 0.0, 0)] * 15
        for p, x, y, v in parts.get(iid, []):
            kps[int(p) - 1] = (float(x), float(y), int(float(v)))
        copies = a.copies if is_train else 1
        for c in range(copies):
            if is_train:
                expand = random.uniform(1.12, 1.7)
                jx, jy = random.uniform(-0.12, 0.12), random.uniform(-0.12, 0.12)
            else:
                expand, jx, jy = 1.25, 0.0, 0.0
            side = max(bw, bh) * expand
            cx = bx + bw / 2 + jx * side
            cy = by + bh / 2 + jy * side
            x0, y0 = cx - side / 2, cy - side / 2
            # crop with padding (PIL handles out-of-bounds by filling); use gray 114
            rx0, ry0 = int(round(x0)), int(round(y0))
            iside = int(round(side))
            canvas = Image.new("RGB", (iside, iside), (114, 114, 114))
            ix0, iy0 = max(0, rx0), max(0, ry0)
            ix1, iy1 = min(W, rx0 + iside), min(H, ry0 + iside)
            if ix1 > ix0 and iy1 > iy0:
                canvas.paste(img.crop((ix0, iy0, ix1, iy1)), (ix0 - rx0, iy0 - ry0))
            x0, y0, side = float(rx0), float(ry0), float(iside)
            canvas = canvas.resize((S, S), Image.BICUBIC)
            k = S / side
            # bbox in crop coords (clipped)
            bx0 = max(0, (bx - x0) * k); by0 = max(0, (by - y0) * k)
            bx1 = min(S, (bx + bw - x0) * k); by1 = min(S, (by + bh - y0) * k)
            if bx1 - bx0 < 4 or by1 - by0 < 4:
                continue
            line = [0, (bx0 + bx1) / 2 / S, (by0 + by1) / 2 / S, (bx1 - bx0) / S, (by1 - by0) / S]
            for (x, y, v) in kps:
                u, w = (x - x0) * k, (y - y0) * k
                if v and 0 <= u < S and 0 <= w < S:
                    line += [u / S, w / S, 2]
                else:
                    line += [0, 0, 0]
            name = f"{iid:05d}_{c}"
            canvas.save(out / "images" / sub / f"{name}.jpg", quality=92)
            (out / "labels" / sub / f"{name}.txt").write_text(" ".join(f"{v:.6f}" if isinstance(v, float) else str(v) for v in line) + "\n")
            n_written += 1
        if iid % 1000 == 0:
            print("processed", iid, "written", n_written, flush=True)
    yaml = f"""path: {out.resolve()}
train: images/train
val: images/val
kpt_shape: [15, 3]
flip_idx: {FLIP_IDX}
names:
  0: bird
kpt_names:
  0: {PARTS}
"""
    (out / "cub_pose.yaml").write_text(yaml)
    print("done", n_written, "missing", missing, "->", out / "cub_pose.yaml")


if __name__ == "__main__":
    main()
