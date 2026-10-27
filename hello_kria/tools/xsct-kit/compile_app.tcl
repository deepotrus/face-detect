################################################################################
# Compile applications after editing their sources in sw/src/<app>.
# Does NOT touch the platform/BSP (except building it if it is out of date).
#
#   xsct tools/xsct-kit/compile_app.tcl                pick from a list
#   xsct tools/xsct-kit/compile_app.tcl <app>          incremental build
#   xsct tools/xsct-kit/compile_app.tcl <app> -clean   clean, then full build
#   xsct tools/xsct-kit/compile_app.tcl -all [-clean]  every app in the workspace
################################################################################

source [file join [file dirname [info script]] lib common.tcl]

set usage {usage: xsct compile_app.tcl [<app>] [-clean]
       xsct compile_app.tcl -all [-clean]

  <app>    app to compile (its folder name in sw/src).
           Omitted: pick from a list (or the only app, if there is one).
  -all     compile every app in the workspace
  -clean   delete the app's build folder first (full rebuild)
  -h       this help}

set app  [kit_parse_args {all clean} $usage]
set apps [kit_ws_apps]
if {![llength $apps]} {
    kit_die "no apps in the workspace, run: xsct tools/xsct-kit/create_workspace.tcl"
}

if {$opt(all)} {
    if {$app ne ""} { kit_die "give either <app> or -all, not both\n\n$usage" }
    set app all
} elseif {$app ne ""} {
    kit_check_app $app
} elseif {[llength $apps] == 1} {
    set app [lindex $apps 0]
} else {
    set app [kit_prompt_app $apps "Apps in the workspace:" compile 1]
    kit_log "Selected: $app"
}

if {$app eq "all"} {
    # Keep going on failure, report at the end
    set failed {}
    foreach a $apps {
        if {![kit_compile $a $opt(clean)]} { lappend failed $a }
    }
    kit_log "Compiled [expr {[llength $apps] - [llength $failed]}]/[llength $apps] apps"
    if {[llength $failed]} { kit_die "build failed: [join $failed {, }]" }
} elseif {![kit_compile $app $opt(clean)]} {
    kit_die "build of $app failed, see the output above"
}
