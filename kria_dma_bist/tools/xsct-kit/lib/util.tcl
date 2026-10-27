################################################################################
# xsct-kit utilities that don't need _config.tcl — sourced by common.tcl, and
# directly by scripts that must also work before the kit is configured.
################################################################################

set kit_dir [file normalize [file join [file dirname [info script]] ..]]

proc kit_log {msg} { puts "===== $msg =====" }

proc kit_die {msg} {
    puts stderr "xsct-kit ERROR: $msg"
    exit 1
}

# Family and JTAG target of a processor core, as {family target arch}.
# Empty family = not supported by run_hw.tcl.
proc kit_core_info {proc_name} {
    if {[regexp {^ps7_cortexa9_(\d+)$} $proc_name -> core]} {
        return [list zynq "ARM*#$core" 32-bit]
    } elseif {[regexp {^psu_cortexa53_(\d+)$} $proc_name -> core]} {
        return [list zynqmp "*A53*#$core" 64-bit]
    } elseif {[regexp {^psu_cortexr5_(\d+)$} $proc_name -> core]} {
        return [list zynqmp "*R5*#$core" 32-bit]
    }
    return [list "" "" ""]
}

# Open an XSA with hsi. hsi unpacks the XSA into a folder next to it: open a
# copy in a temp dir instead, so the Vivado project folder stays clean.
# Close with kit_xsa_close.
proc kit_xsa_open {xsa} {
    set tmp [expr {[info exists ::env(TMPDIR)] ? $::env(TMPDIR) : "/tmp"}]
    set ::kit_xsa_tmp [file join $tmp xsct-kit-[pid]]
    file mkdir $::kit_xsa_tmp
    file copy -force $xsa $::kit_xsa_tmp
    if {[catch {hsi open_hw_design [file join $::kit_xsa_tmp [file tail $xsa]]} err]} {
        file delete -force $::kit_xsa_tmp
        kit_die "cannot open $xsa: $err"
    }
}

proc kit_xsa_close {} {
    hsi close_hw_design [hsi current_hw_design]
    file delete -force $::kit_xsa_tmp
}

# hsi returns cell objects bound to the open design: using them after
# kit_xsa_close crashes xsct (segfault). Return plain names instead.
proc kit_xsa_names {cells} {
    set names {}
    foreach c $cells { lappend names [hsi get_property NAME $c] }
    return $names
}
proc kit_xsa_procs {} { return [kit_xsa_names [hsi get_cells -hier -filter {IP_TYPE==PROCESSOR}]] }
proc kit_xsa_uarts {} { return [kit_xsa_names [hsi get_cells -hier -filter {IP_NAME==psu_uart || IP_NAME==ps7_uart}]] }
