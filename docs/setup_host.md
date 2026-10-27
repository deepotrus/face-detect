# Host setup: Vivado, Vitis, JTAG and UART (Linux PC)

What every step needs on the PC. The board side (Ubuntu + PYNQ) is in [setup_board.md](setup_board.md), FINN in [setup_finn.md](setup_finn.md).

## Tools

| Tool | Version | Used for |
|---|---|---|
| Vivado + Vitis (classic, with `xsct`) + Vitis HLS | **2022.2** | all hardware; bare-metal apps (steps 1-2); FINN (step 5) |
| `picocom` | any | UART console of the board |
| Python 3 + numpy + Pillow | any | small host scripts (`ml/train/prep_wider.py`, `show_samples.py`) |
| Docker | any | FINN and training (step 5), see [setup_finn.md](setup_finn.md) |

All scripts were run on Debian 13 with Vivado installed in `/tools/Xilinx`. Other Linux distributions supported by Vivado 2022.2 should work the same.

Load the tools in every shell that runs Vivado/xsct:

```sh
source /tools/Xilinx/Vivado/2022.2/settings64.sh
source /tools/Xilinx/Vitis/2022.2/settings64.sh      # for xsct (steps 1-2)
```

## Reference documents

- *Kria K26 SOM Data Sheet* (DS987): resources of the XCK26 (117 120 LUTs, 144 BRAM36, 64 URAM, 1 248 DSP), on [docs.amd.com](https://docs.amd.com/r/en-US/ds987-k26-som).
- *Kria KV260 Vision AI Starter Kit User Guide* (UG1089) and the [KV260 page](https://www.amd.com/en/products/system-on-modules/kria/k26/kv260-vision-starter-kit.html).

## KV260 board files

The projects use the board part `xilinx.com:kv260_som:part0:1.4`. Install it once from Vivado: **Tools → Vivado Store → Boards**, refresh, install *Kria KV260 Vision AI Starter Kit SOM*. Check from the Tcl console:

```tcl
get_board_parts *kv260_som*1.4
```

## JTAG cable drivers

For programming the board over the micro-USB (steps 1-2), install the cable drivers once (as root) and replug the board:

```sh
cd /tools/Xilinx/Vivado/2022.2/data/xicom/cable_drivers/lin64/install_script/install_drivers
sudo ./install_drivers
```

They install udev rules `/etc/udev/rules.d/52-xilinx-*.rules`.

## UART console

The micro-USB also carries the PS UART1 console (115200 baud). Your user must be in the `dialout` group (log out and in after adding it):

```sh
sudo usermod -aG dialout $USER
picocom -b 115200 /dev/ttyUSB1          # the 2nd or 3rd FTDI port, depending on the PC
```

Bare-metal output (`xil_printf`) and the Linux console both appear there.

## Recreating and building a step's hardware

Every step has the same three scripts in `fw/`. Run them from anywhere:

```sh
vivado -mode batch -source <step>/fw/create_project.tcl    # project in <step>/fw/prj (deleted and recreated)
vivado -mode batch -source <step>/fw/build.tcl             # bitstream + <step>/fw/prj/fpga_top.xsa, prints WNS
```

`fw/bd/design_1.tcl` is the block design, exported with `write_bd_tcl` from the original project. `create_project.tcl` sources it, adds the step's VHDL and testbenches and sets the top level. Open `fw/prj/prj.xpr` in the Vivado GUI to look at or change the design; after changing the block design, export it again with `write_bd_tcl -force <step>/fw/bd/design_1.tcl` so the change is kept.

## xsct-kit (bare-metal apps, steps 1-2)

`tools/xsct-kit` replaces the Vitis GUI: it creates the Vitis workspace from the XSA, compiles the apps in `sw/src/<app>/` and runs them over JTAG. Each step has its own copy with a step-specific `_config.tcl`. Full documentation: [hello_kria/tools/xsct-kit/README.md](../hello_kria/tools/xsct-kit/README.md).

```sh
cd <step>
xsct tools/xsct-kit/create_workspace.tcl          # platform + one app per sw/src/<app>
xsct tools/xsct-kit/compile_app.tcl <app>
xsct tools/xsct-kit/run_hw.tcl <app>              # reset, program the PL, psu_init, run
```

Watch the output with `picocom`. `run_hw.tcl` resets the board over JTAG: a running Linux is stopped, power-cycle the board to boot Linux again.

## Testbenches

All self-checking VHDL testbenches in one go (about 30 s):

```sh
tools/run_testbenches.sh
```

Each prints one `PASS`/`FAIL` line. To run one in the Vivado GUI instead: open the step's project, set the testbench as simulation top, *Run Behavioral Simulation*, then `run all`.
