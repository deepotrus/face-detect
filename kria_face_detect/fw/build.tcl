# Build the bitstream and the XSA (with bitstream) of a kria_face_detect variant.
#   vivado -mode batch -source kria_face_detect/fw/build.tcl [-tclargs <variant> [<jobs>]]
#   variant: nn (default, fw/prj) or tfc_test (fw/prj_tfc_test), see fw/create_project.tcl
# Output: <project dir>/fpga_top.xsa
# Ends with one line: "BUILD: kria_face_detect (<variant>) WNS ... WHS ... CLB LUTs ... -> <xsa>"

set step    kria_face_detect
set fw_dir  [file normalize [file dirname [info script]]]
set variant [expr {[llength $argv] > 0 ? [lindex $argv 0] : "nn"}]
set jobs    [expr {[llength $argv] > 1 ? [lindex $argv 1] : 8}]

if {$variant eq "nn"} {
    set prj_dir $fw_dir/prj
} elseif {$variant eq "tfc_test"} {
    set prj_dir $fw_dir/prj_tfc_test
} else {
    error "unknown variant '$variant' (nn or tfc_test)"
}

open_project $prj_dir/prj.xpr
reset_run synth_1
launch_runs impl_1 -to_step write_bitstream -jobs $jobs
wait_on_run impl_1
if {[get_property PROGRESS [get_runs impl_1]] ne "100%"} {
    error "BUILD: $step ($variant) FAILED, see $prj_dir/prj.runs/impl_1/runme.log"
}

open_run impl_1
set setup_path [get_timing_paths -delay_type max -max_paths 1]
set hold_path  [get_timing_paths -delay_type min -max_paths 1]
set wns [expr {[llength $setup_path] ? [get_property SLACK $setup_path] : "n/a (no timed paths)"}]
set whs [expr {[llength $hold_path]  ? [get_property SLACK $hold_path]  : "n/a"}]
regexp {CLB LUTs\*?\s*\|\s*(\d+)} [report_utilization -return_string] -> luts
write_hw_platform -fixed -include_bit -force -file $prj_dir/fpga_top.xsa
puts "BUILD: $step ($variant) WNS $wns ns, WHS $whs ns, CLB LUTs $luts -> $prj_dir/fpga_top.xsa"
