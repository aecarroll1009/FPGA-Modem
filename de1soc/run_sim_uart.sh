#!/usr/bin/env bash
# Runs the UART, byte FIFO, and IQ framer testbenches. From the repo root:
#
#   ./de1soc/run_sim_uart.sh
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

SIM_DIR="/tmp/fpga_modem_uart_sim"
mkdir -p "$SIM_DIR"

build_and_run () {
    local top="$1"
    shift
    verilator --binary --timing -Wall \
        -Wno-DECLFILENAME \
        --top-module "$top" \
        "$@" \
        --Mdir "$SIM_DIR/obj_$top" \
        -o "$top"
    stdbuf -oL "$SIM_DIR/obj_$top/$top"
}

build_and_run tb_uart_tx   de1soc/uart_tx.sv    de1soc/tb_uart_tx.sv
build_and_run tb_byte_fifo de1soc/byte_fifo.sv  de1soc/tb_byte_fifo.sv
build_and_run tb_iq_framer de1soc/iq_framer.sv  de1soc/tb_iq_framer.sv
