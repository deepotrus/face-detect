################################################################################
# Program the board and run the application over JTAG (Zynq-7000 and
# Zynq UltraScale+, e.g. ZedBoard and Kria KV260).
# Same sequence as the Vitis GUI launch: system reset, program PL,
# ps7_init / psu_init, download ELF, run. No FSBL needed.
#
#   xsct tools/xsct-kit/run_hw.tcl <app>   compiles <app> first if it has no ELF yet
#   xsct tools/xsct-kit/run_hw.tcl         pick one of the compiled apps
#
# Watch the output in a separate terminal, with DTR/RTS held low (see README):
#   picocom -b 115200 --lower-dtr --lower-rts /dev/ttyACM0
################################################################################

source [file join [file dirname [info script]] lib common.tcl]

set usage {usage: xsct run_hw.tcl [<app>]

  <app>    app to run (its folder name in sw/src); compiled first if it has
           no ELF yet. Omitted: pick from the compiled apps (or the only one).
  -h       this help}

# No app given: pick among the compiled apps (prompt if more than one).
# With a single app in the workspace and nothing compiled, use that app.
proc select_app {} {
    set ws_apps  [kit_ws_apps]
    set compiled {}
    foreach app $ws_apps {
        if {[file exists [kit_app_elf $app]]} { lappend compiled $app }
    }
    if {[llength $compiled] == 1} { return [lindex $compiled 0] }
    if {![llength $compiled]} {
        if {[llength $ws_apps] == 1} { return [lindex $ws_apps 0] }
        kit_die "no compiled apps. Compile one with: xsct tools/xsct-kit/compile_app.tcl <app>\n  or run it directly: xsct tools/xsct-kit/run_hw.tcl <app>\n  apps: [join $ws_apps {, }]"
    }
    return [kit_prompt_app $compiled "Compiled apps:" run]
}

set app [kit_parse_args {} $usage]
if {$app eq ""} {
    set app [select_app]
    kit_log "Selected: $app"
} else {
    kit_check_app $app
}
set app_elf [kit_app_elf $app]

# Per family: PS init script and the PL address ranges xsdb may access
switch -- $family {
    zynq {
        set init_tcl  "ps7_init.tcl"
        set pl_ranges {{0x40000000 0xbfffffff}}
    }
    zynqmp {
        set init_tcl  "psu_init.tcl"
        set pl_ranges {{0x80000000 0xbfffffff} {0x400000000 0x5ffffffff} {0x1000000000 0x7fffffffff}}
    }
    default {
        kit_die "run_hw.tcl supports Zynq-7000 (ps7_cortexa9_*) and Zynq UltraScale+\n  (psu_cortexa53_*, psu_cortexr5_*), not proc_name '$proc_name'"
    }
}

set hw_dir        "$platform_dir/hw"
set hw_xsa        [lindex [glob -nocomplain -directory $hw_dir *.xsa] 0]
set init_path     "$hw_dir/$init_tcl"

kit_require_file $init_path "platform not generated? run create_workspace.tcl or update_hw.tcl"
if {$hw_xsa eq ""} { kit_die "no .xsa in $hw_dir" }

# Not compiled yet: compile it now. An existing ELF is used as is — after
# editing sources, run compile_app.tcl first.
if {![file exists $app_elf]} {
    kit_log "$app is not compiled yet ([file tail $app_elf] missing), compiling it"
    if {![kit_compile $app]} { kit_die "build of $app failed, not running it" }
}

connect

# ZynqMP: force JTAG boot mode, whatever the boot-mode pins say (the Kria SOM
# boots from QSPI). BOOT_MODE_USER survives `rst -system`; without it the
# reset reboots the flash firmware, which then owns the PL configuration port
# and `fpga` fails with "fpga initialization failed".
if {$family eq "zynqmp"} {
    kit_target "PSU"
    mwr 0xffca0010 0x0      ;# CSU multiboot = 0
    mwr 0xff5e0200 0x0100   ;# CRL_APB BOOT_MODE_USER: alternate boot mode = JTAG
}

# Reset the whole PS (not just the core), so no state from a previous run
# (running app, MMU/caches, AXI transactions to the old PL) survives
kit_target "APU*"
rst -system
after 3000

if {$program_pl} {
    set bit_path [lindex [glob -nocomplain -directory $hw_dir *.bit] 0]
    if {$bit_path eq ""} { kit_die "no bitstream in $hw_dir (set program_pl 0 for PS-only designs)" }
    fpga -file $bit_path
    kit_log "FPGA programmed: [file tail $bit_path]"
}

kit_target "APU*"
loadhw -hw $hw_xsa -mem-ranges $pl_ranges -regs
configparams force-mem-access 1

if {$family eq "zynq"} {
    kit_target $core_target
    source $init_path
    ps7_init
    ps7_post_config
} else {
    source $init_path
    psu_init
    after 1000
    psu_ps_pl_isolation_removal
    after 1000
    psu_ps_pl_reset_config
    catch {psu_protection}
    # After a JTAG-mode reset the cores are held in reset: this releases the
    # core (halted) so the ELF can be downloaded
    kit_target $core_target
    rst -processor
}
kit_log "PS init done ([file rootname $init_tcl])"

dow $app_elf
configparams force-mem-access 0
# dow leaves pc at the ELF entry point (start of the app image)
set entry [scan [lindex [rrd pc] 1] %llx]
kit_log "App downloaded: [file tail $app_elf]"

con
kit_log "App started"

# Sanity check: a pc below the app entry, or in OCM high (0xFFFC0000+, where
# the BootROM parks the cores on both families), usually means the PS was
# reset after the download — unless your app is linked to run from OCM high.
after 500
if {[catch {stop; set pc [lindex [rrd pc] 1]; con} err]} {
    kit_log "WARNING: cannot read the pc ($err), the core may have been reset"
    exit 1
}
set pc_val [scan $pc %llx]
if {$pc_val < $entry || $pc_val >= 0xFFFC0000} {
    if {$pc_val < $entry} {
        kit_log "WARNING: pc=0x$pc is below the app entry [format 0x%x $entry], the app is not running"
    } else {
        kit_log "WARNING: pc=0x$pc is in OCM high, where the BootROM parks the core after a reset"
        puts "  Ignore this if your app is linked to run from OCM high."
    }
    puts "  The PS was probably reset after the download. A known cause is the serial"
    puts "  terminal asserting DTR/RTS, which on some USB-UART bridges resets the"
    puts "  board. Use picocom with both held low:"
    puts "    picocom -b 115200 --lower-dtr --lower-rts /dev/ttyACM0"
    puts "  then re-run this script. If it persists: check the board's boot-mode"
    puts "  jumpers (JTAG) and power, and try again after a power cycle."
} else {
    kit_log "APP RUNNING (pc=0x$pc) — check your serial terminal"
}
