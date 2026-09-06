#!/usr/bin/env bash
# Checks the TinyTapeout wrapper's byte-serial interface against the same
# reference vectors the parallel testbench uses, so the serialisation is
# verified rather than assumed. Run from the repo root:
#
#   ./tt/run_sim_tt.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

VEC_DIR="build/ddc_vectors"
SIM_DIR="/tmp/fpga_modem_tt_sim"

python3 cordic/reference/ddc_reference.py --mix-arch fused --emit-vectors "$VEC_DIR"

mkdir -p "$SIM_DIR"

# Same waivers as run_sim_ddc.sh, plus:
# UNUSEDSIGNAL also covers ena and uio_in[7:5], which TinyTapeout requires in
# the port list but this design has no use for.
verilator --binary --timing -Wall \
    -Wno-VARHIDDEN -Wno-UNUSEDPARAM -Wno-UNUSEDSIGNAL \
    --top-module tb_tt_um_cordic_ddc \
    -Icordic \
    -I"$VEC_DIR" \
    cordic/cordic_core.sv \
    cordic/nco.sv \
    cordic/mixer_fused.sv \
    rx/ddc_frontend.sv \
    tt/tt_um_cordic_ddc.sv \
    tt/tb_tt_um_cordic_ddc.sv \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_tt_um_cordic_ddc

stdbuf -oL "$SIM_DIR/obj_dir/tb_tt_um_cordic_ddc"
