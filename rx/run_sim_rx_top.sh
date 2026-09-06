#!/usr/bin/env bash
# Regenerates the DDC vectors and the FIR coefficient table, then runs the
# self-checking rx_top testbench (the full chain, ADC-rate stimulus in,
# baseband IQ out) under Verilator. Run from the repo root:
#
#   ./rx/run_sim_rx_top.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_rx_top_sim"

python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR"
python3 rx/gen_fir_coef.py

mkdir -p "$SIM_DIR"

# VARHIDDEN, UNUSEDPARAM, UNUSEDSIGNAL: same as rx/run_sim_ddc.sh -- the
# testbench feeds ddc_params.svh's localparams into rx_top's identically
# named parameters, several of which (e.g. decimation-related fields used by
# the FIR but not the mixer) are unused by any one submodule alone.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
    --top-module tb_rx_top \
    -Icordic -Irx \
    -I"$VEC_DIR" \
    cordic/cordic_core.sv \
    cordic/nco.sv \
    cordic/mixer_fused.sv \
    rx/ddc_frontend.sv \
    rx/fir_decimate.sv \
    rx/rx_top.sv \
    rx/tb_rx_top.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_rx_top

stdbuf -oL "$SIM_DIR/obj_dir/tb_rx_top"
