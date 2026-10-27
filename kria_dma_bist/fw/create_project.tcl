# Recreate the Vivado project of kria_dma_bist in fw/prj from the version-controlled sources.
#   vivado -mode batch -source kria_dma_bist/fw/create_project.tcl    (from anywhere)
# Then build the bitstream + XSA with fw/build.tcl.
# An existing fw/prj is deleted and recreated.

set fw_dir  [file normalize [file dirname [info script]]]
set prj_dir $fw_dir/prj

create_project prj $prj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

# Block design: PS + AXI DMA (simple mode, 23-bit length) + interrupts, AXI-Stream ports external
source $fw_dir/bd/design_1.tcl
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper

# Top level: MM2S -> S2MM loopback in VHDL
add_files -norecurse $fw_dir/hdl/fpga_top.vhd

add_files -fileset constrs_1 -norecurse $fw_dir/constraints/kria.xdc

set_property top fpga_top [get_filesets sources_1]

# Run settings: Vivado defaults, written out so they are explicit
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]

update_compile_order -fileset sources_1
puts "CREATE_PROJECT: kria_dma_bist -> $prj_dir/prj.xpr (top fpga_top)"
