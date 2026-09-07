# Quartus project build: synthesis, fit, and timing analysis.
#
# Run from the repo root via syn/run_syn.ps1, or directly:
#   quartus_sh -t syn/build.tcl [top] [device]
#
# Four tops are buildable and they answer different questions. rx_top is the
# FPGA RX chain. tx_top is the FPGA TX chain. tt_um_cordic_ddc is the unit
# that tapes out, where the mixing direction is a live pin rather than a
# constant -- so it is the build that actually pays for the runtime
# direction rather than folding it away. DE1_SoC is the pinned-out board
# build; see the pinned/RESERVE_ALL_UNUSED_PINS handling below.
#
# Everything it writes lands in syn/output/, which is gitignored -- the project
# is generated from this script rather than checked in, so the file list and
# device cannot drift out of sync with the RTL.

load_package flow

set top    [expr {[llength $argv] > 0 ? [lindex $argv 0] : "rx_top"}]
# Cyclone V SE A5, speed grade 6 -- the DE1-SoC part. Note the board's own
# documentation gives the ordering code 5CSEMA5F31C6N; Quartus rejects the
# trailing N ("Part name is invalid"), so the device name drops it.
# Override by passing a part name as the second argument.
set device [expr {[llength $argv] > 1 ? [lindex $argv 1] : "5CSEMA5F31C6"}]

set here    [file dirname [file normalize [info script]]]
set root    [file dirname $here]
set outdir  [file join $here output]

# The shared datapath, plus whatever each top wraps around it.
set common {
    cordic/cordic_core.sv
    cordic/nco.sv
    cordic/mixer_fused.sv
    rx/ddc_frontend.sv
}
set tops [dict create \
    rx_top            [concat $common {rx/fir_decimate.sv rx/rx_top.sv}] \
    tx_top            [concat $common {rx/fir_interpolate.sv tx/tx_top.sv}] \
    tt_um_cordic_ddc  [concat $common {tt/tt_um_cordic_ddc.sv}] \
    DE1_SoC           [concat $common {rx/fir_decimate.sv rx/rx_top.sv
                                       de1soc/hex7seg.sv de1soc/DE1_SoC.sv}]]

# Only DE1_SoC is a real board build with pinned-out I/O; the others are
# core-datapath builds whose I/O is false-pathed for measurement.
set pinned {DE1_SoC}

if {![dict exists $tops $top]} {
    puts "unknown top '$top' -- expected one of: [dict keys $tops]"
    exit 1
}

file mkdir $outdir
cd $outdir

project_new $top -overwrite

set_global_assignment -name FAMILY "Cyclone V"
set_global_assignment -name DEVICE $device
set_global_assignment -name TOP_LEVEL_ENTITY $top

# cordic_core.sv includes cordic_atan_table.svh, fir_decimate.sv includes
# fir_coef_table.svh, fir_interpolate.sv includes fir_interp_coef_table.svh,
# and DE1_SoC.sv includes selftest_rom.svh, all by bare name.
set_global_assignment -name SEARCH_PATH [file join $root cordic]
set_global_assignment -name SEARCH_PATH [file join $root rx]
set_global_assignment -name SEARCH_PATH [file join $root de1soc]

foreach f [dict get $tops $top] {
    set_global_assignment -name SYSTEMVERILOG_FILE [file join $root $f]
}

set_global_assignment -name SDC_FILE [file join $here $top.sdc]

if {[lsearch -exact $pinned $top] >= 0} {
    # Real board build: constrain the pins this design uses, and make sure
    # every pin it does not use is left alone. Quartus's default for unused
    # pins drives them, and on the DE1-SoC those nets go to SDRAM, the HPS
    # and the audio codec -- driving them would put the FPGA in contention
    # with real devices.
    source [file join $here de1soc_pins.tcl]
    set_global_assignment -name RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"
}

# Let synthesis optimize toward the SDC's actual timing targets rather than
# a generic area/speed tradeoff -- the Fmax numbers this flow reports are
# only meaningful if synthesis was aiming at the constraint being measured.
set_global_assignment -name SYNTH_TIMING_DRIVEN_SYNTHESIS ON

project_close

# project_new leaves the project open under a name; reopen for the flow.
project_open $top

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
puts "BUILD OK top=$top device=$device"
