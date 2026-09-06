#!/usr/bin/env bash
# Regenerates the DDC/TX vectors and the FIR coefficient tables, then runs
# the self-checking tx_top testbench (the full TX chain, baseband-rate
# stimulus in, RF-rate IQ out) under Verilator. Run from the repo root:
#
#   ./tx/run_sim_tx_top.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_tx_top_sim"

python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR"
python3 rx/gen_fir_coef.py

mkdir -p "$SIM_DIR"

# VARHIDDEN, UNUSEDPARAM, UNUSEDSIGNAL: same reasoning as rx/run_sim_rx_top.sh
# -- the testbench feeds ddc_params.svh's localparams into tx_top's
# identically named parameters, several of which are unused by any one
# submodule alone.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
    --top-module tb_tx_top \
    -Icordic -Irx \
    -I"$VEC_DIR" \
    cordic/cordic_core.sv \
    cordic/nco.sv \
    cordic/mixer_fused.sv \
    rx/ddc_frontend.sv \
    rx/fir_interpolate.sv \
    tx/tx_top.sv \
    tx/tb_tx_top.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_tx_top

stdbuf -oL "$SIM_DIR/obj_dir/tb_tx_top"
