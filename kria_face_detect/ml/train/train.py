# Quantization-aware training of FaceNet on the preprocessed WIDER FACE data (data/prep/*.npz).
#
# Targets on the 20x15 grid (one cell = 8x8 input pixels):
#   score : 1 in the cell that contains a target face centre, 0 elsewhere
#   size  : code = (log2(face size px) - SIZE_LOG_MIN) / SIZE_LOG_SPAN, on face cells only
#   ignore: no score loss in cells whose centre lies inside a face box (target or ignored face),
#           except the target face's own centre cell
# Loss: focal loss on the score (faces are rare among cells) + smooth L1 on the size code.
# Every epoch: precision / recall / F1 on the val set at several score thresholds; the best
# F1 at threshold 0.5 is saved as best.pt.
#
# Run inside the FINN container (same torch / Brevitas as the FINN export), from ml/:
#   python train/train.py                         # full training, defaults below
#   python train/train.py --limit 2000 --epochs 1 # quick check of speed and loss
# Output: runs/<name>/{best.pt, last.pt, log.csv, args.json}

import argparse
import json
import os
import time

import numpy as np
import torch
import torch.nn.functional as F

from model import CELL, GRID_H, GRID_W, FaceNet

ML_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
SIZE_LOG_MIN = 3.5            # log2(11 px)
SIZE_LOG_SPAN = 4.0           # code 0..1 covers 11..181 px
THRESHOLDS = (0.3, 0.5, 0.7)


def size_to_code(s):
    return (np.log2(s) - SIZE_LOG_MIN) / SIZE_LOG_SPAN


def code_to_size(c):
    return 2.0 ** (c * SIZE_LOG_SPAN + SIZE_LOG_MIN)


def load(split, limit):
    d = np.load(os.path.join(ML_DIR, "data", "prep", f"{split}.npz"))
    images, boxes = d["images"], d["boxes"]
    if limit:
        images = images[:limit]
        boxes = boxes[boxes[:, 0] < limit]
    return images, boxes


def make_targets(n, boxes):
    """Grid targets for n samples: pos (bool), ign (bool), code (float), each (n, 15, 20)."""
    pos = np.zeros((n, GRID_H, GRID_W), bool)
    ign = np.zeros((n, GRID_H, GRID_W), bool)
    code = np.zeros((n, GRID_H, GRID_W), np.float32)
    best = np.zeros((n, GRID_H, GRID_W), np.float32)          # size of the face owning a pos cell
    cell_c = (np.arange(GRID_W) + 0.5) * CELL, (np.arange(GRID_H) + 0.5) * CELL
    for i, x, y, w, h, ignore in boxes:
        i = int(i)
        inside_x = (cell_c[0] >= x) & (cell_c[0] < x + w)
        inside_y = (cell_c[1] >= y) & (cell_c[1] < y + h)
        ign[i] |= inside_y[:, None] & inside_x[None, :]
        gx = min(int((x + w / 2) // CELL), GRID_W - 1)
        gy = min(int((y + h / 2) // CELL), GRID_H - 1)
        if ignore:
            ign[i, gy, gx] = True
            continue
        s = np.sqrt(w * h)
        if s > best[i, gy, gx]:                              # two faces in one cell: keep the bigger
            best[i, gy, gx] = s
            pos[i, gy, gx] = True
            code[i, gy, gx] = size_to_code(s)
    ign &= ~pos
    return pos, ign, code


def augment(x, pos, ign, code, gen):
    """x: (B,1,120,160) float 0..255. Random horizontal flip + brightness/contrast, integer pixels."""
    b = x.shape[0]
    flip = torch.rand(b, generator=gen) < 0.5
    x[flip] = x[flip].flip(-1)
    pos[flip], ign[flip], code[flip] = pos[flip].flip(-1), ign[flip].flip(-1), code[flip].flip(-1)
    a = torch.empty(b, 1, 1, 1).uniform_(0.6, 1.4, generator=gen)
    o = torch.empty(b, 1, 1, 1).uniform_(-40, 40, generator=gen)
    x = torch.clamp(torch.round(a * (x - 128) + 128 + o), 0, 255)
    return x, pos, ign, code


def loss_fn(out, pos, ign, code, alpha=0.25, gamma=2.0):
    logit, pred_code = out[:, 0], out[:, 1]
    t = pos.float()
    p = torch.sigmoid(logit)
    ce = F.binary_cross_entropy_with_logits(logit, t, reduction="none")
    p_t = p * t + (1 - p) * (1 - t)
    a_t = alpha * t + (1 - alpha) * (1 - t)
    focal = a_t * (1 - p_t) ** gamma * ce
    npos = max(int(pos.sum()), 1)
    l_score = (focal * (~ign).float()).sum() / npos
    l_size = F.smooth_l1_loss(pred_code[pos], code[pos], reduction="sum") / npos
    return l_score + l_size, l_score.item(), l_size.item()


@torch.no_grad()
def evaluate(model, images, boxes, batch, device):
    """Precision / recall per score threshold. A detection = local maximum of the score map
    (3x3 cells) above the threshold; it is correct if its centre lies inside a not yet matched
    target face and its size is within 2x of the face size. Detections on ignored faces count
    neither way."""
    model.eval()
    scores, codes = [], []
    for k in range(0, len(images), batch):
        x = torch.from_numpy(images[k:k + batch]).float().unsqueeze(1).to(device)
        out = model(x)
        s = torch.sigmoid(out[:, 0])
        peak = s == F.max_pool2d(s.unsqueeze(1), 3, 1, 1).squeeze(1)
        scores.append((s * peak).cpu().numpy())
        codes.append(out[:, 1].cpu().numpy())
    scores, codes = np.concatenate(scores), np.concatenate(codes)

    order = np.argsort(boxes[:, 0], kind="stable")
    per_sample = np.split(boxes[order], np.searchsorted(boxes[order, 0], np.arange(1, len(images))))
    n_targets = int((boxes[:, 5] == 0).sum())
    res = {}
    for thr in THRESHOLDS:
        tp = fp = 0
        for i, bx in enumerate(per_sample):
            gy, gx = np.nonzero(scores[i] > thr)
            if len(gy) == 0:
                continue
            det = sorted(zip(scores[i][gy, gx], (gx + 0.5) * CELL, (gy + 0.5) * CELL,
                             code_to_size(codes[i][gy, gx])), reverse=True)
            used = np.zeros(len(bx), bool)
            for _, cx, cy, ds in det:
                inside = (cx >= bx[:, 1]) & (cx < bx[:, 1] + bx[:, 3]) & (cy >= bx[:, 2]) & (cy < bx[:, 2] + bx[:, 4])
                ratio = ds / np.sqrt(bx[:, 3] * bx[:, 4])
                match = np.nonzero(inside & (bx[:, 5] == 0) & ~used & (ratio > 0.5) & (ratio < 2.0))[0]
                if len(match):
                    used[match[0]] = True
                    tp += 1
                elif not np.any(inside & (bx[:, 5] == 1)):
                    fp += 1
        p = tp / max(tp + fp, 1)
        r = tp / max(n_targets, 1)
        res[thr] = (p, r, 2 * p * r / max(p + r, 1e-9))
    model.train()
    return res


def main():
    ap = argparse.ArgumentParser()
    ap.add_argument("--epochs", type=int, default=40)
    ap.add_argument("--batch", type=int, default=64)
    ap.add_argument("--lr", type=float, default=1e-3)
    ap.add_argument("--wd", type=float, default=1e-4, help="L2 regularization (Adam weight_decay)")
    ap.add_argument("--limit", type=int, default=0, help="use only the first N samples (quick tests)")
    ap.add_argument("--threads", type=int, default=os.cpu_count())
    ap.add_argument("--device", default="cuda" if torch.cuda.is_available() else "cpu",
                    help="cuda (default when a GPU is visible in the container) or cpu")
    ap.add_argument("--name", default=time.strftime("%Y%m%d_%H%M%S"))
    args = ap.parse_args()

    torch.set_num_threads(args.threads)
    gen = torch.Generator().manual_seed(0)
    torch.manual_seed(0)
    out_dir = os.path.join(ML_DIR, "runs", args.name)
    os.makedirs(out_dir, exist_ok=True)
    json.dump(vars(args), open(os.path.join(out_dir, "args.json"), "w"), indent=1)

    tr_img, tr_box = load("train", args.limit)
    va_img, va_box = load("val", args.limit // 4 if args.limit else 0)
    pos, ign, code = (torch.from_numpy(a) for a in make_targets(len(tr_img), tr_box))
    tr_x = torch.from_numpy(tr_img).unsqueeze(1)                       # uint8, converted per batch
    device = torch.device(args.device)
    where = torch.cuda.get_device_name(device) if device.type == "cuda" else f"cpu, {args.threads} threads"
    print(f"train {len(tr_img)} samples ({int(pos.sum())} face cells), val {len(va_img)} samples, "
          f"{where} -> {out_dir}")

    model = FaceNet().to(device)
    opt = torch.optim.Adam(model.parameters(), lr=args.lr, weight_decay=args.wd)
    steps = args.epochs * ((len(tr_img) + args.batch - 1) // args.batch)
    sched = torch.optim.lr_scheduler.OneCycleLR(opt, max_lr=args.lr, total_steps=steps, pct_start=0.1)

    log = open(os.path.join(out_dir, "log.csv"), "w")
    log.write("epoch,loss,l_score,l_size," + ",".join(f"p{t},r{t},f1{t}" for t in THRESHOLDS) + ",sec\n")
    best_f1 = -1.0
    for epoch in range(1, args.epochs + 1):
        t0 = time.time()
        perm = torch.randperm(len(tr_img), generator=gen)
        tot = ls = lz = 0.0
        nb = 0
        for k in range(0, len(perm), args.batch):
            idx = perm[k:k + args.batch]
            x, bp, bi, bc = augment(tr_x[idx].float(), pos[idx].clone(), ign[idx].clone(), code[idx].clone(), gen)
            x, bp, bi, bc = x.to(device), bp.to(device), bi.to(device), bc.to(device)
            loss, l_s, l_z = loss_fn(model(x), bp, bi, bc)
            opt.zero_grad()
            loss.backward()
            opt.step()
            sched.step()
            tot, ls, lz, nb = tot + loss.item(), ls + l_s, lz + l_z, nb + 1
            if nb % 50 == 0:
                rate = nb * args.batch / (time.time() - t0)
                print(f"  epoch {epoch} batch {nb}: loss {tot / nb:.4f}  ({rate:.0f} samples/s)", flush=True)
        train_sec = time.time() - t0
        res = evaluate(model, va_img, va_box, 256, device)
        sec = time.time() - t0
        print(f"epoch {epoch}/{args.epochs}: loss {tot / nb:.4f} (score {ls / nb:.4f}, size {lz / nb:.4f})  "
              + "  ".join(f"thr {t}: P {p:.3f} R {r:.3f} F1 {f:.3f}" for t, (p, r, f) in res.items())
              + f"  [{train_sec:.0f}s train, {sec - train_sec:.0f}s val]", flush=True)
        log.write(f"{epoch},{tot / nb:.5f},{ls / nb:.5f},{lz / nb:.5f},"
                  + ",".join(f"{p:.4f},{r:.4f},{f:.4f}" for p, r, f in res.values()) + f",{sec:.0f}\n")
        log.flush()
        torch.save(model.state_dict(), os.path.join(out_dir, "last.pt"))
        if res[0.5][2] > best_f1:
            best_f1 = res[0.5][2]
            torch.save(model.state_dict(), os.path.join(out_dir, "best.pt"))
            print(f"  new best F1@0.5 = {best_f1:.3f} -> best.pt", flush=True)


if __name__ == "__main__":
    main()
