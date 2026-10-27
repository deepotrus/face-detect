################################################################################
# xsct-kit common library — sourced by every kit script.
#
# Loads _config.tcl (next to this lib/ dir), fills in derived defaults,
# resolves relative paths against project_root and provides small helpers.
################################################################################

source [file join [file dirname [info script]] util.tcl]

# ---------------------------------------------------------------------------
# Defaults (overridden by _config.tcl)
# ---------------------------------------------------------------------------
set project_root   ""
set workspace_dir  "sw/workspace"
set xsa_path       ""
set platform_name  ""
set proc_name      "ps7_cortexa9_0"
set os             "standalone"
set arch           "32-bit"
set domain_name    ""
set stdio_uart     ""
set src_root       "sw/src"
set app_template   "Hello World"
set app_lang       "c"
set build_config   "Debug"
set program_pl     1
set jtag_filter    ""

set kit_config [file join $kit_dir _config.tcl]
if {![file exists $kit_config]} {
    kit_die "config not found: $kit_config\n  cp [file join $kit_dir _config.example.tcl] $kit_config  and edit it"
}
source $kit_config

# ---------------------------------------------------------------------------
# Derived values / path resolution
# ---------------------------------------------------------------------------
proc kit_abspath {p} {
    if {$p eq ""} { return "" }
    return [file normalize [file join $::project_root $p]]
}

if {$project_root eq ""} {
    set project_root [file normalize [file join $kit_dir .. ..]]
} else {
    set project_root [file normalize [file join $kit_dir $project_root]]
}

foreach key {xsa_path src_root} {
    if {[set $key] eq ""} { kit_die "config: '$key' must be set" }
}

set workspace_dir [kit_abspath $workspace_dir]
set xsa_path      [kit_abspath $xsa_path]
set src_root      [kit_abspath $src_root]

if {$platform_name eq ""} { set platform_name [file rootname [file tail $xsa_path]] }
if {$domain_name eq ""}   { set domain_name "${os}_${proc_name}" }

switch -nocase -- $build_config {
    debug   { set build_config "Debug" }
    release { set build_config "Release" }
    default { kit_die "config: build_config must be Debug or Release (got '$build_config')" }
}

set platform_dir "$workspace_dir/$platform_name"

# Processor family and JTAG target of the core, from proc_name.
# Empty family = not supported by run_hw.tcl (the other scripts don't care).
lassign [kit_core_info $proc_name] family core_target

# ---------------------------------------------------------------------------
# Helpers
# ---------------------------------------------------------------------------
proc kit_require_file {path hint} {
    if {![file exists $path]} { kit_die "not found: $path\n  $hint" }
}

# Select a JTAG target by name pattern, honouring the optional cable filter
proc kit_target {name_pattern} {
    set filter "name =~ \"$name_pattern\""
    if {$::jtag_filter ne ""} {
        set filter "jtag_cable_name =~ \"$::jtag_filter\" && $filter"
    }
    if {[catch {targets -set -nocase -filter $filter} err]} {
        kit_die "$err\n  Check that the board is powered on, the JTAG USB cable is connected,\n  the boot-mode jumpers are set to JTAG and jtag_filter (if set) matches.\n  List visible targets with: xsct -eval \"connect; targets\""
    }
}

# Pin stdin/stdout of the active domain's BSP to the configured UART
proc kit_pin_stdio {} {
    if {$::stdio_uart eq ""} { return }
    kit_log "Pinning stdin/stdout to $::stdio_uart"
    bsp config stdin  $::stdio_uart
    bsp config stdout $::stdio_uart
}

# Applications = sub-folders of src_root (folder name = app name)
proc kit_apps {} {
    set apps {}
    foreach d [lsort [glob -nocomplain -type d -directory $::src_root *]] {
        set name [file tail $d]
        if {![regexp {^[A-Za-z_][A-Za-z0-9_]*$} $name]} {
            kit_die "invalid app folder name '$name' in $::src_root\n  use letters, digits and _ only (e.g. adc_test)"
        }
        if {$name eq $::platform_name} {
            kit_die "app folder '$name' has the same name as the platform, rename it"
        }
        lappend apps $name
    }
    return $apps
}

proc kit_app_elf {app} {
    return "$::workspace_dir/$app/$::build_config/$app.elf"
}

# Applications that have been created in the workspace
proc kit_ws_apps {} {
    set apps {}
    foreach app [kit_apps] {
        if {[file isdirectory "$::workspace_dir/$app"]} { lappend apps $app }
    }
    return $apps
}

# Compile one app; returns 1 on success, 0 on failure. With clean=1 the
# app's build folder is deleted first. Not `app clean`: it also cleans the
# shared platform (BSP + FSBL), forcing a full BSP rebuild.
proc kit_compile {app {clean 0}} {
    set elf [kit_app_elf $app]
    setws $::workspace_dir
    if {$clean} {
        kit_log "Cleaning $app"
        file delete -force "$::workspace_dir/$app/$::build_config"
    }
    # `app build` does not raise an error when compilation fails, so a stale
    # ELF would look like success: delete it (forces a relink, < 1 s), and
    # its presence after the build means the build succeeded.
    file delete -force $elf
    app build -name $app
    if {![file exists $elf]} {
        kit_log "BUILD FAILED: $app (see the compiler output above)"
        return 0
    }
    kit_log "Compile complete: $elf"
    return 1
}

proc kit_check_app {app} {
    if {![file isdirectory "$::workspace_dir/$app"]} {
        kit_die "app '$app' is not in the workspace\n  apps in $::src_root: [join [kit_apps] {, }]\n  (new folder? run: xsct tools/xsct-kit/create_workspace.tcl)"
    }
}

# Parse the script arguments. Options may be written -x or --x and must be
# in $allowed; -h/--help prints $usage. Sets ::opt(<name>) to 0/1 for each
# allowed option and returns the app name ("" if not given).
proc kit_parse_args {allowed usage} {
    global opt
    set usage "$usage\n\napps in the workspace: [join [kit_ws_apps] {, }]"
    foreach name $allowed { set opt($name) 0 }
    set app ""
    foreach a $::argv {
        if {[string match -* $a]} {
            set name [string trimleft $a -]
            if {$name in {h help}} { puts $usage; exit 0 }
            if {$name ni $allowed} { kit_die "unknown option '$a'\n\n$usage" }
            set opt($name) 1
        } elseif {$app eq ""} {
            set app $a
        } else {
            kit_die "unexpected argument '$a'\n\n$usage"
        }
    }
    return $app
}

# Numbered list of $apps with their compile state; the user picks one by
# number or name. With allow_all, "a"/"all" returns "all".
proc kit_prompt_app {apps title action {allow_all 0}} {
    puts $title
    set i 0
    foreach app $apps {
        set elf [kit_app_elf $app]
        if {[file exists $elf]} {
            set state "compiled [clock format [file mtime $elf] -format {%Y-%m-%d %H:%M}]"
        } else {
            set state "not compiled"
        }
        puts [format "  %d) %-16s (%s)" [incr i] $app $state]
    }
    set range "1-$i"
    if {$allow_all} {
        puts "  a) all"
        append range ", a"
    }
    puts -nonewline "Select app to $action \[$range\]: "
    flush stdout
    if {[gets stdin choice] < 0} { kit_die "no selection (stdin closed), pass the app name instead" }
    set choice [string trim $choice]
    if {$allow_all && $choice in {a all}} { return all }
    if {[string is integer -strict $choice] && $choice >= 1 && $choice <= $i} {
        return [lindex $apps [expr {$choice - 1}]]
    }
    if {$choice in $apps} { return $choice }
    kit_die "invalid selection '$choice'"
}

proc kit_print_config {} {
    foreach key {kit_dir project_root workspace_dir xsa_path platform_name
                 proc_name family os arch domain_name stdio_uart src_root app_template
                 app_lang build_config program_pl jtag_filter} {
        puts [format "  %-14s %s" $key [set ::$key]]
    }
    puts "  apps:"
    foreach app [kit_apps] {
        if {[file exists [kit_app_elf $app]]} {
            set state "compiled"
        } elseif {[file isdirectory "$::workspace_dir/$app"]} {
            set state "in workspace, not compiled"
        } else {
            set state "not in workspace (run create_workspace.tcl)"
        }
        puts [format "    %-12s %s" $app $state]
    }
}

# Check proc_name, arch and stdio_uart against the XSA before anything is
# created, so a wrong config fails early with a hint instead of leaving a
# half-built platform. Reports every problem at once.
proc kit_check_xsa {} {
    kit_log "Checking the configuration against [file tail $::xsa_path]"
    kit_xsa_open $::xsa_path
    set procs [kit_xsa_procs]
    set uarts [kit_xsa_uarts]
    kit_xsa_close

    set errors {}
    if {$::proc_name ni $procs} {
        lappend errors "proc_name '$::proc_name' is not a processor in the XSA\n    processors: [join $procs {, }]"
    } else {
        set core_arch [lindex [kit_core_info $::proc_name] 2]
        if {$core_arch ne "" && $::arch ne $core_arch} {
            lappend errors "arch '$::arch' does not match $::proc_name, use arch \"$core_arch\""
        }
    }
    if {$::stdio_uart ne "" && $::stdio_uart ni $uarts} {
        lappend errors "stdio_uart '$::stdio_uart' is not an enabled UART in the XSA\n    enabled UARTs: [join $uarts {, }]"
    }
    if {[llength $errors]} {
        kit_die "config does not match the XSA:\n  - [join $errors "\n  - "]\n  List what the XSA contains with: xsct [file join $::kit_dir xsa_info.tcl]"
    }
}
