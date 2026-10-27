################################################################################
# Update the platform after Vivado exported a new XSA (IP change, new
# bitstream, ...) and regenerate it, so the BSP (xparameters.h, drivers) and
# hw/ files (.bit, ps7_init/psu_init) match the new hardware.
#
#   xsct tools/xsct-kit/update_hw.tcl
#   xsct tools/xsct-kit/compile_app.tcl -all -clean
################################################################################

source [file join [file dirname [info script]] lib common.tcl]

kit_require_file $xsa_path "export the hardware from Vivado first"
kit_require_file $platform_dir "create the workspace first: xsct tools/xsct-kit/create_workspace.tcl"
kit_log "Using XSA: $xsa_path ([clock format [file mtime $xsa_path]])"

setws $workspace_dir
platform active $platform_name

# Copies the XSA into the platform and refreshes hw/ (bitstream, ps7_init/psu_init, ...)
platform config -updatehw $xsa_path

# Keep stdin/stdout pinned to the routed UART, in case the update reset them
domain active $domain_name
kit_pin_stdio

platform generate

kit_log "HW spec updated, platform regenerated"
kit_log "Next: xsct tools/xsct-kit/compile_app.tcl -all -clean"
