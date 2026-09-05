# Quartus project build for rx_top: synthesis, fit, and timing analysis.
#
# Run from the repo root via syn/run_syn.ps1, or directly:
#   quartus_sh -t syn/build.tcl [device]
#
# Everything it writes lands in syn/output/, which is gitignored -- the project
# is generated from this script rather than checked in, so the file list and
# device cannot drift out of sync with the RTL.

load_package flow

# Cyclone V E, speed grade 7 -- the DE0-CV part. Chosen as a deliberately
# unexciting default: if the design closes here it closes on the faster grades
# too. Override by passing a part name as the first argument.
set device [expr {[llength $argv] > 0 ? [lindex $argv 0] : "5CEBA4F23C7"}]

set here    [file dirname [file normalize [info script]]]
set root    [file dirname $here]
set outdir  [file join $here output]

file mkdir $outdir
cd $outdir

project_new rx_top -overwrite

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE $device
set_global_assignment -name TOP_LEVEL_ENTITY rx_top

# cordic_core.sv includes cordic_atan_table.svh by bare name.
set_global_assignment -name SEARCH_PATH [file join $root cordic]

foreach f {
    cordic/cordic_core.sv
    cordic/nco.sv
    cordic/mixer_fused.sv
    rx/ddc_frontend.sv
    rx/rx_top.sv
} {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $f]
}

set_global_assignment -name SDC_FILE [file join $here rx_top.sdc]

# Report a violation rather than silently inferring a latch or a soft
# multiplier where the design did not ask for one.
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS ON

project_close

# project_new leaves the project open under a name; reopen for the flow.
project_open rx_top

if {[catch {execute_module -tool map} err]} {
    puts "ANALYSIS/SYNTHESIS FAILED: $err"
    project_close
    exit 1
}
if {[catch {execute_module -tool fit} err]} {
    puts "FITTER FAILED: $err"
    project_close
    exit 1
}
if {[catch {execute_module -tool sta} err]} {
    puts "TIMING ANALYSIS FAILED: $err"
    project_close
    exit 1
}

project_close
puts "BUILD OK device=$device"
