# xsct-kit

A small set of XSCT scripts that replaces the Vitis GUI for bare-metal Zynq-7000 and Zynq UltraScale+ (e.g. Kria KV260) projects:
- creates the workspace from an XSA, with one application per source folder
- compiles each application
- imports a new XSA
- runs an application on the board over JTAG

You watch the UART with `picocom`.

You describe the whole project in one config file. Drop this folder into any project's `tools/` directory, fill in `_config.tcl`, and run `create_workspace.tcl`.

## Requirements

- Vitis **classic** flow with `xsct`. Tested with 2022.2 only; other classic releases (up to 2023.1) will probably work but are untested. The unified Vitis IDE (2023.2+, Python API) is not supported. Put `xsct` on your PATH with `source <Vitis install>/settings64.sh`, e.g. `/tools/Xilinx/Vitis/2022.2/settings64.sh`.
- Zynq-7000 or Zynq UltraScale+, standalone. See [Supported devices](#supported-devices).
- `picocom` for the serial terminal (see [Serial terminal](#serial-terminal)). Your user must be in the `dialout` group to open `/dev/ttyACM*` / `/dev/ttyUSB*`.

## Install

```sh
cp -r xsct-kit <project>/tools/
cd <project>/tools/xsct-kit
cp _config.example.tcl _config.tcl    # _config.tcl is gitignored
xsct xsa_info.tcl <path/to/design.xsa>  # processors and UARTs to put in the config
$EDITOR _config.tcl
xsct info.tcl                         # check the resolved paths and apps
```

The default project layout mirrors the Vivado side:

```
<project>/
├── fw/                   HDL sources
│   └── prj/              Vivado project (generated), exports fpga_top.xsa
├── sw/
│   ├── src/              application sources (git-tracked)   ← src_root
│   │   ├── hello/        → app "hello"
│   │   └── adc_test/     → app "adc_test"
│   └── workspace/        Vitis workspace (generated)         ← workspace_dir
│       ├── fpga_top/                 platform, shared by all apps
│       ├── hello/src/user → sw/src/hello        (symlink)
│       ├── hello_system/
│       ├── adc_test/src/user → sw/src/adc_test  (symlink)
│       └── adc_test_system/
└── tools/xsct-kit/
```

Add the generated workspace to the **project's** `.gitignore`:

```
sw/workspace/
.Xil/
```

## Scripts

| file | scope | purpose |
|---|---|---|
| `create_workspace.tcl [-clean]` | workspace | Platform + domain + BSP, and one app per `sw/src/<app>/`. Does **not** compile the apps. Safe to re-run. `-clean` deletes the workspace first (only generated files: the sources are in `sw/src`). |
| `compile_app.tcl [<app>] [-clean]` | one app | Compiles the app. Without `<app>`, it lists the apps and asks which one to compile (or `a` for all). `-clean` first deletes this app's build folder. A failed build exits with an error, even if an older ELF exists. |
| `compile_app.tcl -all [-clean]` | all apps | Compiles every app in the workspace, carries on past failures and lists them at the end. |
| `update_hw.tcl` | platform | Imports a new XSA and regenerates the platform/BSP. |
| `run_hw.tcl [<app>]` | one app | Reset, program PL, `ps7_init`/`psu_init`, download the ELF, run. If the app has never been compiled, it's compiled first. Without `<app>`, it lists the compiled apps and asks which one to run. |
| `info.tcl` | — | Prints the resolved configuration and the apps. |
| `xsa_info.tcl [<xsa>]` | — | Lists the XSA's processors (`proc_name`, with their `arch`) and enabled PS UARTs with their pins (`stdio_uart`). Without `<xsa>` it reads `xsa_path` from the config; with it, it works before the kit is configured. |
| `_config.example.tcl` | | Configuration template (committed). |
| `_config.tcl` | | Your project's configuration (gitignored). |
| `lib/common.tcl` | | Config loading, defaults, helpers. |
| `lib/util.tcl` | | Helpers that don't need the config (logging, core → family). |

Without `<app>`, both scripts use the only app if there is just one, and otherwise ask you to pick from a numbered list (by number or name). Options can be written `-all` or `--all`, and `-h` shows each script's usage and the apps in the workspace. All scripts locate the kit from their own path, so they run from any working directory.

`create_workspace.tcl` builds the platform itself (BSP and FSBL, via `platform generate`), because an app can't be created without it. It never compiles an application.

A failed run doesn't leave the workspace half-built:

- **Config check first.** Before creating anything, it checks `proc_name`, `arch` and `stdio_uart` against the XSA, and lists every mismatch with the fix.
- **Rollback.** If creating the platform or an app fails anyway, the incomplete platform or app is removed again. Fix the cause and re-run.
- **Only complete parts are skipped.** A platform counts as existing once it has been exported (`export/<platform>/<platform>.xpfm`) with the configured domain, and an app once its `src/user` link exists. Anything else, e.g. left by a Ctrl-C, is recreated. If the platform exists with a different domain (you changed `proc_name`), the script stops and asks for `-clean`.

## Configuration

`_config.tcl` is plain Tcl, sourced by every script. Relative paths are relative to `project_root`.

| key | default | meaning |
|---|---|---|
| `project_root` | `""` | Empty means two levels above the kit (`<project>/tools/xsct-kit` → `<project>`). A relative value is resolved against the kit directory. |
| `xsa_path` | *(required)* | XSA exported from Vivado, including the bitstream. The part number comes from the XSA. |
| `platform_name` | `""` | Empty means the XSA file name without extension. |
| `proc_name` | `ps7_cortexa9_0` | Processor core. It also selects the device family used by `run_hw.tcl`, see [Supported devices](#supported-devices). |
| `os` / `arch` | `standalone` / `32-bit` | |
| `domain_name` | `""` | Empty means `<os>_<proc_name>`. |
| `stdio_uart` | `""` | UART for stdin/stdout, e.g. `ps7_uart_1` or `psu_uart_1`. Empty keeps the platform default (see Troubleshooting). |
| `workspace_dir` | `sw/workspace` | Vitis workspace. It is generated and disposable. |
| `src_root` | `sw/src` | One folder per application. The folder name is the app name. |
| `app_template` | `Hello World` | Used only to seed an empty app folder. Other examples: `Empty Application(C)`, `Peripheral Tests`. |
| `app_lang` | `c` | `c` or `c++`, for all apps |
| `build_config` | `Debug` | `Debug` or `Release`, for all apps. The ELF ends up in `<ws>/<app>/<build_config>/<app>.elf`. |
| `program_pl` | `1` | `0` skips programming the bitstream (PS-only designs). |
| `jtag_filter` | `""` | JTAG cable name pattern for when several boards are connected |

## Supported devices

The family is derived from `proc_name`; `info.tcl` prints it as `family`.

| family | `proc_name` | `arch` | tested on |
|---|---|---|---|
| `zynq` (Zynq-7000) | `ps7_cortexa9_0`, `ps7_cortexa9_1` | `32-bit` | ZedBoard |
| `zynqmp` (Zynq UltraScale+) | `psu_cortexa53_0` … `_3` | `64-bit` | Kria KV260 |
| `zynqmp` | `psu_cortexr5_0`, `psu_cortexr5_1` | `32-bit` | untested |

To list the cores in an XSA, with their `arch` and the enabled UARTs:

```sh
xsct tools/xsct-kit/xsa_info.tcl fw/prj/fpga_top.xsa
```

Use a CPU core, not the PS block name from the block design (`processing_system7_0`, `zynq_ultra_ps_e_0`).

Only `run_hw.tcl` depends on the family:

| | Zynq-7000 | Zynq UltraScale+ |
|---|---|---|
| PS init | `ps7_init` + `ps7_post_config` | `psu_init`, PS-PL isolation removal, PL reset config |
| boot mode | set by the jumpers (must be JTAG) | forced to JTAG through `BOOT_MODE_USER` before `rst -system` |
| JTAG core target | `ARM*#<n>` | `*A53*#<n>` / `*R5*#<n>` |

### Kria KV260

- **Boot mode.** The SOM boots from QSPI and the carrier has no boot-mode jumpers. `run_hw.tcl` writes `BOOT_MODE_USER` so the next `rst -system` boots in JTAG mode, like the Vitis GUI does. Without this, the QSPI firmware starts again after the reset and programming the PL fails with `fpga initialization failed`. The override lasts until a power cycle.
- **UART.** The USB-UART (the FTDI's second port, usually `/dev/ttyUSB1`) is connected to **UART1 on MIO 36..37**. MIO 0..12 are the SOM's QSPI boot flash, so don't route peripherals there. Applying the KV260 board preset in the Zynq UltraScale+ block sets the MIO correctly.

## Applications

- **One folder per app.** `sw/src/<app>/` becomes the app `<app>`. The folder is the only place an app is declared; there's no list to maintain in the config.
- **Naming.** Use lowercase `snake_case`: letters, digits and `_` only (e.g. `adc_test`). The name is also used for the build target and for `<app>_system`. It can't be the same as the platform name.
- **Adding an app.** Create `sw/src/<new_app>/` and re-run `create_workspace.tcl`. Existing apps and the platform are skipped. An empty folder is seeded with the sources of `app_template`; a folder that already has files is used as it is.
- **Removing an app.** Delete `sw/src/<app>/`, then delete `sw/workspace/<app>/` and `sw/workspace/<app>_system/`. Or delete the whole workspace and run `create_workspace.tcl` again.
- **Editing sources.** `<ws>/<app>/src/user` is a symlink to `sw/src/<app>`, so `sw/workspace/<app>/src/user/foo.c` and `sw/src/<app>/foo.c` are the same file. Editing either one (e.g. from an IDE opened on the workspace) changes `sw/src` directly. Files you add or remove are picked up by the next compile.
- **Linker script.** Each app's `lscript.ld` stays in the workspace and is regenerated with it, so edits to it are lost when the workspace is recreated. The kit doesn't manage custom linker scripts yet.

## Serial terminal

Use **picocom**, holding DTR and RTS low:

```sh
picocom -b 115200 --lower-dtr --lower-rts /dev/ttyACM0     # exit: Ctrl-A Ctrl-X
```

On the ZedBoard, when the terminal asserts DTR/RTS the app prints nothing. Sometimes the PS is reset right after the download (`run_hw.tcl` warns that the pc is outside the app). Other times the app looks like it is running but the terminal stays silent.

- picocom deasserts both lines from the command line, every time.
- microcom can only change them interactively after the port is open (`Ctrl-\`, then `dtr 0` / `rts 0`), which is too late and easy to forget.

## Workflows

**First setup**, or after deleting the workspace:

```sh
mkdir -p sw/src/hello                         # empty → seeded from app_template
xsct tools/xsct-kit/create_workspace.tcl
xsct tools/xsct-kit/run_hw.tcl hello          # compiles hello first, since it has no ELF yet
```

**Edit, compile, run:**

```sh
picocom -b 115200 --lower-dtr --lower-rts /dev/ttyACM0   # terminal 1, keep open
xsct tools/xsct-kit/compile_app.tcl hello                # terminal 2
xsct tools/xsct-kit/run_hw.tcl hello                     # or without a name: pick from a list
```

Open the terminal **before** `run_hw.tcl`, so no output is lost and the port is already open with DTR/RTS low.

`run_hw.tcl` only compiles an app that has no ELF yet. If an ELF exists, it runs it as it is, so after editing sources run `compile_app.tcl` first.

**New XSA from Vivado** (IP change, new bitstream):

```sh
xsct tools/xsct-kit/update_hw.tcl                 # platform, shared by all apps
xsct tools/xsct-kit/compile_app.tcl -all -clean   # every app
xsct tools/xsct-kit/run_hw.tcl hello
```

## Troubleshooting

- **`no targets found with "..."`, `available targets: none`.**
  - Check that the board is **powered on**.
  - Check that the JTAG USB cable is connected, and that the boot-mode jumpers are set to JTAG.
  - If you set `jtag_filter`, check that it matches.

  `xsct -eval 'connect; targets'` lists what is visible.
- **Several boards on one PC.** Set `jtag_filter` to the cable name shown by `jtag targets`.
- **`fpga initialization failed` (Zynq UltraScale+).** The PS was not reset in JTAG boot mode. Check that `proc_name` is a `psu_*` core (`info.tcl` shows `family zynqmp`); `run_hw.tcl` then forces JTAG boot mode. See [Kria KV260](#kria-kv260).
- **`WARNING: pc=... is below the app entry` / `is in OCM high`.** The pc is back in BootROM/OCM (e.g. `0x00008fe0` or `0xffffff28`), so the PS was probably reset after the download. Usually the cause is the serial terminal's DTR/RTS: use picocom as shown in [Serial terminal](#serial-terminal) and re-run `run_hw.tcl`. If it persists, check the boot-mode jumpers and power, and power-cycle the board.
  - OCM high is at the same address on Zynq-7000 and Zynq UltraScale+. If your app is linked to run from OCM high (`0xFFFC0000` and up), the OCM-high warning is expected and harmless.
- **`APP RUNNING` but no output.**
  - Check the terminal first: picocom with `--lower-dtr --lower-rts`, the right port, 115200 baud.
  - Then check the UART choice. When the block design enables more than one PS UART, Vitis picks the lowest-numbered one for stdio, and it may be routed to EMIO and connected to nothing. Set `stdio_uart` to the UART that is actually on the pins (e.g. `ps7_uart_1` on MIO 48/49 on the ZedBoard, `psu_uart_1` on MIO 36/37 on the KV260), then run `update_hw.tcl` and `compile_app.tcl -all -clean`. You can check it with `grep STDOUT_BASEADDRESS` in the BSP's `xparameters.h`.
  - Otherwise the core may be stuck in an exception loop, because of a crash early in `main` or a wrong DDR/PS configuration in the XSA.
- **`app '<name>' is not in the workspace`.** The folder exists in `sw/src/` but no app has been created for it yet. Run `create_workspace.tcl`.
