################################################################################
# xsct-kit project configuration
#
#   cp _config.example.tcl _config.tcl   and edit _config.tcl (it is gitignored)
#
# It is plain Tcl, sourced by every kit script.
# Relative paths are relative to project_root.
################################################################################

# Project root. Empty = two levels above this kit (<project>/tools/xsct-kit).
# A relative value is resolved against the kit directory.
set project_root   ""

# --- Hardware / platform -----------------------------------------------------
# XSA exported from Vivado (File > Export > Export Hardware, include bitstream).
# The device/part number is taken from the XSA itself.
set xsa_path       "fw/prj/fpga_top.xsa"
# Empty = XSA file name without extension
set platform_name  ""
# Processor core (list them: xsct tools/xsct-kit/xsa_info.tcl), see README
# "Supported devices":
#   ps7_cortexa9_0 (Zynq-7000, arch 32-bit)
#   psu_cortexa53_0 (Zynq UltraScale+ / Kria, arch 64-bit)
#   psu_cortexr5_0 (Zynq UltraScale+ real-time core, arch 32-bit)
set proc_name      "psu_cortexa53_0"
set os             "standalone"
set arch           "64-bit"
# Empty = <os>_<proc_name>
set domain_name    ""
# UART used for stdin/stdout. Empty = platform default (lowest enabled UART,
# which may NOT be the one routed to pins — see README).
set stdio_uart     ""

# --- Workspace / applications -------------------------------------------------
# Mirrors fw/ (sources) + fw/prj (Vivado project): sw/src + sw/workspace
# Vitis workspace: generated, disposable, keep it out of git.
set workspace_dir  "sw/workspace"
# Application sources (git-tracked): one folder per app, folder name = app
# name, e.g. sw/src/hello -> app "hello". Each is symlinked into the
# workspace as <workspace>/<app>/src/user — editing either path edits the
# same files.
set src_root       "sw/src"
# Template used only to seed an empty sw/src/<app> folder,
# e.g. "Hello World", "Empty Application(C)", "Peripheral Tests"
set app_template   "Hello World"
set app_lang       "c"
# Debug or Release
set build_config   "Debug"

# --- Run on hardware ---------------------------------------------------------
# 1 = program the PL bitstream before running, 0 = skip (PS-only designs)
set program_pl     "1"
# Optional JTAG cable name pattern when several boards are connected,
# e.g. "Digilent Zed 210248*". Empty = first cable found.
set jtag_filter    ""
