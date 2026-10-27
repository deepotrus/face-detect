# Evaluate a trained FaceNet run.
#
# 1. WIDER val: precision and recall per score threshold, with recall split by face size,
#    and a sheet of val samples with ground truth and detections drawn.
# 2. Optionally webcam frames captured on the Kria (raw YUYV 640x480, *.yuyv): processed
#    exactly like the hardware will (Y bytes, 4x4 average with rounding = downscale4x), run
#    through the model, detections drawn on a sheet. No ground truth: judge by eye.
#
# Drawing: green = target face, red = ignored face (val only), yellow = detection (+ score).
# A detection = local maximum (3x3 cells) of the score map above the threshold; box centred
# on its cell, size from the size code.
#
# Run inside the FINN container, from ml/:
#   python train/eval.py --run v1
#   python train/eval.py --run v1 --webcam data/webcam/v1 --thr 0.5
# Output: runs/<run>/eval_val.txt, eval_val.png, eval_webcam.png

import argparse
import glob
import os

import numpy as np
import torch
import torch.nn.functional as F
from PIL import Image, ImageDraw

from model import CELL, FaceNet
from train import ML_DIR, THRESHOLDS, code_to_size, load

SIZE_BINS = ((12, 20), (20, 40), (40, 80), (80, 1000))


@torch.no_grad()
def predict(model, images, device, batch=256):
    """images: (N,120,160) uint8 -> peak score maps (N,15,20) and size codes (N,15,20)."""
    scores, codes = [], []
    for k in range(0, len(images), batch):
        out = model(torch.from_numpy(images[k:k + batch]).float().unsqueeze(1).to(device))
        s = torch.sigmoid(out[:, 0])
        peak = s == F.max_pool2d(s.unsqueeze(1), 3, 1, 1).squeeze(1)
        scores.append((s * peak).cpu().numpy())
        codes.append(out[:, 1].cpu().numpy())
    return np.concatenate(scores), np.concatenate(codes)


def detections(score, code, thr):
    gy, gx = np.nonzero(score > thr)
    return sorted(zip(score[gy, gx], (gx + 0.5) * CELL, (gy + 0.5) * CELL, code_to_size(code[gy, gx])),
                  reverse=True)


def match(dets, bx):
    """Greedy matching, same rule as training: centre inside an unmatched target face, size
    within 2x. Returns (tp, fp, matched flag per box)."""
    used = np.zeros(len(bx), bool)
    tp = fp = 0
    for _, cx, cy, ds in dets:
        inside = (cx >= bx[:, 1]) & (cx < bx[:, 1] + bx[:, 3]) & (cy >= bx[:, 2]) & (cy < bx[:, 2] + bx[:, 4])
        ratio = ds / np.sqrt(bx[:, 3] * bx[:, 4])
        m = np.nonzero(inside & (bx[:, 5] == 0) & ~used & (ratio > 0.5) & (ratio < 2.0))[0]
        if len(m):
            used[m[0]] = True
            tp += 1
        elif not np.any(inside & (bx[:, 5] == 1)):
            fp += 1
    return tp, fp, used


def draw_sheet(images, picks, dets_of, boxes_of, path, cols=6, scale=2):
    rows = (len(picks) + cols - 1) // cols
    sheet = Image.new("RGB", (cols * 160 * scale, rows * 120 * scale), "black")
    for k, i in enumerate(picks):
        tile = Image.fromarray(images[i]).convert("RGB").resize((160 * scale, 120 * scale), Image.NEAREST)
        dr = ImageDraw.Draw(tile)
        for _, x, y, w, h, ign in boxes_of(i):
            dr.rectangle([x * scale, y * scale, (x + w) * scale, (y + h) * scale],
                         outline=(255, 60, 60) if ign else (60, 255, 60), width=1 if ign else 2)
        for s, cx, cy, ds in dets_of(i):
            h = ds / 2
            dr.rectangle([(cx - h) * scale, (cy - h) * scale, (cx + h) * scale, (cy + h) * scale],
                         outline=(255, 230, 0), width=2)
            dr.text(((cx - h) * scale + 2, (cy - h) * scale + 1), f"{s:.2f}", fill=(255, 230, 0))
        sheet.paste(tile, ((k % cols) * 160 * scale, (k // cols) * 120 * scale))
    sheet.save(path)


def eval_val(model, device, run_dir, thr_draw, count):
    images, boxes = load("val", 0)
    scores, codes = predict(model, images, device)
    order = np.argsort(boxes[:, 0], kind="stable")
    per = np.split(boxes[order], np.searchsorted(boxes[order, 0], np.arange(1, len(images))))
    tsize = [np.sqrt(b[:, 3] * b[:, 4]) for b in per]

    lines = [f"WIDER val: {len(images)} samples, {int((boxes[:, 5] == 0).sum())} target faces"]
    header = "thr   precision  recall   F1    | recall by face size: " + "  ".join(
        f"{lo}-{hi if hi < 1000 else ''}px" for lo, hi in SIZE_BINS)
    lines.append(header)
    for thr in THRESHOLDS:
        tp = fp = 0
        hit = np.zeros(len(SIZE_BINS))
        tot = np.zeros(len(SIZE_BINS))
        for i, bx in enumerate(per):
            t, f, used = match(detections(scores[i], codes[i], thr), bx)
            tp, fp = tp + t, fp + f
            for j, (lo, hi) in enumerate(SIZE_BINS):
                sel = (bx[:, 5] == 0) & (tsize[i] >= lo) & (tsize[i] < hi)
                tot[j] += sel.sum()
                hit[j] += (sel & used).sum()
        p = tp / max(tp + fp, 1)
        r = tp / max(int((boxes[:, 5] == 0).sum()), 1)
        f1 = 2 * p * r / max(p + r, 1e-9)
        bins = "  ".join(f"{h / max(n, 1):.2f} ({int(n)})" for h, n in zip(hit, tot))
        lines.append(f"{thr:<5} {p:9.3f} {r:7.3f} {f1:6.3f}  | {bins}")
    text = "\n".join(lines)
    print(text)
    open(os.path.join(run_dir, "eval_val.txt"), "w").write(text + "\n")

    picks = np.random.default_rng(0).choice(len(images), count, replace=False)
    path = os.path.join(run_dir, "eval_val.png")
    draw_sheet(images, picks, lambda i: detections(scores[i], codes[i], thr_draw), lambda i: per[i], path)
    print(f"sheet (thr {thr_draw}): {path}")


def downscale4x(yuyv):
    """Hardware model: Y bytes of a 640x480 YUYV frame -> 160x120, 4x4 average, (sum + 8) >> 4."""
    y = yuyv[0::2].reshape(480, 640).astype(np.uint32)
    return ((y.reshape(120, 4, 160, 4).sum(axis=(1, 3)) + 8) >> 4).astype(np.uint8)


def eval_webcam(model, device, run_dir, folder, thr):
    files = sorted(glob.glob(os.path.join(ML_DIR, folder, "*.yuyv")))
    if not files:
        print(f"no *.yuyv files in {folder}")
        return
    images = np.stack([downscale4x(np.fromfile(f, dtype=np.uint8)[-640 * 480 * 2:]) for f in files])
    scores, codes = predict(model, images, device)
    n_det = [len(detections(scores[i], codes[i], thr)) for i in range(len(images))]
    print(f"webcam: {len(files)} frames, detections at thr {thr}: " + " ".join(map(str, n_det)))
    path = os.path.join(run_dir, "eval_webcam.png")
    draw_sheet(images, range(len(images)), lambda i: detections(scores[i], codes[i], thr), lambda i: [], path)
    print(f"sheet: {path}")


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--run", required=True, help="folder name under runs/")
    ap.add_argument("--ckpt", default="best.pt")
    ap.add_argument("--thr", type=float, default=0.5, help="score threshold for the drawings")
    ap.add_argument("--count", type=int, default=24, help="val samples on the sheet")
    ap.add_argument("--webcam", default="", help="folder (relative to ml/) with *.yuyv frames")
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu")
    args = ap.parse_args()

    device = torch.device(args.device)
    run_dir = os.path.join(ML_DIR, "runs", args.run)
    model = FaceNet().to(device)
    model.load_state_dict(torch.load(os.path.join(run_dir, args.ckpt), map_location=device))
    model.eval()

    eval_val(model, device, run_dir, args.thr, args.count)
    if args.webcam:
        eval_webcam(model, device, run_dir, args.webcam, args.thr)


if __name__ == "__main__":
    main()
