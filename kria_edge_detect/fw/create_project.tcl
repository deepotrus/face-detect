# Recreate the Vivado project of kria_edge_detect in fw/prj from the version-controlled sources.
#   vivado -mode batch -source kria_edge_detect/fw/create_project.tcl    (from anywhere)
# Then build the bitstream + XSA with fw/build.tcl.
# An existing fw/prj is deleted and recreated.

set fw_dir  [file normalize [file dirname [info script]]]
set prj_dir $fw_dir/prj

create_project prj $prj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

# Block design: PS + AXI DMA, AXI-Stream ports, pl_clk0 and peripheral_aresetn external
source $fw_dir/bd/design_1.tcl
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper

# Top level: MM2S -> yuyv2gray -> unpack32to8 -> sobel3x3 -> pack8to32 -> S2MM
add_files -norecurse $fw_dir/hdl/yuyv2gray.vhd
add_files -norecurse $fw_dir/hdl/axis_unpack32to8.vhd
add_files -norecurse $fw_dir/hdl/sobel3x3.vhd
add_files -norecurse $fw_dir/hdl/axis_pack8to32.vhd
add_files -norecurse $fw_dir/hdl/fpga_top.vhd

add_files -fileset constrs_1 -norecurse $fw_dir/constraints/kria.xdc

# Testbenches (tb_sobel3x3 is the simulation top; switch with set_property top ... [get_filesets sim_1])
add_files -fileset sim_1 -norecurse $fw_dir/hdl/tb/tb_axis_unpack32to8.vhd
add_files -fileset sim_1 -norecurse $fw_dir/hdl/tb/tb_axis_pack8to32.vhd
add_files -fileset sim_1 -norecurse $fw_dir/hdl/tb/tb_sobel3x3.vhd

set_property top fpga_top [get_filesets sources_1]
set_property top tb_sobel3x3 [get_filesets sim_1]

# Run settings: Vivado defaults, written out so they are explicit
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]

update_compile_order -fileset sources_1
update_compile_order -fileset sim_1
puts "CREATE_PROJECT: kria_edge_detect -> $prj_dir/prj.xpr (top fpga_top)"
