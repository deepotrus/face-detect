# WIDER FACE -> 160x120 gray samples that look like the hardware input.
#
# For every WIDER image:
#   - convert to gray with the BT.601 luma formula (the Y of the webcam's YUYV)
#   - one "full" sample: centre crop to 4:3, area-downscale to 160x120 (like downscale4x)
#   - up to ZOOM_PER_IMAGE "zoom" samples: a 4:3 crop around one face, sized so that the face
#     comes out FACE_MIN_OUT..FACE_MAX_OUT px tall at 160x120 (webcam-like close faces)
# Faces keep their box in 160x120 coordinates. A face is marked "ignore" (no reward, no
# penalty in training) when it is smaller than IGNORE_BELOW px, flagged invalid by WIDER,
# or cut by the crop border.
#
# Output: data/prep/{train,val}.npz with
#   images : (N, 120, 160) uint8
#   boxes  : (M, 6) float32  [sample index, x, y, w, h, ignore]   (x, y = top-left, px)
#
# Run on the host (numpy + PIL only), from ml/:   python3 train/prep_wider.py

import os
import sys
from multiprocessing import Pool

import numpy as np
from PIL import Image

ML_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
WIDER = os.path.join(ML_DIR, "data", "wider_face")
OUT_DIR = os.path.join(ML_DIR, "data", "prep")

OUT_W, OUT_H = 160, 120
IGNORE_BELOW = 12.0                  # px at 160x120: smaller faces are "ignore"
ZOOM_PER_IMAGE = 2
ZOOM_SRC_MIN = 20.0                  # only zoom on faces at least this big in the original image
FACE_MIN_OUT, FACE_MAX_OUT = 20.0, 70.0
SEED = 1234


def parse_gt(path):
    """WIDER txt: file name, face count, then one line per face (x y w h + 6 attributes).
    Images with 0 faces still have one all-zero line."""
    entries = []
    with open(path) as f:
        lines = [l.strip() for l in f]
    i = 0
    while i < len(lines):
        name = lines[i]
        n = int(lines[i + 1])
        rows = lines[i + 2:i + 2 + max(n, 1)]
        faces = []
        for r in rows[:n]:
            v = [int(t) for t in r.split()]
            x, y, w, h, invalid = v[0], v[1], v[2], v[3], v[7]
            if w > 0 and h > 0:
                faces.append((x, y, w, h, invalid))
        entries.append((name, faces))
        i += 2 + max(n, 1)
    return entries


def to_gray(rgb):
    a = np.asarray(rgb, dtype=np.float32)
    y = 0.299 * a[..., 0] + 0.587 * a[..., 1] + 0.114 * a[..., 2]
    return Image.fromarray(np.clip(np.rint(y), 0, 255).astype(np.uint8))


def crop_sample(gray, faces, cx0, cy0, cw, ch):
    """Crop (cx0, cy0, cw, ch) from the gray image, downscale to 160x120, map the faces."""
    img = gray.resize((OUT_W, OUT_H), Image.BOX, box=(cx0, cy0, cx0 + cw, cy0 + ch))
    s = OUT_W / cw
    boxes = []
    for x, y, w, h, invalid in faces:
        fcx, fcy = x + w / 2, y + h / 2
        if not (cx0 <= fcx < cx0 + cw and cy0 <= fcy < cy0 + ch):
            continue                                            # centre outside: not in this sample
        cut = x < cx0 or y < cy0 or x + w > cx0 + cw or y + h > cy0 + ch
        bx, by, bw, bh = (x - cx0) * s, (y - cy0) * s, w * s, h * s
        ignore = invalid == 1 or cut or np.sqrt(bw * bh) < IGNORE_BELOW
        boxes.append((bx, by, bw, bh, float(ignore)))
    return np.asarray(img, dtype=np.uint8), boxes


def process(args):
    idx, name, faces, split = args
    rng = np.random.default_rng(SEED + idx)
    path = os.path.join(WIDER, f"WIDER_{split}", "images", name)
    gray = to_gray(Image.open(path).convert("RGB"))
    W, H = gray.size
    samples = []

    # full image, centre crop to 4:3
    cw, ch = (H * 4 / 3, H) if W / H > 4 / 3 else (W, W * 3 / 4)
    samples.append(crop_sample(gray, faces, (W - cw) / 2, (H - ch) / 2, cw, ch))

    # zoom crops around single faces
    big = [f for f in faces if f[4] == 0 and np.sqrt(f[2] * f[3]) >= ZOOM_SRC_MIN]
    for k in rng.permutation(len(big))[:ZOOM_PER_IMAGE]:
        x, y, w, h, _ = big[k]
        size = np.sqrt(w * h)
        if size < FACE_MIN_OUT:
            continue
        target = rng.uniform(FACE_MIN_OUT, min(FACE_MAX_OUT, size))   # never upscale: crop >= 160 px wide
        cw = min(OUT_W * size / target, W, H * 4 / 3)          # crop no larger than the image
        ch = cw * 3 / 4
        fcx = x + w / 2 + rng.uniform(-0.3, 0.3) * cw          # face somewhere in the middle 60%
        fcy = y + h / 2 + rng.uniform(-0.3, 0.3) * ch
        cx0 = float(np.clip(fcx - cw / 2, 0, W - cw))
        cy0 = float(np.clip(fcy - ch / 2, 0, H - ch))
        samples.append(crop_sample(gray, faces, cx0, cy0, cw, ch))
    return samples


def build(split):
    entries = parse_gt(os.path.join(WIDER, "wider_face_split", f"wider_face_{split}_bbx_gt.txt"))
    jobs = [(i, n, f, split) for i, (n, f) in enumerate(entries)]
    with Pool() as pool:
        results = pool.map(process, jobs, chunksize=16)
    images, boxes = [], []
    for samples in results:
        for img, bx in samples:
            for b in bx:
                boxes.append((len(images),) + b)
            images.append(img)
    images = np.stack(images)
    boxes = np.asarray(boxes, dtype=np.float32).reshape(-1, 6)
    os.makedirs(OUT_DIR, exist_ok=True)
    np.savez_compressed(os.path.join(OUT_DIR, f"{split}.npz"), images=images, boxes=boxes)
    targets = boxes[boxes[:, 5] == 0]
    sizes = np.sqrt(targets[:, 3] * targets[:, 4])
    print(f"{split}: {len(entries)} WIDER images -> {len(images)} samples, "
          f"{len(targets)} target faces, {int((boxes[:, 5] == 1).sum())} ignored, "
          f"samples without target face: {len(images) - len(np.unique(targets[:, 0]))}, "
          f"target face size px: min {sizes.min():.0f} median {np.median(sizes):.0f} max {sizes.max():.0f}")


if __name__ == "__main__":
    for split in sys.argv[1:] or ["train", "val"]:
        build(split)
