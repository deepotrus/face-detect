# ml: FaceNet, from dataset to FINN IP

Everything on the PC that turns a public face dataset into the FINN IP used by `fw/hdl/fpga_top_nn.vhd`. FINN/Docker setup: [docs/setup_finn.md](../../docs/setup_finn.md).

The trained weights are versioned (`runs/v1/best.pt`, plus `finn_v1/facenet_v1.onnx` and `finn_v1/hw_meta.json`), so **to rebuild the hardware you only need step 4 below**. Steps 1-3 reproduce the training.

## The network (`train/model.py`, the source of truth)

| | |
|---|---|
| input | 1 × 120 × 160 gray, UINT8 (the output of `downscale4x`) |
| layers | 6 × (conv 3×3 + BatchNorm + ReLU), channels 8-16-32-32-32-32, 2×2 max-pool after the first three; 1×1 conv head; receptive field 70 px |
| quantization | 4-bit weights and activations (Brevitas), 8-bit output |
| output | 20 × 15 grid (one cell = 8 × 8 input pixels) × [face score logit, size code], INT8 |
| decoding | score = sigmoid(int8 × out_scale); face size px = 2^(code × 4 + 3.5) with code = int8 × out_scale; box centred on the cell |
| size | 33.5 k weights, 20.8 M MAC per frame |

## 1. Data (host Python: numpy + Pillow)

```sh
cd kria_face_detect/ml
mkdir -p data/wider_face && cd data/wider_face
for f in WIDER_train.zip WIDER_val.zip wider_face_split.zip; do
  wget https://huggingface.co/datasets/CUHK-CSE/wider_face/resolve/main/data/$f
done
for f in *.zip; do unzip -q $f; done
cd ../..
python3 train/prep_wider.py                      # -> data/prep/train.npz, val.npz (~1 min)
python3 train/show_samples.py train 24 0         # -> data/prep/samples_train.png
```

`prep_wider.py` makes WIDER look like the hardware input: gray with the BT.601 luma (the Y of YUYV), 4:3 crop, area downscale to 160×120 (like `downscale4x`), plus "zoom" crops around single faces (20-70 px, never upscaled) to get webcam-like close faces. Faces under 12 px, cut by the crop or flagged invalid are "ignore" (no reward, no penalty). Result: train 33 080 samples / 42 873 target faces, val 8 275 / 10 906. WIDER's test split has no labels and is not needed.

## 2. Train (FINN container, GPU)

```sh
tmux new -s train
cd ~/finn
ML=$REPO/kria_face_detect/ml                     # REPO = this repository
FINN_DOCKER_EXTRA="$FINN_DOCKER_EXTRA -v $ML:$ML -w $ML" ./run-docker.sh
# inside the container:
python train/train.py --epochs 40 --name v1
```

Quantization-aware from the start (what is trained is exactly what FINN builds). Focal loss on the score, smooth L1 on the size code, flips and brightness/contrast augmentation, Adam with L2 1e-4, one-cycle schedule. About 25 min on an NVIDIA T1000 (≈1 000 samples/s; ≈32 samples/s on 24 CPU threads, `--device cpu`). Output in `runs/<name>/`: `best.pt` (best F1 at threshold 0.5 on val), `last.pt`, `log.csv`, `args.json`.

## 3. Evaluate

```sh
python train/eval.py --run v1                            # inside the container, from ml/
python train/eval.py --run v1 --webcam data/webcam/v1    # optional: your own frames (*.yuyv)
```

Writes `runs/v1/eval_val.txt` and `eval_val.png` (detections drawn on val samples). With `--webcam`, frames captured on the board ([docs/setup_board.md](../../docs/setup_board.md#capturing-raw-frames)) are downscaled exactly like the hardware and drawn in `eval_webcam.png`.

FaceNet v1 on WIDER val (`runs/v1/eval_val.txt`):

| threshold | precision | recall | F1 | recall 12-20 px | 20-40 px | 40-80 px | > 80 px |
|---|---|---|---|---|---|---|---|
| 0.3 | 0.714 | 0.790 | 0.750 | 0.63 | 0.84 | 0.88 | 0.58 |
| 0.5 | 0.909 | 0.677 | 0.776 | 0.47 | 0.73 | 0.81 | 0.50 |
| 0.7 | 0.958 | 0.546 | 0.695 | 0.31 | 0.60 | 0.72 | 0.41 |

On 60 webcam frames (one person, 0.4-2 m): no false detection on ~17 empty frames, ~33 of ~37 visible faces found. Known weaknesses: very close faces (> 80 px at 160×120, rare in training: boxes too small or missed), glasses with a window behind, strongly tilted heads; duplicate boxes on one face (removed by the overlap suppression in the board notebook).

## 4. FINN build of the trained network → IP

```sh
cd ~/finn
./run-docker.sh build_custom $REPO/kria_face_detect/ml finn_v1/build      # about 1 hour
```

`finn_v1/build.py` loads `runs/v1/best.pt`, exports QONNX (`facenet_v1.onnx`, input annotated UINT8), writes `hw_meta.json` (output scale and layout for the notebook) and verification data (2 seeded random images and the PyTorch output for them: `input.npy`, `expected_output.npy`), then builds the stitched IP into `finn_v1/output_facenet_v1/stitched_ip/ip` with `target_fps=150`, `auto_fifo_depths=False`, `stitched_ip_gen_dcp=True`. `verification_output/` must contain `verify_stitched_ip_rtlsim_0/1_SUCCESS.npy`.

| FaceNet v1 IP (out-of-context, 2026-10-16) | |
|---|---|
| resources | 14 316 LUT, 15 646 FF, 3 BRAM36 + 4 BRAM18, **0 DSP** |
| timing | WNS +3.21 ns at 100 MHz (fmax ≈ 147 MHz) |
| one frame (RTL simulation) | 1.54 M cycles = **15.4 ms**; estimated throughput 163 fps |
| interface | `s_axis_0` 8 bit, 19 200 beats/frame in; `m_axis_0` 8 bit, 600 beats/frame out (NHWC: per cell score, size) |

## Sizing build (`size_net/build.py`)

Before training, the same architecture with random weights was built with FINN to measure resources and speed (they depend on layer sizes and bit widths, not on weight values): 12.6 k LUT, 7.5 BRAM, 0 DSP, WNS +4.4 ns, 35.6 ms per frame at `target_fps=60`. That latency (more than one camera frame) is why `finn_v1` uses `target_fps=150`. `size_net/build.py` has its own copy of the network; `train/model.py` is the reference.

```sh
./run-docker.sh build_custom $REPO/kria_face_detect/ml/size_net       # from ~/finn, about 1 hour
```
