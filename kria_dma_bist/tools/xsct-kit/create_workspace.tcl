################################################################################
# Create the Vitis workspace: platform (from XSA) + domain + BSP, and one
# application per folder in src_root (sw/src/<app> -> app "<app>").
# Does NOT compile the applications: use compile_app.tcl <app>.
#
#   xsct tools/xsct-kit/create_workspace.tcl
#   xsct tools/xsct-kit/create_workspace.tcl -clean    delete the workspace first
#
# Safe to re-run: what already exists is skipped. To add an application,
# create sw/src/<new_app>/ (empty = seeded from app_template) and re-run.
# The config is checked against the XSA first; a platform whose creation
# failed is removed, so fixing the config and re-running is enough.
################################################################################

source [file join [file dirname [info script]] lib common.tcl]

set usage {usage: xsct create_workspace.tcl [-clean]

  -clean   delete the workspace first and recreate it. Only generated files
           are lost: the app sources live in sw/src.
  -h       this help}

if {[kit_parse_args {clean} $usage] ne ""} { kit_die "unexpected argument\n\n$usage" }

kit_require_file $xsa_path "export the hardware from Vivado first"

kit_log "Configuration"
kit_print_config
kit_check_xsa

if {$opt(clean) && [file exists $workspace_dir]} {
    kit_log "Deleting the workspace $workspace_dir"
    # Deletes the <app>/src/user symlinks, not the sw/src folders they point to
    file delete -force $workspace_dir
}
file mkdir $workspace_dir $src_root

setws $workspace_dir

# The platform is complete once `platform generate` has exported it (.xpfm)
set platform_xpfm "$platform_dir/export/$platform_name/$platform_name.xpfm"
set domain_dir    "$platform_dir/$proc_name/$domain_name"

proc remove_platform {} {
    catch {platform remove $::platform_name}
    file delete -force $::platform_dir
}

# ---------------------------------------------------------------------------
# 1. Platform + domain (shared by all applications)
# ---------------------------------------------------------------------------
if {[file exists $platform_xpfm] && [file isdirectory $domain_dir]} {
    kit_log "Platform $platform_name exists, skipping"
} elseif {[file exists $platform_xpfm]} {
    kit_die "platform $platform_name exists but has no domain $domain_name\n  (proc_name/os/domain_name changed since it was created?)\n  Recreate the workspace: xsct [file join $kit_dir create_workspace.tcl] -clean"
} else {
    if {[file exists $platform_dir]} {
        kit_log "Platform $platform_name is incomplete (an earlier run failed), recreating it"
        remove_platform
    }
    kit_log "Creating platform $platform_name from [file tail $xsa_path]"
    set failed [catch {
        platform create -name $platform_name -hw $xsa_path

        # Vitis 2022.2 `domain create` has no -stdin/-stdout: stdio is set on the BSP
        domain create -name $domain_name -proc $proc_name -os $os -arch $arch
        platform generate

        if {$stdio_uart ne ""} {
            platform active $platform_name
            domain active $domain_name
            kit_pin_stdio
            platform generate
        }
    } err]
    # `platform generate` does not always raise an error: check its output too
    if {!$failed && ![file exists $platform_xpfm]} {
        set failed 1
        set err "platform generate did not produce [file tail $platform_xpfm], see the output above"
    }
    if {$failed} {
        kit_log "Platform creation failed, removing the incomplete platform"
        remove_platform
        kit_die "$err\n  Fix the cause and re-run: xsct [file join $kit_dir create_workspace.tcl]"
    }
}

# ---------------------------------------------------------------------------
# 2. Applications
#    The generated linker script stays in the workspace (it is derived from
#    the hardware); the sources live in src_root/<app> and are symlinked in.
# ---------------------------------------------------------------------------
set apps [kit_apps]
if {![llength $apps]} {
    kit_log "No applications in $src_root"
    puts "  Create a folder per application, e.g. mkdir [file join $src_root hello]"
    puts "  (an empty folder is seeded from app_template), then re-run this script."
}

# An app is complete once its src/user link exists (the last step below).
# `file type` does not follow the link, so a dangling one still counts.
proc app_complete {app} {
    return [expr {![catch {file type "$::workspace_dir/$app/src/user"}]}]
}

proc remove_app {app} {
    catch {app remove $app}
    # Deletes the src/user symlink, not the sw/src folder it points to
    file delete -force "$::workspace_dir/$app" "$::workspace_dir/${app}_system"
}

proc create_app {app} {
    set app_src "$::src_root/$app"

    app create -name $app -platform $::platform_name -domain $::domain_name \
        -template $::app_template -lang $::app_lang
    app config -name $app -set build-config [string tolower $::build_config]

    set ws_src "$::workspace_dir/$app/src"
    set template_files {}
    foreach f [glob -nocomplain -directory $ws_src *] {
        if {[file tail $f] ni {lscript.ld Xilinx.spec}} { lappend template_files $f }
    }
    if {![llength [glob -nocomplain -directory $app_src *]]} {
        kit_log "Seeding empty $app_src from template '$::app_template'"
        foreach f $template_files { file copy $f $app_src }
    }
    foreach f $template_files { file delete -force $f }

    # A filesystem symlink (not `importsources -soft-link`, which links files
    # one by one): files added to the folder later are picked up by the next build.
    file link -symbolic "$ws_src/user" $app_src
    kit_log "Linked $ws_src/user -> $app_src"
}

set failed_apps {}
foreach app $apps {
    if {[app_complete $app]} {
        kit_log "App $app exists, skipping"
        continue
    }
    if {[file exists "$workspace_dir/$app"]} {
        kit_log "App $app is incomplete (an earlier run failed), recreating it"
        remove_app $app
    }
    kit_log "Creating app $app"
    if {[catch {create_app $app} err]} {
        puts stderr "xsct-kit ERROR: creating app $app failed: $err"
        remove_app $app
        lappend failed_apps $app
    }
}
if {[llength $failed_apps]} {
    kit_die "app creation failed: [join $failed_apps {, }] (removed from the workspace, see the errors above)\n  Fix the cause and re-run: xsct [file join $kit_dir create_workspace.tcl]"
}

kit_log "Workspace ready: $workspace_dir"
if {[llength $apps]} {
    kit_log "Next: xsct tools/xsct-kit/compile_app.tcl <app>   (apps: [join $apps {, }])"
}
