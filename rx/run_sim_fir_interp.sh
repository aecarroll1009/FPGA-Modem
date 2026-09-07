#!/usr/bin/env bash
# Regenerates the DDC/TX vectors and the FIR coefficient tables, then runs
# the self-checking fir_interpolate testbench under Verilator. Run from the
# repo root:
#
#   ./rx/run_sim_fir_interp.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_fir_interp_sim"

python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR"
python3 rx/gen_fir_coef.py

mkdir -p "$SIM_DIR"

# VARHIDDEN/UNUSEDPARAM are expected: the testbench feeds ddc_params.svh's
# DATA_BITS/ACC_BITS into identically-named DUT parameters; fir_interpolate
# takes the rest (INTERP/N_TAPS/etc.) from fir_interp_coef_table.svh instead.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM \
    --top-module tb_fir_interpolate \
    -Irx \
    -I"$VEC_DIR" \
    rx/fir_interpolate.sv \
    rx/tb_fir_interpolate.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_fir_interpolate

stdbuf -oL "$SIM_DIR/obj_dir/tb_fir_interpolate"
