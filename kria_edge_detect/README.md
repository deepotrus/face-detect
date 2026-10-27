# Step 4 — kria_edge_detect: live Sobel edge detection

## Objective

A real image-processing pipeline in the PL: every webcam frame is converted to grayscale and filtered with a **3×3 Sobel edge detector**, at one pixel per clock, and shown live in the notebook.

```
MM2S ─yuyv─► yuyv2gray ─gray32─► unpack32to8 ─gray8─► sobel3x3 ─edge8─► pack8to32 ─edge32─► S2MM
```

## What's new

- **Width converters**: the DMA side stays 32 bit (4 pixels per word), the processing runs at 1 pixel per beat. `axis_unpack32to8` (1 word → 4 beats) and `axis_pack8to32` (4 beats → 1 word), each a small exercise in the handshake: unpack may only take a new word when its last byte is leaving.
- **Line buffer + sliding window** (`sobel3x3`): one memory of 640 entries × 16 bit holds the two previous rows per column (index = column counter, read and rewrite at the same address); a 3×3 register window shifts left on every input pixel. At the clock edge the registers still hold the old window, so the centre of the new window is `w12`.
- **Borders and drain**: the output image has the input's size, border pixels are 0 (they are exactly the windows that wrap around a row). The output lags the input by W+1 pixels, so after the frame's last input the block **drains** W+1 zeros by itself, with `tlast` on the last one.
- **Pipeline throughput**: the slowest stage sets the pace. Sobel takes 1 pixel/clock, so the DMA is throttled to 200 MB/s by backpressure, still 10× faster than the camera.
- Signals between blocks named after the link (`gray32`, `gray8`, `edge8`), not after one of its ends.

## Builds on / prepares

`yuyv2gray` and the DMA design from step 3. The line buffer, sliding window and 1-pixel-per-clock streaming are exactly what a convolution layer is made of: step 5's `downscale4x` reuses the pattern, and FINN's sliding-window generator and MVAU do the same with learned weights and many channels. The live-webcam notebook pattern carries over to step 5.

## Contents

| Path | |
|---|---|
| `fw/hdl/axis_unpack32to8.vhd`, `axis_pack8to32.vhd` | width converters |
| `fw/hdl/sobel3x3.vhd` | line buffer, 3×3 window, Sobel magnitude `min(255, |Gx|+|Gy|)`, borders, drain |
| `fw/hdl/yuyv2gray.vhd` | from step 3 |
| `fw/hdl/fpga_top.vhd` | the chain above |
| `fw/hdl/tb/` | testbenches for unpack, pack, sobel3x3 (`G_MODE` 0 = centre pixel + black border, 1 = Sobel) |
| `fw/bd/design_1.tcl`, `fw/create_project.tcl`, `fw/build.tcl` | block design, project, build |
| `pynq/edge_detect.ipynb`, `pynq/export_overlay.sh` | notebook; XSA → `edge_detect.bit` + `.hwh` |

## Build, simulate, run

```sh
tools/run_testbenches.sh                                 # includes the three testbenches of this step
vivado -mode batch -source kria_edge_detect/fw/create_project.tcl
vivado -mode batch -source kria_edge_detect/fw/build.tcl
cd kria_edge_detect/pynq && ./export_overlay.sh          # -> edge_detect.bit, edge_detect.hwh
```

Upload the notebook, `.bit` and `.hwh` to Jupyter ([docs/setup_board.md](../docs/setup_board.md)) and run all cells: synthetic frames checked against a numpy Sobel model, one webcam frame shown next to its edges, then a 60-frame live loop.

## Results

| | |
|---|---|
| Implementation (2026-10-08) | WNS +2.81 ns at 100 MHz, 5 243 LUTs (whole design), 0 DSP |
| PL time per frame | **3.43 ms** (307 200 pixels at 1 px/clock = 3.07 ms + Python overhead), bit-exact vs numpy |
| Live | **26.4 fps**: camera-bound (capture and PL run one after the other, 33.5 + 3.45 ms) |
