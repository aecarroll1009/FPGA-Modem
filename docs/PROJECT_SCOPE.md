# FPGA SDR Modem — Project Scope

An FPGA-based SDR modem built around a folded CORDIC front-end.

**Architecture.** The receive side is a digital down-converter (DDC): a rotation-mode
CORDIC combines the NCO and mixer into one block, down-converting the RF input to
baseband, followed by a decimating CIC/FIR chain producing baseband IQ. The same CORDIC
core runs in reverse as an up-converter (DUC) with an interpolating filter, so RX and TX
share one front-end. An earlier version used a separate NCO, CORDIC, and complex mixer;
folding them together removes the discrete complex multiplier entirely, at the cost of one
extra output bit (see `hardware/DDC_FRONTEND_SCOPE.md`).

**Demod/mod split.** Demodulation and modulation happen off the FPGA, in GNU Radio, via a
file-based flowgraph. The FPGA's job is only the rate-critical front-end; baseband IQ is
handed off to GNU Radio for the actual demod/mod work.

**Status and sequencing.** Everything is developed and verified in simulation first; there
is no physical board access right now. FPGA bring-up on a DE1-SoC, with a HackRF as the RF
front-end, is a later step. The CORDIC core also targets an MPW tapeout.

**Near-term deliverable.** The receive chain end-to-end in simulation — DDC producing an
IQ file, consumed by a GNU Radio flowgraph for demod — verified against the reference
model. The transmit path follows the same pattern once RX is solid.

Current RTL status, verification approach, and design detail live in
`hardware/DDC_FRONTEND_SCOPE.md`, which is kept current; this file is the stable overview.

## Repository layout

```
hardware/   SystemVerilog RTL: cordic/ (the shared CORDIC core and its testbench),
            reference/ (numpy reference model + tests), DDC_FRONTEND_SCOPE.md
docs/       this file, the datapath diagram
build/      scratch: generated test vectors, Verilator build output. Gitignored.
```

Run from the repo root, e.g. `./hardware/cordic/run_sim.sh`,
`python hardware/reference/test_ddc_reference.py`.
