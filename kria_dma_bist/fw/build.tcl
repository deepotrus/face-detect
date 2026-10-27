# Build the bitstream and the XSA (with bitstream) of kria_dma_bist.
#   vivado -mode batch -source kria_dma_bist/fw/build.tcl [-tclargs <jobs>]
# Needs the project from fw/create_project.tcl. Output: fw/prj/fpga_top.xsa
# Ends with one line: "BUILD: kria_dma_bist WNS ... WHS ... CLB LUTs ... -> <xsa>"

set step    kria_dma_bist
set fw_dir  [file normalize [file dirname [info script]]]
set prj_dir $fw_dir/prj
set jobs    [expr {[llength $argv] > 0 ? [lindex $argv 0] : 8}]

open_project $prj_dir/prj.xpr
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "BUILD: $step FAILED, see $prj_dir/prj.runs/impl_1/runme.log"
}

open_run impl_1
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1]
set wns [expr {[llength $setup_path] ? [get_property SLACK $setup_path] : "n/a (no timed paths)"}]
set whs [expr {[llength $hold_path]  ? [get_property SLACK $hold_path]  : "n/a"}]
regexp {CLB LUTs\*?\s*\|\s*(\d+)} [report_utilization -return_string] -> luts
write_hw_platform -fixed -include_bit -force -file $prj_dir/fpga_top.xsa
puts "BUILD: $step WNS $wns ns, WHS $whs ns, CLB LUTs $luts -> $prj_dir/fpga_top.xsa"
