#!/usr/bin/env bash
# Regenerates the CORDIC test vectors and runs the self-checking testbench
# under Verilator. Run from the repo root:
#
#   ./cordic/run_sim.sh
#
# Requires Verilator with --binary support (5.x). If the installed version
# is too old for --binary, replace the verilator invocation below with a
# --cc build plus a small C++ harness calling eval() in a loop.
#
# Verilator's generated Makefile refuses to build in a directory containing
# spaces, and this repo's path has one ("FPGA Modem"), so the actual build
# output goes to a space-free directory outside the repo. Verilator's own
# SystemVerilog compile step reads sources from the repo fine; only the
# downstream C++ build needs to live elsewhere.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/cordic_vectors"
SIM_DIR="/tmp/fpga_modem_cordic_sim"

python3 cordic/gen_cordic_vectors.py --out "$VEC_DIR"

NUM_VECTORS=$(python3 -c "import json; print(json.load(open('$VEC_DIR/manifest.json'))['n_vectors'])")

mkdir -p "$SIM_DIR"

verilator --binary --timing -Wall \
    --top-module tb_cordic_core \
    -Icordic \
    -GNUM_VECTORS="$NUM_VECTORS" \
    cordic/cordic_core.sv \
    cordic/tb_cordic_core.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_cordic_core

# Line-buffered: piped stdout is fully buffered by default, and a hung
# simulation would otherwise show no output at all instead of stopping
# partway through the vector list.
stdbuf -oL "$SIM_DIR/obj_dir/tb_cordic_core"
