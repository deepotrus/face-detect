# Step 2 — kria_dma_bist: AXI DMA loopback, bare-metal and PYNQ

## Objective

Move data between DDR and the PL with an **AXI DMA**, and prove it works: a VHDL loopback sends every word that leaves memory (MM2S) straight back into memory (S2MM). It is tested twice, with the same bitstream:
1. a **bare-metal built-in self-test** (C, interrupts) that checks data, lengths, error handling and measures throughput;
2. a **PYNQ notebook** under Ubuntu on the board, which also sends a real webcam frame through the PL.

## What's new

- **AXI DMA** in simple mode (no scatter-gather): MM2S reads DDR into an AXI-Stream, S2MM writes an AXI-Stream into DDR. Control through `M_AXI_HPM0_FPD`, data through `S_AXI_HP0_FPD` via a SmartConnect. Interrupts `mm2s_introut`/`s2mm_introut` → `pl_ps_irq0` (GIC 121/122).
- **AXI-Stream** signals `tdata`, `tkeep`, `tlast`, `tvalid`, `tready`; the stream ports are made external of the block design and wired in `fw/hdl/fpga_top.vhd`.
- Bare-metal DMA: arm S2MM before MM2S, cache flush/invalidate around transfers, interrupt handlers, timeouts, error recovery.
- **Throughput model**: time = fixed overhead + length / rate, fitted from a length sweep.
- **Buffer length register** widened to 23 bits (8 MB per transfer): a 640×480 frame fits in one transfer.
- **Ubuntu 22.04 + Kria-PYNQ** on the board: load a bitstream from Python, drive the DMA from a notebook.

## Builds on / prepares

Builds on step 1's PS block design and tool flow. The DMA block design and the PYNQ notebook flow made here are reused by **every later step**: steps 3-5 only replace the loopback between MM2S and S2MM with processing blocks.

## Contents

| Path | |
|---|---|
| `fw/bd/design_1.tcl` | block design: PS + AXI DMA (MM2S/S2MM 32 bit, 23-bit length) + interconnects + interrupt concat |
| `fw/hdl/fpga_top.vhd` | top level: MM2S → S2MM loopback (plain wires) |
| `fw/create_project.tcl`, `fw/build.tcl` | recreate the Vivado project, build bitstream + `fw/prj/fpga_top.xsa` |
| `sw/src/dma_bist/dma_bist.c` | bare-metal BIST (interrupt driven) |
| `tools/xsct-kit/` | build/run scripts for the bare-metal app |
| `pynq/dma_loop.ipynb`, `pynq/export_overlay.sh` | PYNQ notebook; XSA → `dma_loop.bit` + `dma_loop.hwh` |

## Build

```sh
vivado -mode batch -source kria_dma_bist/fw/create_project.tcl
vivado -mode batch -source kria_dma_bist/fw/build.tcl
```

## Run: bare-metal BIST

```sh
cd kria_dma_bist
xsct tools/xsct-kit/create_workspace.tcl
xsct tools/xsct-kit/run_hw.tcl dma_bist          # compiles on first use
```

Output on `picocom -b 115200 /dev/ttyUSB1`, five tests ending with `PASS`:

| Test | What it checks |
|---|---|
| fixed | lengths 1…16380 bytes × 6 data patterns, data + guard bytes after the buffer + S2MM received length |
| soak | 1000 transfers of random length |
| throughput | 100 × maximum length |
| error interrupt | sends 4096 bytes into a 1024-byte S2MM buffer: expects the DMA error interrupt, no overwrite past the buffer, recovery after reset |
| length sweep | 256 B … 16 KB, 50 transfers each; fits the overhead + rate model |

The bare-metal buffers are 16 KB (`BUF_BYTES`), independent of the 23-bit DMA register.

## Run: PYNQ notebook

Board setup first: [docs/setup_board.md](../docs/setup_board.md) (firmware, Ubuntu, PYNQ).

```sh
cd kria_dma_bist/pynq && ./export_overlay.sh       # -> dma_loop.bit, dma_loop.hwh
```

Upload `dma_loop.ipynb`, `dma_loop.bit` and `dma_loop.hwh` into one Jupyter folder and run all cells. The notebook sends 10 × 921 600 bytes of random data and one webcam frame (640×480 BGR) through the loopback and compares them.

## Results

| | |
|---|---|
| Implementation (2026-09-30) | WNS +5.47 ns at 100 MHz, 4 779 LUTs, 0 DSP |
| Bare-metal sweep | streaming rate **400 MB/s** (= 32 bit × 100 MHz, 100 % of the link), **5.4 µs** fixed cost per transfer, half the rate reached at 2.2 KB per transfer, fit residuals ±13 ns |
| PYNQ | 921 600 B in one transfer in 2.71-2.74 ms (≈337 MB/s; ≈0.4 ms of it is Python overhead); webcam frame identical after the loop |

## Notes

- With the original 14-bit length register a frame needed 57 transfers, and each one paid the Python overhead. Widening the register (block design, AXI DMA "Width of Buffer Length Register" = 23) fixed it.
- PYNQ's `wait()` polls the DMA status register; `wait_async()` uses the interrupt.
