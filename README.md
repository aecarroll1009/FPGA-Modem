# FPGA SDR Modem

An SDR front end built around a folded CORDIC, targeting a DE1-SoC and a TinyTapeout shuttle.

## Architecture

RX is a digital down-converter: a rotation-mode CORDIC fuses the NCO and mixer, followed by
a decimating FIR. TX mirrors it — an interpolating filter feeds the same CORDIC as an
up-converter. `mixer_fused.sv` takes a `downconvert` port sampled per sample, so one
instance serves both directions. On the DE1-SoC the IQ lands in a FIFO the board's ARM
cores drain over the lightweight FPGA bridge and send as UDP, which GNU Radio reads live.

![RX/TX CORDIC datapath](docs/ddc_duc_datapath.svg)

| block | file | detail |
|---|---|---|
| CORDIC, fused NCO + mixer | `cordic/` | 16 iterations, ±θ per `downconvert`, no DSP blocks |
| Decimating FIR | `rx/fir_decimate.sv` | 63 taps, ÷8, 20 kHz cutoff, 68.7 dB stopband, symmetry-folded to 32 MACs |
| Interpolating FIR | `rx/fir_interpolate.sv` | 63 taps, ×8, polyphase |
| ADC | `de1soc/ltc2308_ctrl.sv` | LTC2308 SPI master, 400 kS/s |
| IQ egress | `de1soc/iq_avalon_fifo.sv` | Avalon-MM FIFO, tuning and rate registers |
| HPS | `hps/iq_streamd.c` | drains the FIFO, sends UDP, `docs/iq_format.md` |
| Host | `host/` | live viewer `rx_qpsk.grc`, capture with `iq_udp.py` |

## Status

RTL is complete and verified bit-exact against a numpy reference model. The DE1-SoC build
closes timing and produces a programmable `.sof`: it digitises CH0, down-converts, and hands
IQ to the HPS, with a self-test mode that checks the whole path without an analog input.
The host picks the LO and the sample rate through the FIFO's registers.

**Nothing has run on hardware** — there is no board on hand, and the HPS side has never
booted. Still missing: an analog front end (bias and anti-alias filter), a TX output device,
and carrier/timing recovery.

## Rate budget

The converter sets the rate. The LTC2308 runs at 400 kS/s rather than its 500 kS/s ceiling,
which only closes against the typical conversion time, not the guaranteed 1.6 µs maximum.
The CORDIC is iterative, so the mixer takes 19 clocks per sample (`./rx/run_throughput.sh`).

| | rate | budget |
|---|---|---|
| Input | 400 kS/s | 19 clocks each → **7.6 MHz minimum clock** |
| Mixer tap | 400 kS/s | 200 kHz of spectrum, 1.6 MB/s to the host |
| FIR tap (÷8) | 50 kS/s | 152 clocks per IQ pair, 32 used by the folded MACs |

`CTRL[0]` picks the tap at run time; full rate is the default. Either way the gigabit link
is under 2% used — the converter is the ceiling, not the wire.

## Synthesis

```
powershell -File syn/run_syn.ps1 [-Top rx_top|tx_top|tt_um_cordic_ddc|DE1_SoC]
```

`syn/build.tcl` generates the project rather than checking it in. The first three tops
false-path their I/O to measure logic only; `DE1_SoC` is pinned out, constrains the ADC
interface from datasheet timing, generates the Platform Designer system from
`syn/soc_system.tcl` first, and produces the `.sof`.

Cyclone V 5CSEMA5F31C6, Quartus Lite 17.0, 50 MHz constraint, slow 1100 mV 85 °C:

| | `rx_top` | `tx_top` | `tt_um_cordic_ddc` | `DE1_SoC` |
|---|---|---|---|---|
| Fmax | 76.22 MHz | 97.22 MHz | 115.58 MHz | 79.03 MHz |
| Setup / hold | +6.880 / +0.226 ns | +9.714 / +0.221 ns | +11.348 / +0.204 ns | +4.698 / +0.221 ns |
| Logic | 395 ALMs | 493 ALMs | 250 ALMs | 1,125 ALMs |
| Registers | 392 | 836 | 247 | 1,122 |
| DSP | 2 | 2 | 0 | 2 |
| Block memory | 8,704 bits | 0 | 0 | 140,032 bits |

Zero negative slack on every build. The two DSP blocks are the filter's multiplier per
rail; the CORDIC uses none. `DE1_SoC` includes the HPS, and most of its memory is the
4096-word IQ FIFO. Its critical path is still the ADC read — `ADC_DOUT` to the sample
register has +4.698 ns against +7.347 inside the FIR. Tightest in the whole design is
+1.730 ns inside the HPS's DDR3 PHY, which is hard IP. Every top raises Quartus's
unassigned-pin critical warning: the first three are unpinned by design, and `DE1_SoC`'s
two are HPS pins Quartus places from the hard block.

## HPS bring-up

The gigabit PHY hangs off the ARM cores, not the fabric, so Ethernet means running Linux.
`syn/soc_system.tcl` builds the Platform Designer system — the HPS, its lightweight bridge,
and an Avalon master wired to the FIFO — and `syn/build.tcl` generates it before synthesis.

1. Write Terasic's prebuilt DE1-SoC Linux image to an SD card and boot it.
2. `quartus_cpf -c syn/output/DE1_SoC.sof soc.rbf`, copy it over, `dd if=soc.rbf of=/dev/fpga0`.
3. `make -C hps`, copy `iq_streamd` over, and run it as root:
   `./iq_streamd --host <pc-address> --lo-hz 85000`
4. On the PC, open `host/rx_qpsk.grc`.

**Never booted.** Three things to settle against real hardware first:

- The FPGA image and the SD card's preloader must agree on the HPS configuration. The safe
  path is rebuilding the preloader from `hps_isw_handoff/` with the SoC EDS, which is not
  installed here; the assumption is that Terasic's stock image matches.
- The DDR3 settings in `syn/soc_system.tcl` are the board's published geometry (1 GB,
  32-bit, 400 MHz) applied over a generic JEDEC preset, not Terasic's GHRD values.
- `HPS_DDR3_RZQ` has no explicit location, so Quartus chose one. Worth checking against
  Terasic's reference pinout before trusting OCT calibration.

## Board bring-up

`SW[0]` picks the mode; both fill the FIFO the HPS drains.

**Low — self-test.** Plays a 512-sample ROM through `rx_top` and compares all 57 outputs
against the reference model. `LEDR[1]` alone lit is pass. The ROM is paced by the
converter's 400 kS/s tick, so the egress path runs at the same rate live capture does. Run
`iq_streamd --rate decimated`, then:

```
python host/iq_udp.py --check-selftest
```

**High — live capture.** The LTC2308 samples CH0 at 400 kS/s; codes map to signed by
inverting the MSB and left-justifying. The host sets the LO and the tap over the bridge.
`HEX3:HEX0` shows the drop count and the FIFO level.

```
python host/iq_udp.py --out build/capture.cf32 --seconds 5
```

| LED | |
|---|---|
| `LEDR[0]`/`[1]`/`[2]` | self-test done / pass / fail |
| `LEDR[3]` | `rx_top` egress overflow |
| `LEDR[4]` | IQ pair dropped before the HPS |
| `LEDR[5]` | ADC sample arrived before the last was taken |
| `LEDR[6]` | live mode |
| `LEDR[7]` | the host has enabled streaming |
| `LEDR[9]` | heartbeat |

`de1soc/run_sim_de1soc.sh` runs three testbenches against `de1soc_core`: self-test, a
negative instance at a wrong `PHASE_INC` where every output must mismatch, and a live-ADC
test that drives a simulated LTC2308 and drains the FIFO over Avalon the way the daemon
does. `DE1_SoC.sv` above it is structural, so the unsimulatable HPS costs no coverage.
`de1soc/gen_selftest_rom.py` regenerates the vectors after a config change.

**Board revision.** The bundled DE1-SoC manual (2014) documents an **AD7928** on those four
pins, with `AJ4` as chip-select rather than CONVST; later revisions carry the LTC2308 this
targets. Pin locations match either way and the converter is one module, but check it
against a physical board.

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
./run_all.sh              # 44 model tests, 13 RTL testbenches, host and HPS software
./run_all.sh --with-ber   # plus the QPSK BER sweep
```

`host/iq_udp.py --self-check` and `make -C hps check` run the software side alone: the
daemon is built against a model of the Avalon slave and its datagrams decoded.

CI runs the same list on every push. Needs verilator, python3, numpy, and a C compiler.

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
