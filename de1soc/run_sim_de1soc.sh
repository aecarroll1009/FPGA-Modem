#!/usr/bin/env bash
# Regenerates the self-test ROM and coefficient tables, then runs the
# DE1-SoC board top level under Verilator -- both the positive case (the
# board reports pass) and the negative one (a corrupted expectation is
# detected). Run from the repo root:
#
#   ./de1soc/run_sim_de1soc.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SIM_DIR="/tmp/fpga_modem_de1soc_sim"

python3 rx/gen_fir_coef.py
python3 de1soc/gen_selftest_rom.py

mkdir -p "$SIM_DIR"

SRC="cordic/cordic_core.sv cordic/nco.sv cordic/mixer_fused.sv
     rx/ddc_frontend.sv rx/fir_decimate.sv rx/rx_top.sv
     de1soc/hex7seg.sv de1soc/DE1_SoC.sv de1soc/tb_de1soc.sv"

# UNUSEDSIGNAL: the board top declares board pins it deliberately does not
# use yet (SW, the spare KEYs, ADC_DOUT); they are collected into an
# explicit _unused_ok term rather than omitted, so the pin assignments stay
# in place for the ADC work.
# DECLFILENAME: tb_de1soc.sv holds both the positive and the negative
# testbench on purpose -- they instantiate the same DUT the same way, and
# splitting them would duplicate that wiring for no benefit.
build_and_run () {
    local top="$1"
    verilator --binary --timing -Wall \
        -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME \
        --top-module "$top" \
        -Icordic -Irx -Ide1soc \
        $SRC \
        --Mdir "$SIM_DIR/obj_$top" \
        -o "$top"
    stdbuf -oL "$SIM_DIR/obj_$top/$top"
}

build_and_run tb_de1soc
build_and_run tb_de1soc_negative
