# Step 1 — hello_kria: the tool flow

## Objective

Get the whole flow working once, with the simplest possible design: a block design with only the Zynq UltraScale+ processing system (PS), exported from Vivado as an XSA, a bare-metal "Hello World" built with Vitis, run over JTAG, output read on the UART.

## What's new

- **Block design** with the `zynq_ultra_ps_e` IP (KV260 board preset) and a processor system reset. No PL logic yet.
- **XSA**: the hardware description Vivado hands to the software tools (PS configuration, `psu_init`, bitstream).
- **Bare-metal app** on the Cortex-A53 (`psu_cortexa53_0`, 64 bit), `xil_printf` on PS UART1.
- **[xsct-kit](tools/xsct-kit/README.md)**: scripts that replace the Vitis GUI (workspace from XSA, compile, run over JTAG).

## Prepares the next step

A known-good tool flow (Vivado → XSA → xsct-kit → JTAG → UART) and the PS configuration that every later block design starts from. Step 2 adds an AXI DMA to this block design.

## Contents

| Path | |
|---|---|
| `fw/bd/design_1.tcl` | block design: PS + proc_sys_reset |
| `fw/create_project.tcl`, `fw/build.tcl` | recreate the Vivado project, build bitstream + `fw/prj/fpga_top.xsa` |
| `fw/constraints/kria.xdc` | KV260 PL pin template (nothing used here) |
| `sw/src/hello/` | the bare-metal app (Vitis "Hello World" template) |
| `tools/xsct-kit/` | build/run scripts, configured in `_config.tcl` (`psu_cortexa53_0`, 64-bit, XSA `fw/prj/fpga_top.xsa`) |

## Build and run

Host setup first: [docs/setup_host.md](../docs/setup_host.md).

```sh
source /tools/Xilinx/Vivado/2022.2/settings64.sh
source /tools/Xilinx/Vitis/2022.2/settings64.sh
vivado -mode batch -source hello_kria/fw/create_project.tcl
vivado -mode batch -source hello_kria/fw/build.tcl

cd hello_kria
xsct tools/xsct-kit/create_workspace.tcl
xsct tools/xsct-kit/compile_app.tcl hello
xsct tools/xsct-kit/run_hw.tcl hello
```

In another terminal, `picocom -b 115200 /dev/ttyUSB1` shows `Hello World`.

## Results

PS-only design: no PL logic (0 LUTs), nothing to time in the PL. The app prints `Hello World` on the UART.

## Notes

- `run_hw.tcl` resets the processors over JTAG. If Linux was running on the board, it is stopped; power-cycle the board to boot Linux again.
