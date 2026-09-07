#!/usr/bin/env bash
# Measures ddc_frontend's sustained clocks-per-sample under Verilator and
# prints the cycle budget every downstream block has to fit inside. Run from
# the repo root:
#
#   ./rx/run_throughput.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_throughput_sim"

# --n 64 because this measures a rate, not correctness -- only the params
# header is needed, not a full stimulus set.
python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR" --n 64

mkdir -p "$SIM_DIR"

# Same waivers as run_sim_ddc.sh, for the same reasons -- see the comment there.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
    --top-module tb_throughput \
    -Icordic \
    -I"$VEC_DIR" \
    cordic/cordic_core.sv \
    cordic/nco.sv \
    cordic/mixer_fused.sv \
    rx/ddc_frontend.sv \
    rx/tb_throughput.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_throughput

stdbuf -oL "$SIM_DIR/obj_dir/tb_throughput"
