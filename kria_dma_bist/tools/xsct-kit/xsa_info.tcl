################################################################################
# List the processors and PS UARTs in an XSA, to pick proc_name / arch /
# stdio_uart for _config.tcl. Works before the kit is configured.
#
#   xsct tools/xsct-kit/xsa_info.tcl            the XSA from _config.tcl
#   xsct tools/xsct-kit/xsa_info.tcl <xsa>      any XSA
################################################################################

source [file join [file dirname [info script]] lib util.tcl]

set usage {usage: xsct xsa_info.tcl [<xsa>]

  <xsa>    XSA to inspect. Omitted: xsa_path from _config.tcl.
  -h       this help}

if {[lsearch -regexp $argv {^--?h(elp)?$}] >= 0} { puts $usage; exit 0 }
if {[llength $argv] > 1} { kit_die "too many arguments\n\n$usage" }

if {[llength $argv]} {
    set xsa [file normalize [lindex $argv 0]]
} elseif {[file exists [file join $kit_dir _config.tcl]]} {
    source [file join $kit_dir lib common.tcl]
    set xsa $xsa_path
} else {
    kit_die "no XSA given and no _config.tcl yet\n\n$usage"
}
if {![file isfile $xsa]} { kit_die "not found: $xsa" }

kit_xsa_open $xsa

set part [hsi get_property DEVICE [hsi current_hw_design]]
set ps   [lindex [hsi get_cells -hier -filter {IP_NAME==processing_system7 || IP_NAME==zynq_ultra_ps_e}] 0]

puts ""
kit_log "XSA: $xsa"
puts "  device  $part"
if {$ps ne ""} { puts "  PS      $ps  (the block-design name of the PS, not a proc_name)" }

puts "\nProcessors (proc_name):"
foreach cpu [kit_xsa_procs] {
    lassign [kit_core_info $cpu] family target arch
    if {$family ne ""} {
        puts [format "  %-18s arch %-7s family %s" $cpu $arch $family]
    } else {
        puts [format "  %-18s (%s, not supported by run_hw.tcl)" $cpu [hsi get_property IP_NAME [hsi get_cells $cpu]]]
    }
}

# UART pins come from the PS configuration: PSU__UART<n>__PERIPHERAL__IO on
# Zynq UltraScale+, PCW_UART<n>_UART<n>_IO on Zynq-7000 ("MIO 36 .. 37", "EMIO")
puts "\nEnabled PS UARTs (stdio_uart):"
set uarts [kit_xsa_uarts]
if {![llength $uarts]} {
    puts "  none: enable the UART the board routes to its USB-UART in the PS"
    puts "  configuration (Vivado: board preset, or the board's MIO table)"
}
foreach uart $uarts {
    set io ""
    if {$ps ne "" && [regexp {_(\d+)$} $uart -> n]} {
        foreach param [list CONFIG.PSU__UART${n}__PERIPHERAL__IO CONFIG.PCW_UART${n}_UART${n}_IO] {
            if {![catch {hsi get_property $param $ps} v] && $v ne ""} { set io $v; break }
        }
    }
    puts [format "  %-18s %s" $uart $io]
}

kit_xsa_close

puts "\nPut the chosen core in _config.tcl as proc_name (and its arch). stdio_uart"
puts "is only needed when more than one UART is enabled: use the one on the"
puts "board's USB-UART pins (e.g. psu_uart_1 on MIO 36 .. 37 on the Kria KV260)."
