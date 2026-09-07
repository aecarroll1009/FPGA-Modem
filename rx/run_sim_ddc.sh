#!/usr/bin/env bash
# Regenerates the DDC-level (fused mixer) test vectors and runs the
# self-checking ddc_frontend testbench under Verilator. Run from the repo
# root:
#
#   ./rx/run_sim_ddc.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_ddc_sim"

python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR"

mkdir -p "$SIM_DIR"

# VARHIDDEN/UNUSEDPARAM/UNUSEDSIGNAL are expected: the testbench feeds
# ddc_params.svh's localparams (which carry fields ddc_frontend doesn't
# consume) into identically-named DUT parameters, and waits on out_valid
# only, not busy.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
    --top-module tb_ddc_frontend \
    -Icordic \
    -I"$VEC_DIR" \
    cordic/cordic_core.sv \
    cordic/nco.sv \
    cordic/mixer_fused.sv \
    rx/ddc_frontend.sv \
    rx/tb_ddc_frontend.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_ddc_frontend

stdbuf -oL "$SIM_DIR/obj_dir/tb_ddc_frontend"
