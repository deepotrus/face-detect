# Draw preprocessed samples with their labels, to check the data before training.
#   green box = target face, red box = ignored face, faint lines = the 8x8-pixel grid cells
# Run on the host from ml/:   python3 train/show_samples.py [train|val] [count] [seed]
# Output: data/prep/samples_<split>.png

import os
import sys

import numpy as np
from PIL import Image, ImageDraw

ML_DIR = os.path.dirname(os.path.dirname(os.path.abspath(__file__)))
split = sys.argv[1] if len(sys.argv) > 1 else "train"
count = int(sys.argv[2]) if len(sys.argv) > 2 else 24
seed = int(sys.argv[3]) if len(sys.argv) > 3 else 0

d = np.load(os.path.join(ML_DIR, "data", "prep", f"{split}.npz"))
images, boxes = d["images"], d["boxes"]
pick = np.random.default_rng(seed).choice(len(images), count, replace=False)

SCALE, COLS = 2, 6
rows = (count + COLS - 1) // COLS
sheet = Image.new("RGB", (COLS * 160 * SCALE, rows * 120 * SCALE), "black")
for k, i in enumerate(pick):
    tile = Image.fromarray(images[i]).convert("RGB").resize((160 * SCALE, 120 * SCALE), Image.NEAREST)
    dr = ImageDraw.Draw(tile)
    for gx in range(0, 160, 8):
        dr.line([(gx * SCALE, 0), (gx * SCALE, 120 * SCALE)], fill=(40, 40, 70))
    for gy in range(0, 120, 8):
        dr.line([(0, gy * SCALE), (160 * SCALE, gy * SCALE)], fill=(40, 40, 70))
    for _, x, y, w, h, ign in boxes[boxes[:, 0] == i]:
        dr.rectangle([x * SCALE, y * SCALE, (x + w) * SCALE, (y + h) * SCALE],
                     outline=(255, 60, 60) if ign else (60, 255, 60), width=2 if not ign else 1)
    sheet.paste(tile, ((k % COLS) * 160 * SCALE, (k // COLS) * 120 * SCALE))

out = os.path.join(ML_DIR, "data", "prep", f"samples_{split}.png")
sheet.save(out)
print(out)
