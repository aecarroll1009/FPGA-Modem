#!/usr/bin/env bash
# Regenerates the CORDIC test vectors and runs the self-checking testbench
# under Verilator. Requires Verilator 5.x with --binary support.
#
# Usage:  ./cordic/run_sim.sh  (run from the repo root)
#
# Build output goes to a space-free directory outside the repo, since
# Verilator's generated Makefile cannot build in a path containing spaces
# (this repo's does). Verilator's own compile step still reads sources from
# the repo directly.
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
