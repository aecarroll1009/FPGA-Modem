# FPGA SDR Modem

An FPGA-based SDR modem built around a folded CORDIC front-end.

**Architecture.** The receive side is a digital down-converter (DDC): a rotation-mode
CORDIC fuses the NCO and mixer, down-converting RF to baseband, followed by a decimating
FIR. The transmit side mirrors it: an interpolating filter feeds the same CORDIC running as
an up-converter (DUC). `mixer_fused.sv` takes a `downconvert` port sampled per sample, so
one instance serves both directions — on the FPGA each top ties it to a constant and
synthesis folds it away, but a build-time parameter would leave one direction permanently
untestable on silicon, so the chip time-shares one rotator instead. Demodulation and
modulation happen off-chip in GNU Radio via a file-based flowgraph; the FPGA only handles
the rate-critical front end.

![RX/TX CORDIC datapath](docs/ddc_duc_datapath.svg)

**Status.** RX and TX datapaths are complete in RTL and verified bit-exact against a numpy
reference model, with a self-testing DE1-SoC board top and a datasheet-verified LTC2308 SPI
master. Nothing has run on hardware yet: the controller isn't wired into a board top, and
the analog front end and a TX output device are still missing.

## Components

- **CORDIC (rotation mode)** — the shared engine behind both directions: fused NCO + mixer,
  rotating by −θ (RX) or +θ (TX) depending on `downconvert`, same 16 iterations either way.
- **Decimating FIR** (`rx/fir_decimate.sv`) — 63-tap linear-phase lowpass, decimating by 8
  (20 kHz cutoff, 25 kHz decimated Nyquist, 68.7 dB stopband), with the CORDIC's gain
  K ≈ 1.6467 folded into its coefficients. Not a CIC — at ÷8 a CIC saves little and needs a
  compensating FIR anyway. Folds its own symmetry (`h[k] == h[62-k]`) to halve the multiply
  count.
- **Interpolating filter** (`rx/fir_interpolate.sv`) — the TX counterpart, upsampling by 8
  ahead of the CORDIC, same 63 taps but scaled to `decim/K` since the mixer's K now runs
  after it. Realized as a polyphase filter (each output phase reads a stride through the
  taps against the un-stuffed history), not literal zero-stuffing, and not folded — a
  polyphase sub-filter's taps aren't a mirror pair.
- **GNU Radio** — off-chip, file-based, handles demodulation and modulation.

## Rate budget

The sample rate is set by the converter. The DE1-SoC's on-board **LTC2308** runs at
**400 kS/s** here, not its advertised 500 kS/s ceiling — that ceiling only closes against
the *typical* conversion time (1.3 µs), while the guaranteed maximum (1.6 µs) needs a 2.5 µs
period for real margin at 50 MHz. The CORDIC is iterative (`n_iter = 16`), so the mixer is
not one-sample-per-clock; measured sustained throughput is **19.0 clocks per sample**
(`./rx/run_throughput.sh` re-measures this):

| | rate | cycle budget |
|---|---|---|
| Input samples | 400 kS/s | 19 clocks each → **7.6 MHz minimum clock** |
| Mixer outputs | 400 kS/s | one per 19 clocks |
| FIR outputs (÷8) | 50 kS/s | 152 clocks per I/Q output pair |

The FIR's symmetry fold turns 63 taps into 32 MACs per rail: 32 cycles against the
152-clock budget, **21%** rather than the 83% an unfolded design would cost. At 400 kS/s
the datapath needs 7.6 MHz against a 50 MHz oscillator, a 6.6× margin, so the iterative
CORDIC costs nothing here; only a capture rate above ~2.6 MS/s would justify unrolling it
into a pipelined, one-sample-per-clock version.

TX mirrors this: the interpolator produces 8 outputs per baseband sample, one every 19
clocks, sharing the same 152-clock envelope. Its 63 taps split into 8 polyphase sub-filters
of 7–8 taps each — worst case 8 MACs per output, no folding needed.

## Synthesis

`syn/` builds with Quartus. Four tops are buildable:

```
powershell -File syn/run_syn.ps1                          # rx_top, the FPGA RX chain
powershell -File syn/run_syn.ps1 -Top tx_top              # tx_top, the FPGA TX chain
powershell -File syn/run_syn.ps1 -Top tt_um_cordic_ddc    # the unit that tapes out
powershell -File syn/run_syn.ps1 -Top DE1_SoC             # the pinned-out board build
```

The first three false-path their I/O to measure logic only; `DE1_SoC` is the only build with
real pins, producing a programmable `.sof`. `syn/build.tcl` generates the project rather
than checking it in, so the file list can't drift from the RTL. Default device is
`5CSEMA5F31C6` (Quartus rejects the board manual's trailing "N").

Measured on a Cyclone V 5CEBA4F23C7 (speed grade 7), Quartus Lite 17.0, 50 MHz constraint —
predates the move to the DE1-SoC part (speed grade 6), not yet re-measured there:

| | `rx_top` | `tx_top` | `tt_um_cordic_ddc` |
|---|---|---|---|
| Fmax (slow 1100 mV 85 °C) | **69.55 MHz** | **87.05 MHz** | **102.81 MHz** |
| Setup / hold slack | +5.622 / +0.256 ns | +8.513 / +0.259 ns | +10.273 / +0.236 ns |
| Logic | 375 ALMs | 492 ALMs | 251 ALMs |
| Registers | 389 | 841 | 255 |
| DSP blocks | **2** | **2** | **0** |
| Block memory | 8,704 bits | 0 bits | 0 bits |

The tightest Fmax (`rx_top`, 69.55 MHz) is still 9.2× the 7.6 MHz the converter demands. The
CORDIC uses zero DSP blocks (`tt_um_cordic_ddc` proves it in isolation); the 2 DSP blocks
elsewhere are the filter's one multiplier per rail. The decimator's 128-deep×4-copy delay
line maps to M10K (8,704 bits, requiring registered reads — a combinational version cost
4,630 ALMs and half the Fmax); the interpolator's 8-deep shift register stays in
flip-flops. `tx_top`'s extra ~450 registers are mostly the interpolator's state and its
elastic queue to the mixer, and the runtime-direction port itself costs little: `rx_top`
folds it away entirely, and `tt_um_cordic_ddc` adds only +13 ALMs / +80 registers over a
CORDIC-only build. These are FPGA numbers, not ASIC-predictive — ALMs are LUT-based, and
the CORDIC's barrel shifters are cheap in LUTs but expensive in standard cells.

## Board bring-up

`de1soc/` pins out the RX chain on the board's 50 MHz oscillator, self-checking against the
reference model.

**No ADC yet, on purpose.** Datapath, analog front end, and converter interface are three
independent ways to get a wrong answer; this stage plays a 512-sample stimulus ROM through
`rx_top` and compares all 57 outputs against the same reference model the simulation
testbenches use, so a programmed board answers exactly one question: does the synthesized
datapath match the model, on real silicon. Result is readable with no instrumentation:
`LEDR[1]` alone lit is pass, `LEDR[2]` a mismatch, `LEDR[3]` an overflow, `LEDR[9]` a
heartbeat, `HEX3:HEX0` the output/mismatch counts. `de1soc/gen_selftest_rom.py` regenerates
the ROM after any config change. `de1soc/run_sim_de1soc.sh` also builds a negative instance
at a deliberately wrong `PHASE_INC`, so every output should mismatch: 57/57 positive,
57 mismatches negative.

Pin assignments in `syn/de1soc_pins.tcl` come from a hardware-proven Quartus project for
this board. `build.tcl` sets `RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"` for this top,
since Quartus's default of driving unused pins would contend with the DE1-SoC's SDRAM, HPS,
and audio codec.

**Not yet run on hardware.** There is no board on hand; the `DE1_SoC` top has not been
through Quartus or timing-closed.

### The LTC2308 controller

`de1soc/ltc2308_ctrl.sv` is the SPI master, built from datasheet Figure 9 ("short CONVST
pulse"): a 2-clock CONVST pulse, a wait to `cnt == 80` (1.62 µs, past tCONV's 1.6 µs
guaranteed max), then 12 SCK pulses shifting out the result while loading the next
conversion's 6-bit mode word (CH0, single-ended, unipolar, no sleep) — 125 clocks, 2.5 µs,
400 kS/s, every timing constraint clearing its guaranteed maximum. Because the ADC shifts
out the *previous* conversion's result, the first code after reset was never configured and
is discarded. `de1soc/tb_ltc2308_ctrl.sv` models the ADC's SPI slave side and checks SDO
stays stale until tCONV elapses, SDI is stable a full clock before the sampling edge, and
all 23 samples decode bit-exact 125 clocks apart. Run via `./de1soc/run_sim_ltc2308.sh`.

**Not yet wired into a board top.** It's verified against a protocol model, not silicon,
and `DE1_SoC.sv` still plays the ROM rather than live ADC samples.

### What the board still cannot do

- **No DAC.** The TX chain is complete and verified in RTL, but transmitting needs the audio
  codec (audio-band only) or an external part on GPIO.
- **No analog front end.** The LTC2308 is unipolar, 0–4.096 V, so a real signal needs
  mid-scale biasing and an anti-alias filter ahead of it — analog and unavoidable, since the
  decimating FIR can't undo energy that already aliased in at the converter.

## TinyTapeout

The NCO + fused mixer target a TinyTapeout shuttle; the FPGA flow is a prototyping vehicle,
not the deliverable. `tt/tt_um_cordic_ddc.sv` is the wrapper, checked by `./tt/run_sim_tt.sh`
against the same reference vectors the parallel testbench uses.

**The FIR is out of scope for silicon.** A 63-tap filter needs a 63-deep × 17-bit delay
line, over a thousand flip-flops, larger than this whole design, so it stays on the FPGA or
host. What tapes out is the CORDIC that's simultaneously the NCO and mixer, with `uio_in[5]`
selecting down- or up-convert per sample so RX and TX can interleave through the one
rotator.

**I/O, not area, is the binding constraint.** TinyTapeout gives 8 dedicated in, 8 dedicated
out, 8 bidirectional pins; the parallel core needs 65 input and 36 output bits, so the
interface is byte-serial:

| | bits | bytes |
|---|---|---|
| config: `phase_inc` (once) | 24 | 3 |
| in: `xi`, `xq` | 32 | 4 |
| out: `mix_i`, `mix_q` | 34 | 5 |

Serialisation is nearly free: the CORDIC already spends 19 clocks per sample, and separate
input/output ports let byte traffic overlap it — measured cost is **22 clocks per sample**,
**2.27 MS/s** at 50 MHz.

## Verification

The numpy reference model is `cordic/reference/ddc_reference.py`, with 45 tests in
`cordic/reference/test_ddc_reference.py`.

Two models, one file: `ddc_ideal()` is float64, exact; `DDC.run()` is bit-exact fixed
point, what the RTL must match bit for bit. `--emit-vectors build/ddc_vectors` writes
`$readmemh`-ready hex for stimulus and every intermediate stage, plus a generated
`ddc_params.svh` parameterizing the RTL from the same numbers.

Measured at the default config (`--report`) — 400 kS/s in, 50 kS/s out, LO at 80 kHz:

| | SNR | SFDR | ENOB |
|---|---|---|---|
| NCO alone | 73.9 dB | 85.8 dB | — |
| NCO at an LO that exercises N-bit truncation | — | 84.3 dB | — |
| DDC (fused mixer) | 69.0 dB | 84.0 dB | 11.17 |

The default LO (80 kHz = fs/5) is deliberately not a binary fraction of fs, so the M→N
phase truncation error is a real periodic sequence rather than zero.

### Both mixing directions

Each check pairs with a case that should fail, since nothing else catches a direction bit
that's wired but ignored:

| check | result |
|---|---|
| up-convert vs analytic K·x·e^(+jθ) | 74.2 dB |
| up-convert vs the *down-convert* reference (must fail) | −3.0 dB |
| up-convert then down-convert, vs K²·x | 79.3 dB |

`rx/run_sim_ddc.sh` runs stimulus three ways — all down, all up, alternating — for 24576
bit-exact samples; `tt/run_sim_tt.sh` alternates through the serial interface. Both drive
the direction pin wrong mid-rotation, so latching it, not reading it live, is what's under
test. `test_tx_then_rx_round_trip` chains interpolate → up-convert → down-convert →
decimate on a baseband tone, recovering the original at 79.5 dB SNR.

### FIR and tx_top checks

`rx/run_sim_fir.sh` checks the decimator alone (1017/1017 bit-exact); `rx/run_sim_rx_top.sh`
runs full ADC-rate stimulus through mixer and FIR together, the only test exercising their
handshake. `rx/run_sim_fir_interp.sh` checks the interpolator (4096/4096), after
`test_polyphase_decomposition_matches_zero_stuffed_convolution` confirms in Python that the
polyphase realization equals zero-stuffing then filtering. Both coefficient ROMs are
generated from the reference model's quantized taps (`rx/gen_fir_coef.py`): the decimator's
stores only 32 of 63 taps (folded symmetry), the interpolator's stores all 63 flat plus a
per-phase tap-count table, since 63 taps over 8 phases leaves one phase with 7 instead of 8.

Since the interpolator bursts 8 outputs per baseband sample as fast as its MAC engine
allows while the mixer accepts a new sample only every 19 clocks, `tx_top.sv` bridges them
with an 8-deep elastic queue, draining one entry per rotation and refusing the next baseband
sample until the queue is fully drained. `tx/tb_tx_top.sv` checks 4096/4096 RF-rate outputs
bit-exact, the only test exercising this composition.

### Design facts from the reference model

The fused mixer's output is K·x·e^(−jθ) with K > 1, so the datapath carries one extra guard
bit, sized against the complex envelope (not the per-axis word); the 1/K correction lives
in the FIR/interpolator coefficients instead. The rotation stays exact only while
|xi + j·xq| ≤ ~1.21× full scale — arbitrary IQ (a QPSK corner, two tones in phase) can reach
√2 ≈ 1.41× and clip, which matters most on TX. Only fully-loaded filter outputs are real
outputs: the model uses valid-only convolution, matching hardware.

### NCO widths: M = 24, N = 14

**M = 24** (`phase_bits`, accumulator width) sets frequency resolution: fs/2^M = 0.024 Hz at
400 kS/s. **N = 14** (`phase_trunc_bits`, phase bits reaching the angle path) sets spectral
purity — truncating M→N produces periodic spurs, worst case ~6.02·N = 84 dBc. **`ang_bits`
= 17** is the CORDIC's internal angle register, the floor at `n_iter = 16` where the last
atan entries round to zero. Trimmed from an earlier 32/14/18 for the TinyTapeout area
budget; narrowing `cordic_bits` 20→18 alongside them improved SNR by 1.16 dB.
