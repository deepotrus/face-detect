# Recreate a Vivado project of kria_face_detect from the version-controlled sources.
#   vivado -mode batch -source kria_face_detect/fw/create_project.tcl                       (variant nn)
#   vivado -mode batch -source kria_face_detect/fw/create_project.tcl -tclargs tfc_test     (FINN test)
# Then build the bitstream + XSA with fw/build.tcl (same variant argument).
#
# Variants (each in its own project dir: every FINN IP is called xilinx_finn:finn:finn_design:1.0,
# so two FINN IPs cannot share a project):
#   nn       -> fw/prj           top fpga_top_nn:   MM2S -> yuyv2gray -> unpack -> downscale4x -> FaceNet v1 -> S2MM
#            needs the FINN build of ml/finn_v1 (output_facenet_v1/stitched_ip/ip)
#   tfc_test -> fw/prj_tfc_test  top fpga_top_test: MM2S -> FINN MNIST example (TFC) -> S2MM
#            needs the FINN build of finn/tfc_example (output_tfc_kv260/stitched_ip/ip)
# An existing project dir of the variant is deleted and recreated.

set fw_dir  [file normalize [file dirname [info script]]]
set variant [expr {[llength $argv] > 0 ? [lindex $argv 0] : "nn"}]

if {$variant eq "nn"} {
    set prj_dir  $fw_dir/prj
    set ip_repo  [file normalize $fw_dir/../ml/finn_v1/output_facenet_v1/stitched_ip/ip]
    set top      fpga_top_nn
} elseif {$variant eq "tfc_test"} {
    set prj_dir  $fw_dir/prj_tfc_test
    set ip_repo  [file normalize $fw_dir/../finn/tfc_example/output_tfc_kv260/stitched_ip/ip]
    set top      fpga_top_test
} else {
    error "unknown variant '$variant' (nn or tfc_test)"
}
if {![file exists $ip_repo/component.xml]} {
    error "FINN IP not found: $ip_repo\n  run the FINN build first (see kria_face_detect/README.md)"
}

create_project prj $prj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

# Block design: PS + AXI DMA (MM2S 32 bit, S2MM 8 bit), AXI-Stream ports, pl_clk0 and
# peripheral_aresetn external
source $fw_dir/bd/design_1.tcl
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper

# FINN stitched IP (self-contained DCP), instance name used by both top levels
set_property ip_repo_paths $ip_repo [current_project]
update_ip_catalog -rebuild
create_ip -vlnv xilinx_finn:finn:finn_design:1.0 -module_name finn_design_0
generate_target all [get_ips finn_design_0]

if {$variant eq "nn"} {
    add_files -norecurse $fw_dir/hdl/yuyv2gray.vhd
    add_files -norecurse $fw_dir/hdl/axis_unpack32to8.vhd
    add_files -norecurse $fw_dir/hdl/downscale4x.vhd
    add_files -norecurse $fw_dir/hdl/fpga_top_nn.vhd
    add_files -fileset sim_1 -norecurse $fw_dir/hdl/tb/tb_downscale4x.vhd
    set_property top tb_downscale4x [get_filesets sim_1]
} else {
    add_files -norecurse $fw_dir/hdl/fpga_top_test.vhd
}

set_property top $top [get_filesets sources_1]

# Run settings: Vivado defaults, written out so they are explicit
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]

update_compile_order -fileset sources_1
puts "CREATE_PROJECT: kria_face_detect ($variant) -> $prj_dir/prj.xpr (top $top, FINN IP $ip_repo)"
