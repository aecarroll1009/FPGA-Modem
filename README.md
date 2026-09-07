# FPGA SDR Modem

An SDR front end built around a folded CORDIC, targeting a DE1-SoC and a TinyTapeout shuttle.

## Architecture

RX is a digital down-converter: a rotation-mode CORDIC fuses the NCO and mixer, followed by
a decimating FIR. TX mirrors it — an interpolating filter feeds the same CORDIC as an
up-converter. `mixer_fused.sv` takes a `downconvert` port sampled per sample, so one
instance serves both directions. On the DE1-SoC the decimated IQ leaves over a UART; a host
script captures it to a file for GNU Radio.

![RX/TX CORDIC datapath](docs/ddc_duc_datapath.svg)

| block | file | detail |
|---|---|---|
| CORDIC, fused NCO + mixer | `cordic/` | 16 iterations, ±θ per `downconvert`, no DSP blocks |
| Decimating FIR | `rx/fir_decimate.sv` | 63 taps, ÷8, 20 kHz cutoff, 68.7 dB stopband, symmetry-folded to 32 MACs |
| Interpolating FIR | `rx/fir_interpolate.sv` | 63 taps, ×8, polyphase |
| ADC | `de1soc/ltc2308_ctrl.sv` | LTC2308 SPI master, 400 kS/s |
| IQ egress | `de1soc/{iq_framer,byte_fifo,uart_tx}.sv` | 2.5 Mbaud framed stream, `docs/iq_format.md` |
| Host | `host/` | capture to complex64, view in `rx_qpsk.grc` |

## Status

RTL is complete and verified bit-exact against a numpy reference model. The DE1-SoC build
closes timing and produces a programmable `.sof`: it digitises CH0, down-converts, decimates,
and streams IQ to a host, with a self-test mode that checks the whole path without an analog
input.

**Nothing has run on hardware** — there is no board on hand. Still missing: an analog front
end (bias and anti-alias filter), a TX output device, and carrier/timing recovery.

## Rate budget

The converter sets the rate. The LTC2308 runs at 400 kS/s rather than its 500 kS/s ceiling,
which only closes against the typical conversion time, not the guaranteed 1.6 µs maximum.
The CORDIC is iterative, so the mixer takes 19 clocks per sample (`./rx/run_throughput.sh`).

| | rate | budget |
|---|---|---|
| Input | 400 kS/s | 19 clocks each → **7.6 MHz minimum clock** |
| FIR output (÷8) | 50 kS/s | 152 clocks per IQ pair, 32 used by the folded MACs |

## Synthesis

```
powershell -File syn/run_syn.ps1 [-Top rx_top|tx_top|tt_um_cordic_ddc|DE1_SoC]
```

`syn/build.tcl` generates the project rather than checking it in. The first three tops
false-path their I/O to measure logic only; `DE1_SoC` is pinned out, constrains the ADC
interface from datasheet timing, and produces the `.sof`.

Cyclone V 5CSEMA5F31C6, Quartus Lite 17.0, 50 MHz constraint, slow 1100 mV 85 °C:

| | `rx_top` | `tx_top` | `tt_um_cordic_ddc` | `DE1_SoC` |
|---|---|---|---|---|
| Fmax | 76.03 MHz | 97.22 MHz | 115.58 MHz | 78.39 MHz |
| Setup / hold | +6.848 / +0.221 ns | +9.714 / +0.221 ns | +11.348 / +0.204 ns | +4.520 / +0.221 ns |
| Logic | 375 ALMs | 493 ALMs | 250 ALMs | 900 ALMs |
| Registers | 373 | 836 | 247 | 620 |
| DSP | 2 | 2 | 0 | 2 |
| Block memory | 8,704 bits | 0 | 0 | 8,960 bits |

Zero critical warnings and zero negative slack on every build. The two DSP blocks are the
filter's multiplier per rail; the CORDIC uses none. `DE1_SoC`'s critical path is the ADC
read, not the datapath — the LTC2308's 12.5 ns SDO delay consumes most of one 20 ns clock.

## Board bring-up

`SW[0]` picks the mode. Both stream IQ out `GPIO_0[0]`.

**Low — self-test.** Plays a 512-sample ROM through `rx_top` and compares all 57 outputs
against the reference model. `LEDR[1]` alone lit is pass. The ROM is paced by the
converter's 400 kS/s tick, so the egress path runs at the same rate live capture does.

```
python host/capture_iq.py --port COM4 --check-selftest
```

**High — live capture.** The LTC2308 samples CH0 at 400 kS/s; codes map to signed by
inverting the MSB and left-justifying. `HEX3:HEX0` shows the frame counter.

```
python host/capture_iq.py --port COM4 --seconds 5 --out build/capture.cf32
```

| LED | |
|---|---|
| `LEDR[0]`/`[1]`/`[2]` | self-test done / pass / fail |
| `LEDR[3]` | `rx_top` egress overflow |
| `LEDR[4]` | IQ pair dropped before the UART |
| `LEDR[5]` | ADC sample arrived before the last was taken |
| `LEDR[6]` | live mode |
| `LEDR[9]` | heartbeat |

`de1soc/run_sim_de1soc.sh` runs three testbenches: self-test, a negative instance at a wrong
`PHASE_INC` where every output must mismatch, and a live-ADC test that drives a simulated
LTC2308 and decodes `UART_TX` — the only test covering the whole board path as one piece.
`de1soc/gen_selftest_rom.py` regenerates the vectors after a config change.

**Board revision.** The bundled DE1-SoC manual (2014) documents an **AD7928** on those four
pins, with `AJ4` as chip-select rather than CONVST; later revisions carry the LTC2308 this
targets. Pin locations match either way and the converter is one module, but check it
against a physical board.

## IQ egress

2.5 Mbaud 8N1 (50 MHz ÷ 20, exact), 82% utilised. Frames are a 4-byte magic, a 16-bit
counter, then 64 IQ pairs as big-endian `int16`. Format and wiring: `docs/iq_format.md`.
The host decoder runs without hardware:

```
python host/capture_iq.py --self-check
```

## TinyTapeout

The NCO + fused mixer target a shuttle; `tt/tt_um_cordic_ddc.sv` is the wrapper. The FIR
stays off-chip — its 63-tap delay line is larger than the rest of the design.

**In progress, not submitted.** RTL and verification are done; packaging (cocotb tests,
`info.yaml`, an OpenLane2 run for the tile count) is not.

TinyTapeout gives 24 pins against the core's 65 input and 36 output bits, so the interface
is byte-serial: 3 config bytes, 4 in, 5 out. Byte traffic overlaps the CORDIC's 19-clock
rotation, costing 22 clocks per sample — 2.27 MS/s at 50 MHz.

## Verification

```
./run_all.sh              # 45 model tests, 15 RTL testbenches, the host decoder
./run_all.sh --with-ber   # plus the QPSK BER sweep
```

CI runs the same list on every push. Needs verilator, python3, numpy.

`cordic/reference/ddc_reference.py` is the authority: `ddc_ideal()` is float64,
`DDC.run()` is bit-exact fixed point that the RTL must match. `--emit-vectors` writes
`$readmemh` hex and a `ddc_params.svh` that parameterises the RTL from the same numbers.

| | SNR | SFDR | ENOB |
|---|---|---|---|
| NCO alone | 73.9 dB | 85.8 dB | — |
| DDC (fused mixer) | 69.0 dB | 84.0 dB | 11.17 |

Checks pair with cases that must fail, since nothing else catches a direction bit that is
wired but ignored: up-convert scores 74.2 dB against the analytic rotation and −3.0 dB
against the down-convert reference. `rx/run_sim_ddc.sh` runs 24576 samples down, up, and
alternating, driving the direction pin wrong mid-rotation.

### BER

`sim/ber_awgn.py` closes the loop: QPSK → `tx_stage()` → AWGN/CFO/timing channel →
`run()` → slicer → BER.

![BER vs Eb/N0](docs/ber_curve.svg)

The curve sits ~7 dB right of theory (1.07e-3 at 14 dB, theory 6.8 dB), from holding symbols
as an unshaped rectangular pulse instead of a matched filter. At 20 dB, a half-symbol timing
offset costs 6.8e-2, while any nonzero carrier offset drives BER to 0.5 — the case for the
carrier recovery the chain lacks.
