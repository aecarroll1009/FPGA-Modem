#!/usr/bin/env bash
# Regenerates the DDC vectors and the FIR coefficient table, then runs the
# self-checking fir_decimate testbench under Verilator. Run from the repo
# root:
#
#   ./rx/run_sim_fir.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_fir_sim"

python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR"
python3 rx/gen_fir_coef.py

mkdir -p "$SIM_DIR"

# UNUSEDPARAM and VARHIDDEN: ddc_params.svh carries the full DDC config,
# including fields fir_decimate doesn't take as parameters (it gets N_TAPS
# etc. from fir_coef_table.svh instead), and the testbench feeds those
# localparams into the DUT's identically-named parameters. Both expected,
# same as the other testbenches in this repo.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM \
    --top-module tb_fir_decimate \
    -Irx \
    -I"$VEC_DIR" \
    rx/fir_decimate.sv \
    rx/tb_fir_decimate.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_fir_decimate

stdbuf -oL "$SIM_DIR/obj_dir/tb_fir_decimate"
