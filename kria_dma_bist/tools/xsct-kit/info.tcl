################################################################################
# Print the resolved configuration (paths made absolute, defaults filled in).
#
#   xsct tools/xsct-kit/info.tcl
################################################################################

source [file join [file dirname [info script]] lib common.tcl]

kit_log "xsct-kit configuration"
kit_print_config
