#!/usr/bin/env bash
# Runs the LTC2308 SPI master against a datasheet-timing ADC model under
# Verilator. Run from the repo root:
#
#   ./de1soc/run_sim_ltc2308.sh
#
# See cordic/run_sim.sh for the Verilator version and space-in-path notes
# that apply equally here.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SIM_DIR="/tmp/fpga_modem_ltc2308_sim"
mkdir -p "$SIM_DIR"

SRC="de1soc/ltc2308_ctrl.sv de1soc/tb_ltc2308_ctrl.sv"

# BLKSEQ: the ADC model's always block uses blocking assignments for its
# bookkeeping variables (conv_ptr, rise_cnt, ...) deliberately, so that
# pending_code is fixed *before* the procedural `repeat (...) @(posedge
# clk)` tCONV wait -- a nonblocking assignment there would still show the
# old value across that wait. adc_dout stays nonblocking throughout, so
# every signal still has exactly one assignment style.
verilator --binary --timing -Wall \
    -Wno-BLKSEQ \
    --top-module tb_ltc2308_ctrl \
    -Ide1soc \
    $SRC \
    --Mdir "$SIM_DIR/obj_dir" \
    -o tb_ltc2308_ctrl

stdbuf -oL "$SIM_DIR/obj_dir/tb_ltc2308_ctrl"
