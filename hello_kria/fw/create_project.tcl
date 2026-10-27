# Recreate the Vivado project of hello_kria in fw/prj from the version-controlled sources.
#   vivado -mode batch -source hello_kria/fw/create_project.tcl       (from anywhere)
# Then build the bitstream + XSA with fw/build.tcl.
# An existing fw/prj is deleted and recreated.

set fw_dir  [file normalize [file dirname [info script]]]
set prj_dir $fw_dir/prj

create_project prj $prj_dir -part xck26-sfvc784-2LV-c -force
set_property board_part xilinx.com:kv260_som:part0:1.4 [current_project]
set_property target_language VHDL [current_project]
set_property simulator_language Mixed [current_project]

# Block design: Zynq UltraScale+ PS + processor system reset (exported with write_bd_tcl)
source $fw_dir/bd/design_1.tcl
validate_bd_design
save_bd_design
set wrapper [make_wrapper -files [get_files design_1.bd] -top]
add_files -norecurse $wrapper

# Constraints (template only: no PL pins used in this step)
add_files -fileset constrs_1 -norecurse $fw_dir/constraints/kria.xdc

set_property top design_1_wrapper [get_filesets sources_1]

# Run settings: Vivado defaults, written out so they are explicit
set_property strategy {Vivado Synthesis Defaults} [get_runs synth_1]
set_property strategy {Vivado Implementation Defaults} [get_runs impl_1]

update_compile_order -fileset sources_1
puts "CREATE_PROJECT: hello_kria -> $prj_dir/prj.xpr (top design_1_wrapper)"
