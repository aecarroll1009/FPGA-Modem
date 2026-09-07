#!/usr/bin/env bash
# Runs every check in the project, the same list CI runs.
#
#   ./run_all.sh              everything but the BER sweep (about a minute)
#   ./run_all.sh --with-ber   plus the QPSK BER sweep (several minutes)
#
# Needs verilator, python3, numpy. Synthesis is separate, see syn/run_syn.ps1.
set -euo pipefail

cd "$(git rev-parse --show-toplevel)"

WITH_BER=0
if [ "${1:-}" = "--with-ber" ]; then
    WITH_BER=1
fi

pass=0
step () {
    printf '\n==== %s ====\n' "$1"
    shift
    "$@"
    pass=$((pass + 1))
}

step "reference model unit tests"      python3 cordic/reference/test_ddc_reference.py
step "CORDIC core"                     bash cordic/run_sim.sh
step "DDC front end, both directions"  bash rx/run_sim_ddc.sh
step "decimating FIR"                  bash rx/run_sim_fir.sh
step "interpolating FIR"               bash rx/run_sim_fir_interp.sh
step "RX top"                          bash rx/run_sim_rx_top.sh
step "TX top"                          bash tx/run_sim_tx_top.sh
step "TinyTapeout wrapper"             bash tt/run_sim_tt.sh
step "LTC2308 SPI master"              bash de1soc/run_sim_ltc2308.sh
step "UART, FIFO, and IQ framer"       bash de1soc/run_sim_uart.sh
step "DE1-SoC board top"               bash de1soc/run_sim_de1soc.sh
step "host IQ decoder"                 python3 host/capture_iq.py --self-check
step "sustained throughput"            bash rx/run_throughput.sh

if [ "$WITH_BER" = "1" ]; then
    step "QPSK BER over AWGN" python3 sim/ber_awgn.py --skip-robustness
fi

printf '\n==== %d/%d STEPS PASSED ====\n' "$pass" "$pass"
