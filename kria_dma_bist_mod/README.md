# Step 3 — kria_dma_bist_mod: first AXI-Stream block, YUYV → grayscale

## Objective

Replace step 2's loopback with a first processing block written in VHDL: **`yuyv2gray`** keeps the brightness (Y) of the webcam's YUYV stream and drops the colour, so a 640×480 frame goes in as 614 400 bytes and comes back as a 307 200-byte grayscale image, in one DMA transfer each way.

## What's new

- **YUYV 4:2:2**: the C170's native format, 2 pixels per 32-bit word (`Y0 U Y1 V`, `Y0` in `tdata[7:0]`). The Y bytes are already the grayscale image.
- **The AXI-Stream handshake, done by hand**: 2 input words → 1 output word, so input and output rates differ. A beat moves only when `tvalid` and `tready` are both 1; `tready` = "I have room now" (output empty, or emptying at this very clock); `tvalid` high = my output register is occupied; stalls propagate back to the DMA, nothing is ever dropped.
- **Self-checking testbench** (`fw/hdl/tb/tb_yuyv2gray.vhd`): full frames, random input gaps, random output backpressure, a 1000-cycle stall, a protocol checker, a full-rate check, and one PASS/FAIL line. Every later block is verified the same way.
- Clock and reset now come out of the block design (`pl_clk0`, `peripheral_aresetn`) for the registered VHDL.

## Builds on / prepares

Uses step 2's DMA block design and PYNQ flow unchanged (S2MM simply receives fewer bytes than MM2S sends; `tlast` ends the transfer). `yuyv2gray` is the first stage of the pipelines in steps 4 and 5, and the testbench method is reused for every block that follows.

## Contents

| Path | |
|---|---|
| `fw/hdl/yuyv2gray.vhd` | YUYV (32 bit, 2 px/word) → gray (32 bit, 4 px/word) |
| `fw/hdl/fpga_top.vhd` | MM2S → yuyv2gray → S2MM |
| `fw/hdl/tb/tb_yuyv2gray.vhd` | self-checking testbench |
| `fw/bd/design_1.tcl`, `fw/create_project.tcl`, `fw/build.tcl` | block design, project, build |
| `pynq/yuyv2gray.ipynb`, `pynq/export_overlay.sh` | notebook; XSA → `yuyv2gray.bit` + `.hwh` |

## Build, simulate, run

```sh
tools/run_testbenches.sh yuyv2gray                       # tb_yuyv2gray: PASS (4 frames, 307200 output words)
vivado -mode batch -source kria_dma_bist_mod/fw/create_project.tcl
vivado -mode batch -source kria_dma_bist_mod/fw/build.tcl
cd kria_dma_bist_mod/pynq && ./export_overlay.sh         # -> yuyv2gray.bit, yuyv2gray.hwh
```

Upload `yuyv2gray.ipynb`, `.bit` and `.hwh` to Jupyter ([docs/setup_board.md](../docs/setup_board.md)), close other notebooks that use the webcam, run all cells. The notebook checks:
1. synthetic data: output = `tx[0::2]`, the DMA's `S2MM_LENGTH` register reports 307 200 bytes, the 64 bytes after the frame stay untouched;
2. one webcam frame: FPGA grayscale = OpenCV's `COLOR_YUV2GRAY_YUYV`;
3. a 60-frame live loop, every frame checked.

## Results

| | |
|---|---|
| Implementation (2026-10-06) | WNS +5.64 ns at 100 MHz, 5 185 LUTs (whole design), 0 DSP |
| PL time per frame | **1.90 ms** (614 400 B at 400 MB/s = 1.54 ms + Python overhead); bit-exact on synthetic data and webcam frames |
| Live loop | 13.7 fps, limited by the per-frame numpy checks in the loop, not by the PL |
