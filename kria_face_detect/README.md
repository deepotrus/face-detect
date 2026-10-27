# Step 5 — kria_face_detect: a neural network detecting faces in the PL

## Objective

Detect faces in the live webcam stream with a small convolutional neural network that runs **entirely in the PL**: trained in PyTorch/Brevitas on a public dataset, turned into a dataflow IP by FINN, and chained after the stream blocks of the previous steps.

```
MM2S ─yuyv─► yuyv2gray ─gray32─► unpack32to8 ─gray8─► downscale4x ─small8─► FaceNet v1 (FINN) ─grid8─► S2MM
 614 400 B / frame                                    640×480 → 160×120                         600 B / frame
```

The PS only moves frames (USB webcam → DDR → DMA) and draws the boxes; detection is done by the PL.

## What's new

- **FINN** ([docs/setup_finn.md](../docs/setup_finn.md)): a quantized network becomes one hardware block per layer, chained with AXI-Stream, packaged as an IP. **MAC** = multiply-accumulate, the unit of the network's work; **folding** (PE × SIMD MACs per clock per layer) trades LUTs for cycles; 4-bit weights make multipliers small enough for LUTs (0 DSP).
- **Integration test first** ([finn/tfc_example](finn/tfc_example/README.md)): FINN's MNIST network through the whole path before our own network depends on it.
- **Sizing before training**: FINN's resources and speed don't depend on the weight values, so the architecture was built with random weights first (`ml/size_net`).
- **Dataset → training → evaluation** ([ml/README.md](ml/README.md)): WIDER FACE preprocessed to look like the hardware input, quantization-aware training on a GPU, evaluation by face size and on real webcam frames.
- **`downscale4x`** (VHDL): 640×480 → 160×120 by 4×4 averaging with rounding, the line-buffer pattern of step 4 with one partial sum per output column.
- **FINN IP in our design**: no `tlast` from FINN, so `fpga_top_nn` counts the 600 output beats; the IP's output is INT8 in NHWC order and gets multiplied by `out_scale` in Python.

## Builds on

Steps 2-4: the DMA design and PYNQ flow, `yuyv2gray`, `axis_unpack32to8`, the testbench method and the live-webcam notebook. A convolution layer is step 4's line buffer + window with learned weights and many channels.

## Contents

| Path | |
|---|---|
| `fw/hdl/downscale4x.vhd`, `fw/hdl/tb/tb_downscale4x.vhd` | downscaler and its testbench |
| `fw/hdl/yuyv2gray.vhd`, `axis_unpack32to8.vhd` | from steps 3-4 |
| `fw/hdl/fpga_top_nn.vhd` | the face detection top level (instance `finn_design_0` of the FINN IP, tlast counter) |
| `fw/hdl/fpga_top_test.vhd` | FINN integration test top level (MNIST IP) |
| `fw/bd/design_1.tcl` | block design: as step 4, with S2MM 8 bit |
| `fw/create_project.tcl`, `fw/build.tcl` | variants `nn` (fw/prj) and `tfc_test` (fw/prj_tfc_test) |
| `ml/` | dataset preparation, training, evaluation, sizing, FINN build: [ml/README.md](ml/README.md) |
| `finn/tfc_example/` | FINN integration test: [README](finn/tfc_example/README.md) |
| `pynq/face_detect.ipynb` | board notebook: bit-exact check, one frame, live video |
| `pynq/finn_tfc_test.ipynb` | board notebook of the integration test |

## Build

```sh
# 1. FINN IP of the trained network (weights are in the repo; ~1 h, see ml/README.md)
cd ~/finn && ./run-docker.sh build_custom $REPO/kria_face_detect/ml finn_v1/build

# 2. Vivado project + bitstream
vivado -mode batch -source $REPO/kria_face_detect/fw/create_project.tcl
vivado -mode batch -source $REPO/kria_face_detect/fw/build.tcl

# 3. overlay + notebook files
cd $REPO/kria_face_detect/pynq
./export_overlay.sh                                          # -> face_detect.bit, face_detect.hwh
cp ../ml/finn_v1/hw_meta.json .
cp ../ml/finn_v1/input.npy facenet_verify_input.npy
cp ../ml/finn_v1/expected_output.npy facenet_expected_output.npy
```

Testbench: `tools/run_testbenches.sh downscale4x`.

## Run

Upload `face_detect.ipynb`, `face_detect.bit`, `face_detect.hwh`, `hw_meta.json`, `facenet_verify_input.npy`, `facenet_expected_output.npy` into one Jupyter folder ([docs/setup_board.md](../docs/setup_board.md)), close other notebooks that use the webcam, run all cells:
1. **bit-exact check**: the 2 verification images (as YUYV frames, each pixel repeated 4×4) through the PL; the 600 integers must equal the PyTorch output, S2MM must report 600 bytes;
2. one live frame with boxes;
3. 30 s of live video with boxes, fps and PL time (threshold `THR`, default 0.5).

## Results (board, 2026-10-16)

| | |
|---|---|
| Implementation | WNS +3.92 ns at 100 MHz; 18 683 LUTs, 7 BRAM tiles for the whole design (FINN IP alone: 14.3 k LUT, 0 DSP) |
| Bit-exact | 0 of 600 values differ on both verification frames (measured with 2 webcam frames; the repository's check uses 2 random images instead), S2MM 600 B, guard untouched |
| PL time per frame | **16.4 ms** (FINN RTL simulation: 15.4 ms + DMA/Python) |
| Live | **29.9 fps**: the webcam's maximum; the PL is busy about half of each 33 ms frame |

Model quality and known weaknesses: [ml/README.md](ml/README.md#3-evaluate).
