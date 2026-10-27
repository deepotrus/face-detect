# tfc_example: FINN integration test

Builds FINN's tiny MNIST network (TFC: fully connected, 1-bit weights and activations; `model.onnx`, configs and test vectors copied from FINN's `src/finn/qnn-data/build_dataflow`) up to the **stitched IP** for the KV260 chip (`xck26-sfvc784-2LV-c`, 100 MHz), then runs it on the board inside our own DMA design. It proves the whole FINN path (Docker → IP → our Vivado project → PYNQ) with a known network before the face detector depends on it.

FINN setup first: [docs/setup_finn.md](../../../docs/setup_finn.md).

## Build the IP

```sh
cd ~/finn
./run-docker.sh build_custom $REPO/kria_face_detect/finn/tfc_example     # REPO = this repository
```

About 6 minutes (3 for the out-of-context synthesis, 1.5 for HLS). The last line should be `Completed successfully`.

## Files

| File | |
|---|---|
| `build.py` | build configuration: target chip, clock, outputs, verification steps, `stitched_ip_gen_dcp=True` |
| `model.onnx` | the quantized network (QONNX) |
| `folding_config.json` | parallelism (PE/SIMD) per layer. `Thresholding_rtl_0` PE = 4 → 32-bit input stream (4 pixels per beat), matching the DMA's MM2S |
| `specialize_layers_config.json` | HLS or RTL implementation per layer |
| `input.npy`, `expected_output.npy` | 4 MNIST images and their labels (7, 2, 1, 0), for the verification steps and the board notebook |

## Output: `output_tfc_kv260/`

| Path | |
|---|---|
| `stitched_ip/ip/` | the packaged IP (`xilinx_finn:finn:finn_design:1.0`), self-contained thanks to `dcp/finn_design.dcp` |
| `verification_output/` | `*_SUCCESS.npy` = that step matched `expected_output.npy` |
| `report/` | `ooc_synth_and_timing.json`, `rtlsim_performance.json`, estimates |

## Run it on the board

```sh
vivado -mode batch -source kria_face_detect/fw/create_project.tcl -tclargs tfc_test   # project fw/prj_tfc_test
vivado -mode batch -source kria_face_detect/fw/build.tcl -tclargs tfc_test
cd kria_face_detect/pynq
./export_overlay.sh ../fw/prj_tfc_test/fpga_top.xsa finn_tfc_test
cp ../finn/tfc_example/input.npy ../finn/tfc_example/expected_output.npy .
```

`fw/hdl/fpga_top_test.vhd` puts the IP between MM2S (32 bit) and S2MM (8 bit). One image per DMA transfer: 784 bytes in, 1 byte (the digit) out, so S2MM `tlast` is simply always 1. Upload `finn_tfc_test.ipynb`, `.bit`, `.hwh`, `input.npy`, `expected_output.npy` and run all cells.

## Results

| | |
|---|---|
| First build (PE = 49, 392-bit input, 2026-10-08) | all verification steps passed (RTL bit-exact); 4 907 LUT, 6 778 FF, 11 BRAM36, 0 DSP; WNS +3.36 ns (fmax ≈ 150 MHz); 794 cycles per image |
| Board (PE = 4, 32-bit input) | the 4 images classified as **7, 2, 1, 0**, S2MM 1 byte per image; 1 622 images/s from Python (617 µs per image, almost all of it Python DMA calls: the network itself needs ~8 µs) |

## IP interface

```
ap_clk, ap_rst_n                       clock, active-low reset
s_axis_0_tdata[31:0], tvalid, tready   input: 4 pixels (UINT8) per beat, 196 beats per image
m_axis_0_tdata[7:0],  tvalid, tready   output: class index, 1 beat per image
```

No `tlast` on either side, and the input width depends on the first layer's folding.
