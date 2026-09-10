#!/usr/bin/env bash
# Regenerates the vectors and coefficient tables, then runs the three board
# testbenches: ROM self-test, the negative case, and live ADC. From the repo
# root:
#
#   ./de1soc/run_sim_de1soc.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SIM_DIR="/tmp/fpga_modem_de1soc_sim"

python3 rx/gen_fir_coef.py
python3 de1soc/gen_selftest_rom.py

mkdir -p "$SIM_DIR"

SRC="cordic/cordic_core.sv cordic/nco.sv cordic/mixer_fused.sv
     rx/ddc_frontend.sv rx/fir_decimate.sv rx/rx_top.sv
     de1soc/hex7seg.sv de1soc/ltc2308_ctrl.sv de1soc/ltc2308_model.sv
     de1soc/iq_avalon_fifo.sv
     de1soc/de1soc_core.sv de1soc/tb_de1soc.sv"

# UNUSEDSIGNAL: spare SWs and KEYs are collected into _unused_ok.
# DECLFILENAME: tb_de1soc.sv holds all three board testbenches.
# UNUSEDPARAM: adc_vectors.svh is included file-wide, unused in two builds.
build_and_run () {
    local top="$1"
    verilator --binary --timing -Wall \
        -Wno-UNUSEDSIGNAL -Wno-DECLFILENAME -Wno-UNUSEDPARAM \
        --top-module "$top" \
        -Icordic -Irx -Ide1soc \
        $SRC \
        --Mdir "$SIM_DIR/obj_$top" \
        -o "$top"
    stdbuf -oL "$SIM_DIR/obj_$top/$top"
}

build_and_run tb_de1soc
build_and_run tb_de1soc_negative
build_and_run tb_de1soc_live
