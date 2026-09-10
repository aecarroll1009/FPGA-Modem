#!/usr/bin/env bash
# Runs the Avalon-MM IQ FIFO testbench. From the repo root:
#
#   ./de1soc/run_sim_egress.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SIM_DIR="/tmp/fpga_modem_egress_sim"
mkdir -p "$SIM_DIR"

# DECLFILENAME: the testbench name does not match the module under test.
verilator --binary --timing -Wall \
    -Wno-DECLFILENAME \
    --top-module tb_iq_avalon_fifo \
    -Ide1soc \
    de1soc/iq_avalon_fifo.sv de1soc/tb_iq_avalon_fifo.sv \
    --Mdir "$SIM_DIR/obj_tb" \
    -o tb_iq_avalon_fifo
stdbuf -oL "$SIM_DIR/obj_tb/tb_iq_avalon_fifo"
