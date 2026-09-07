# FPGA SDR Modem

An FPGA-based SDR modem built around a folded CORDIC front-end.

**Architecture.** The receive side is a digital down-converter (DDC): a rotation-mode
CORDIC combines the NCO and mixer into one block, down-converting the RF input to
baseband, followed by a decimating FIR producing baseband IQ. The transmit side is the
mirror image — an interpolating filter into the same CORDIC running as an up-converter
(DUC).

**Direction is a runtime input, not a build option.** `mixer_fused.sv` takes a
`downconvert` port, sampled per accepted sample, so one instance can serve both
directions and can even interleave them sample by sample. On the FPGA that costs nothing:
each top ties the port to a constant and synthesis folds it away, so a full-duplex build
still instantiates the core twice — a CORDIC is a handful of adders, and duplicating it
beats time-multiplexing two live streams. It matters on silicon, where a parameter would
be frozen at tapeout: the die would do one direction and the other would be untestable.
The trade is that the chip time-shares one rotator, so interleaving RX and TX halves the
per-direction sample rate.

**Demod/mod split.** Demodulation and modulation happen off the FPGA, in GNU Radio, via a
file-based flowgraph. The FPGA's job is only the rate-critical front-end; baseband IQ is
handed off to GNU Radio for the actual demod/mod work.

![RX/TX CORDIC datapath](docs/ddc_duc_datapath.svg)

**Status.** The full RX and TX datapaths exist in RTL and are verified bit-exact against a
numpy reference model, along with a pinned-out, self-testing DE1-SoC board top and a
datasheet-verified LTC2308 SPI master. Nothing has run on hardware — there is no board on
hand — the controller is not yet wired into a board top, and the analog front end and a TX
output device are still missing entirely. *Board bring-up* below says which of those gaps
blocks what.

## Components

- **CORDIC (rotation mode)** — the shared engine behind both directions: fused NCO +
  mixer, rotating by −θ when `downconvert` is high (RX) and by +θ when it is low (TX).
  Both directions run the same 16 iterations through the same adders, so they cost the
  same and neither is a slow path.
- **Decimating FIR** (`rx/fir_decimate.sv`) — the RX-side filter: one 63-tap linear-phase
  lowpass decimating by 8 (20 kHz cutoff against a 25 kHz decimated Nyquist, 68.7 dB
  stopband), with the CORDIC gain K ≈ 1.6467 folded into its coefficients
  rather than spent on a separate scaling stage. It is what prevents aliasing *at the
  decimation step*; aliasing at the converter is a separate problem an analog filter has to
  solve, since by then the damage is already in the samples. Deliberately not a CIC — a CIC earns its
  keep at decimation factors in the tens or hundreds, where its multiplier-free structure
  beats a long FIR. At ÷8 it would save little and cost passband droop that needs a
  compensating FIR afterward anyway. Exploits the filter's own linear-phase symmetry
  (`h[k] == h[62-k]`) to halve the multiply count — see the rate budget below.
- **Interpolating filter** (`rx/fir_interpolate.sv`) — the TX-side counterpart, upsampling
  by 8 ahead of the CORDIC. Same 63 taps as the decimator, but scaled to a DC gain of
  `decim/K` rather than `1/K`: zero-stuffing on its own cuts the amplitude by `1/decim`,
  and this filter has to put that back on top of pre-cancelling the mixer's K, which now
  runs *after* it instead of before. Realized as a polyphase filter (each of the 8 output
  phases reads a different sub-sampling of the 63 taps directly against the un-stuffed
  input history) rather than literal zero-stuffing, which is exact, not approximate — see
  the rate budget below. Not folded for symmetry the way the decimator is: a polyphase
  sub-filter's taps are an arbitrary stride through the coefficient array, not a mirror
  pair, so there is nothing to fold.
- **GNU Radio** — off-chip, file-based, handles demodulation and modulation.

## Rate budget

The sample rate is set by the converter, not by the logic. The DE1-SoC's on-board ADC is
an **LTC2308**, and this design runs it at **400 kS/s** — not the part's advertised 500
kS/s ceiling, because that ceiling only closes against the LTC2308's *typical* conversion
time (1.3 µs); the datasheet's maximum (1.6 µs) needs a 2.5 µs sample period, i.e. 400
kS/s, to leave real margin at the SPI clock the SCK-generating logic can produce from a 50
MHz oscillator. 400 kS/s is therefore the number the whole chain is budgeted against, and
every rate below is derived from it. (The design was originally written for 2.4 MS/s,
which no converter on this board can reach at all; see *Board bring-up* for what changed.)

The CORDIC is iterative — one rotation per clock, `n_iter = 16` — so the mixer is not a
one-sample-per-clock block. Measured sustained throughput of `ddc_frontend` with
`in_valid` held high is **19.0 clocks per sample**: 16 iterations plus the
`IDLE → WAIT_BUSY → RUN` handshake. Everything downstream is budgeted from that number,
which `./rx/run_throughput.sh` re-measures — rerun it whenever the iteration count or the
mixer handshake changes, since both move every budget below:

| | rate | cycle budget |
|---|---|---|
| Input samples | 400 kS/s (LTC2308, run below its 500 kS/s ceiling) | 19 clocks each → **7.6 MHz minimum clock** |
| Mixer outputs | 400 kS/s | one per 19 clocks |
| FIR outputs (÷8) | 50 kS/s | 152 clocks per I/Q output pair |

Two consequences worth stating up front. First, the FIR's 63 taps fold around their own
symmetry (`h[k] == h[62-k]`) into 32 multiply-accumulate steps per rail — one pre-add
replaces one multiply, exact rather than approximate because the folded pair is only
correct if the taps are precisely palindromic, which `fir_taps_quantized()` enforces at
generation time. Run with one multiplier per rail (both rails computed in parallel, not
time-shared — DSP blocks are abundant on this device, 2 of 87), that is 32 cycles against
the 152-clock budget: **21%**, not the 83% an unfolded, rail-shared design would cost.

Second, the 19 clocks/sample that used to be the binding constraint no longer is. At 400
kS/s the datapath needs 7.6 MHz against a 50 MHz board oscillator — a **6.6× margin** — so
the iterative CORDIC is no longer trading rate for area in any way that costs anything
here. The ratio is still worth keeping in view because it scales linearly: the converter,
not the logic, is what would have to change first, and only if a capture faster than about
2.6 MS/s were ever needed would unrolling the CORDIC into 16 pipeline stages (~16× the
adders, one sample per clock) become the answer.

TX is the mirror image, with the multiply work moved to the *other* side of the mixer: for
every baseband sample accepted, the interpolator must produce 8 outputs, one every 19
clocks (matching the mixer's own consumption rate), so it has the same 152-clock envelope
per baseband sample. Its 63 taps split into 8 polyphase sub-filters of 7 or 8 taps each
(63 is not a multiple of 8, so one phase is one tap short) — worst case 8 MACs per output,
comfortably inside 19 clocks with no folding needed. Unlike the decimator, no new baseband
sample can arrive mid-computation (the interpolator's own `in_ready` stays low until all 8
phases are produced), so there is no address-vs-live-write race to guard against and the
history is a plain 8-deep shift register per rail, not a circular buffer.

## Synthesis

`syn/` builds with Quartus so the rate budget above is checked against a real device
instead of only against simulation. Four tops are buildable, and they answer different
questions:

```
powershell -File syn/run_syn.ps1                          # rx_top, the FPGA RX chain
powershell -File syn/run_syn.ps1 -Top tx_top              # tx_top, the FPGA TX chain
powershell -File syn/run_syn.ps1 -Top tt_um_cordic_ddc    # the unit that tapes out
powershell -File syn/run_syn.ps1 -Top DE1_SoC             # the pinned-out board build
```

The first three are core-datapath builds: their I/O is false-pathed, so what they measure
is the logic and nothing else. `DE1_SoC` is the only one with real pin assignments and the
only one that produces a programmable `.sof` — see *Board bring-up* below.

The project is generated by `syn/build.tcl` rather than checked in, so the file list and
device cannot drift away from the RTL. Everything it writes goes to the gitignored
`syn/output/`. The default device is `5CSEMA5F31C6`, the DE1-SoC part — note the board's
own documentation gives the ordering code `5CSEMA5F31C6N`, and Quartus rejects the
trailing `N` outright ("Part name is invalid").

Measured on a Cyclone V 5CEBA4F23C7 (speed grade 7 — the slow common grade, so the faster
parts only do better), Quartus Lite 17.0, constrained at 50 MHz. These predate the move to
the DE1-SoC part and have not been re-measured on `5CSEMA5F31C6`. Resource counts should
carry over essentially unchanged (same family, same fabric), and Fmax should *improve*,
since the DE1-SoC part is speed grade 6 against this one's 7 — but "should" is not
"measured", so the table stays labelled with the part it was actually taken on:

| | `rx_top` (CORDIC + decimator) | `tx_top` (CORDIC + interpolator) | `tt_um_cordic_ddc` (CORDIC only) |
|---|---|---|---|
| Fmax (slow 1100 mV 85 °C) | **69.55 MHz** | **87.05 MHz** | **102.81 MHz** |
| Setup / hold slack | +5.622 / +0.256 ns | +8.513 / +0.259 ns | +10.273 / +0.236 ns |
| Logic | 375 ALMs | 492 ALMs | 251 ALMs |
| Registers | 389 | 841 | 255 |
| DSP blocks | **2** | **2** | **0** |
| Block memory | 8,704 bits | 0 bits | 0 bits |

Three things worth reading off that table. The rate budget is nowhere near binding on any
build — even `rx_top`'s 69.55 MHz, the tightest of the three, is 9.2× the 7.6 MHz the
converter can actually demand, so the iterative CORDIC remains the right call and the
unrolled version stays unnecessary. The CORDIC itself still spends **no** DSP blocks, because shift-and-add
is the whole point of it — `tt_um_cordic_ddc`, which is CORDIC-only, proves that in
isolation; the 2 DSP blocks in each of the other two builds are entirely the filter's, one
multiplier per rail (see the rate budget above for why 2, not 1, in both directions).

The two filters land in opposite places on block memory for a structural reason, not an
oversight: the decimator's 128-deep×4-copy delay line is large enough that Quartus maps it
onto M10K (8,704 bits), while the interpolator's 8-deep shift register is small enough that
plain flip-flops are simply the right call — there is no threshold being missed, just two
delay lines two orders of magnitude apart in size. `tx_top`'s extra ~450 registers over
`rx_top` are almost entirely the interpolator's own state plus the elastic queue between it
and the mixer (see tx_top.sv's header for why that queue exists), not the coefficient
storage, which at 63 entries × 16 bits is smaller than either delay line.

And the runtime direction is close to free — compare `tt_um_cordic_ddc` against the
CORDIC-only numbers from before the direction became a port (238 ALMs, 175 registers,
102.84 MHz): +13 ALMs, +80 registers, essentially the byte-serial interface, not the
direction bit itself, and Fmax barely moves. In `rx_top` the port is tied to a constant and
folds away entirely, so the FPGA build pays literally nothing for the chip's flexibility.

One synthesis lesson worth stating because it cost a real iteration: the FIR's delay line
is four `logic ... mem[0:127]` arrays read combinationally. The first pass through Quartus
came back at **0 block memory bits**, 4,630 ALMs, and Fmax nearly halved to 51.56 MHz —
Quartus had built the arrays out of plain flip-flops with a 128:1 mux in front, since
combinational reads cannot map onto M10K block RAM. Registering the reads (one pipeline
stage inside the MAC engine) is what produced the 8,704-bit / 375-ALM numbers above; the
data is now available a cycle later, which the 152-clock decimation budget does not
notice. `fir_decimate.sv`'s header documents this exchange.

The FPGA numbers are a *relative* measurement for the ASIC target, not an absolute one:
ALMs are LUT-based and do not predict standard-cell area, and the CORDIC's barrel shifters
are precisely where the two diverge — cheap in LUTs, expensive in cells. A real tile
estimate needs an ASIC flow.

`rx_top`/`tx_top`'s egress is a stub — a valid/ready IQ stream with the I/O false-pathed in
`syn/rx_top.sdc` — so the table above is core-datapath numbers by construction. The
`DE1_SoC` build is where real pins and real I/O standards enter.

## Board bring-up

`de1soc/` is the DE1-SoC build: the RX chain pinned out, running on the board's own 50 MHz
oscillator, checking itself against the reference model.

**It contains no ADC on purpose.** The datapath, the analog front end and the converter
interface are three independent ways for a board to give a wrong answer, and wiring them up
together means a bad result has three suspects. So the first bring-up stage plays a
512-sample stimulus ROM through `rx_top` and compares all 57 decimated outputs against the
expectations the *same* reference model produced for the simulation testbenches. A
programmed board therefore answers exactly one question — does the synthesized datapath
produce, on real silicon, the bits the model says it should — and when the LTC2308
controller lands, the datapath is already ruled out.

The result is readable off the board with no instrumentation: `LEDR[1]` alone lit is a
pass, `LEDR[2]` is a mismatch, `LEDR[3]` is an overflow that should never happen, `LEDR[9]`
is a heartbeat so a dead clock is distinguishable from a design that produced nothing, and
`HEX3:HEX0` show the outputs-received and mismatch counts in hex. `de1soc/gen_selftest_rom.py`
regenerates the ROM; it must be re-run after any config change, since the expectations are
config-specific.

`de1soc/run_sim_de1soc.sh` verifies the wrapper before it is ever programmed, and it runs
the negative case too: a second instance built at a deliberately wrong `PHASE_INC`, so
every output legitimately mismatches and a comparison that silently compared nothing would
be caught. Overriding the parameter rather than forcing the ROM's contents matters — it
corrupts the design's *input* instead of reaching inside it, so what is under test stays
the real comparison path. Both pass: 57/57 outputs, 0 mismatches positive, 57 mismatches
negative.

The pin assignments in `syn/de1soc_pins.tcl` (71 locations plus their I/O standards) are
lifted from a hardware-proven Quartus project for this exact board rather than transcribed
from the manual. `build.tcl` also sets `RESERVE_ALL_UNUSED_PINS "AS INPUT TRI-STATED"` for
this top specifically: Quartus's default is to *drive* unused pins, and on the DE1-SoC
those nets run to SDRAM, the HPS and the audio codec, so the default would put the FPGA in
contention with real devices.

**Not yet run on hardware.** There is no board on hand. Everything above is verified in
simulation only — the `DE1_SoC` top has not yet been taken through Quartus or timing-closed,
let alone programmed — and nothing here is claimed as a hardware result.

### The LTC2308 controller

`de1soc/ltc2308_ctrl.sv` is the SPI master, built directly from the datasheet (Figure 9,
"short CONVST pulse"): CONVST pulses for 2 clocks (40 ns, against a 20 ns minimum), waits
until `cnt` reaches 80 — 81 clocks (1.62 µs) after CONVST rose, since `cnt` starts at 0 on
the first clock — before reading the already-valid MSB, then drives 12 SCK pulses that
shift out the remaining 11 bits while loading the next conversion's 6-bit mode word
(channel 0, single-ended, unipolar, no sleep). One 125-clock period is 2.5 µs, i.e. 400
kS/s. Every datasheet timing constraint closes against its own guaranteed maximum, not a
typical value, but not with uniform margin — tCONV (1.6 µs guaranteed max) clears by only
20 ns, the tightest constraint in the design, while tACQ clears by 2.7×, tWLCONVST by 6×,
and tHCONVST by over 20×; the full derivation is in the module's comments.

Because "between conversions... data from the previous conversion is shifted out on SDO"
(the datasheet's own words), the code returned during any given transfer was actually
configured by the *previous* transfer's mode word — so the very first code after reset was
converted before this master ever sent a mode word at all, and is discarded rather than
trusted. `de1soc/tb_ltc2308_ctrl.sv` models the ADC's SPI slave side from the same timing
diagram, holding SDO at a stale value until its own tCONV delay elapses (so a wait shortened
back to the 1.3 µs typical would be caught) and checking SDI's value a full clock before the
edge that samples it, not merely as of that edge (so a setup violation is caught, not just a
value mismatch). Over 23 back-to-back samples it checks: the first is correctly discarded,
every later one decodes bit-exact to what the model queued for it, the mode word is right on
every single transfer, SDI setup holds on every bit, and samples land exactly 125 clocks
apart. Run via `./de1soc/run_sim_ltc2308.sh`.

**Not yet wired into a board top.** The controller is verified against a protocol model,
not against silicon, and it is not yet instantiated in `DE1_SoC.sv` — that top still plays
the on-chip stimulus ROM described above. Feeding it live ADC samples means deciding how to
get baseband IQ off a board with no chosen physical link yet (the same open question
`rx_top`'s stub egress already flags), so the controller and the self-test datapath are
kept as two independently-verified pieces until that decision is made.

### What the board still cannot do

Two gaps, stated plainly because they bound what this project currently is:

- **No DAC, so TX cannot leave the board.** The DE1-SoC has no general-purpose DAC. The TX
  chain is complete and verified in RTL, but transmitting needs either the audio codec
  (band-limited to audio) or an external part on the GPIO header.
- **No analog front end.** The LTC2308 is unipolar, 0–4.096 V, so a real signal needs
  biasing to mid-scale and an anti-alias filter ahead of it. That anti-alias filter is
  **analog and unavoidable** — the decimating FIR prevents aliasing at the *decimation*
  step, which happens after sampling, and can do nothing about energy that already folded
  into band at the converter.

When the converter does land, its 12 bits are left-justified into the 16-bit datapath
rather than zero-extended: the model's own width sweep puts 16-bit at 68.9 dB SNR against
10-bit at 43.5 dB, and right-justifying a 12-bit sample would throw away the top of that
range for nothing.

## TinyTapeout

The NCO + fused mixer are meant for a TinyTapeout shuttle; the FPGA flow above is a
prototyping and verification vehicle, not the deliverable. `tt/tt_um_cordic_ddc.sv` is the
wrapper, checked by `./tt/run_sim_tt.sh` against the same reference vectors the parallel
testbench uses, so the serialisation is verified rather than assumed.

**The FIR is not in scope for silicon.** A 63-tap filter needs a 63-deep × 17-bit sample
delay line — over a thousand flip-flops, larger than this entire design — plus coefficient
storage. It stays on the FPGA or the host. What tapes out is the part that is actually
novel: a CORDIC that is simultaneously the NCO and the mixer.

**The chip does both directions.** `uio_in[5]` selects down- or up-convert, latched with
the last byte of each sample frame, so RX and TX rotations can interleave through the one
rotator. This is the reason the direction is a port: on an FPGA a parameter is free to
change, but a parameter reaching silicon means half the design is unreachable forever.
The wrapper testbench alternates direction every sample and drives the pin to the *wrong*
value the instant each byte is taken, so only a capture on the correct edge passes.

**I/O is the binding constraint, not area.** TinyTapeout provides 8 dedicated inputs, 8
dedicated outputs and 8 bidirectional pins. The parallel core needs 65 input and 36 output
bits, so it cannot be pinned out directly and the interface is byte-serial:

| | bits | bytes |
|---|---|---|
| config: `phase_inc` (once, not per sample) | 24 | 3 |
| in: `xi`, `xq` | 32 | 4 |
| out: `mix_i`, `mix_q` | 34 | 5 |

Serialisation is *nearly* free, because the iterative CORDIC already spends 19 clocks per
sample and the byte traffic hides inside that. Input and output use separate ports, so
they overlap; measured cost is **22 clocks per sample against the core's 19**, i.e. three
clocks of overhead, not nine. `i_ready` is deliberately not gated on the output frame —
doing so serialises the two directions and costs about five clocks a sample.

At a 50 MHz TinyTapeout clock, 22 clocks/sample is **2.27 MS/s**. Getting to ~20 would
need an input holding register so the next sample can accumulate during a rotation, which
costs 32 flip-flops — deliberately not spent, since area is what binds here.

## Verification

The numpy reference model is `cordic/reference/ddc_reference.py`, with 45 tests in
`cordic/reference/test_ddc_reference.py` (`python cordic/reference/test_ddc_reference.py`).

It is two models in one file. `ddc_ideal()` is float64, exact: what the answer should be.
`DDC.run()` is bit-exact fixed point: what the RTL must produce. RTL is checked against
the fixed-point model bit for bit, with no tolerance to hide in. The fixed-point model is
checked against the ideal one in SNR/SFDR, which is a question of whether the chosen
widths are good enough, not a correctness question.

`--emit-vectors build/ddc_vectors` writes `$readmemh`-ready hex for the stimulus and
every intermediate stage (NCO, mixer, output), plus a generated `ddc_params.svh` so the
RTL is parameterised from the same numbers. The testbench reads these values rather than
recomputing the reference, so a sign error shared by both implementations cannot hide.

Measured at the default 16-bit config (`--report`) — 400 kS/s in, 50 kS/s out, LO at
80 kHz:

| | SNR | SFDR | ENOB |
|---|---|---|---|
| NCO alone | 73.9 dB | 85.8 dB | — |
| NCO at an LO that exercises the N-bit truncation | — | 84.3 dB | — |
| DDC (fused mixer) | 69.0 dB | 84.0 dB | 11.17 |

The default LO is deliberately **not** a binary fraction of the sample rate. 80 kHz on
400 kS/s is fs/5, so its frequency control word is not a multiple of 2^(M−N) and the M→N
phase truncation error is a long-period sequence rather than identically zero. fs/4 or fs/8
would divide the accumulator exactly, exercise no truncation at all, and report flattering
numbers that no real LO would reproduce. The cost of that choice is visible in the table —
these figures are lower than the ones this project used to quote at a benign LO, and that
is the point: 73.9 dB is what the NCO does at an LO you would actually ask for, and
`test_phase_truncation_only_bites_when_the_fcw_exercises_it` builds *both* FCWs and
measures the gap (96.4 dB benign vs 84.3 dB truncating, against a ~6.02·N = 84.3 dB bound)
so the difference is a documented property rather than a surprise.

### Both mixing directions

Because the direction is a port, one build has to prove both. Nothing here would catch a
direction bit that was wired but ignored, so each check is paired with the case that
should fail:

| check | result |
|---|---|
| up-convert vs analytic K·x·e^(+jθ) | 74.2 dB |
| up-convert vs the *down-convert* reference (must fail) | −3.0 dB |
| up-convert then down-convert, vs K²·x | 79.3 dB |
| `mixer_fused.sv` declares `downconvert` as a port, not a parameter | asserted in source |

On the RTL side `rx/run_sim_ddc.sh` runs the stimulus three times — all down, all up, and
alternating every sample — for 24576 bit-exact samples, and `tt/run_sim_tt.sh` alternates
through the serial interface. Both drive the direction pin to the wrong value while the
rotation is running, so a design that read the live pin instead of latching it with the
sample fails every case rather than passing by luck.

On silicon, TX only ever covers the mixer — the interpolator is FPGA/host scope, same as
the decimator — but both the reference model and the FPGA RTL now have a complete TX chain.
`test_tx_then_rx_round_trip` interpolates and up-converts a baseband tone, treats the
result as a captured RF signal, then down-converts and decimates it back with the RX chain,
recovering the original at 79.5 dB SNR. That one test exercises the interpolator, both
mixer directions, and the decimator together, so a wrong sign or a wrong gain anywhere in
the chain would show up there even if it happened to cancel in a narrower test.

### The decimating FIR

`rx/fir_decimate.sv` is checked two ways. `rx/run_sim_fir.sh` feeds `mix_i`/`mix_q` from
the same vectors directly into the FIR and checks all 1017 outputs bit-exact against
`fir_decimate()` — the filter in isolation, at the mixer's real 19-clocks-per-sample
cadence (faster spacing would violate the MAC engine's one-run-at-a-time assumption, which
is asserted in simulation rather than silently handled, since the real system never
produces samples that fast). `rx/run_sim_rx_top.sh` then runs ADC-rate stimulus through the
whole chain — mixer and FIR together — because neither of the other testbenches exercises
the handshake between them; this is the one that would catch a `valid`/data timing mismatch
neither block's own test could see. Both pass 1017/1017.

The coefficient ROM is generated, not hand-copied: `rx/gen_fir_coef.py` reads the same
quantized taps the reference model computes and writes `rx/fir_coef_table.svh`, checked
into the repo alongside the RTL (the same pattern `cordic/cordic_atan_table.svh` uses).
Since the RTL folds the filter around its own symmetry, only the first 32 of the 63 taps
are needed; the generator re-checks the exact-symmetry property before halving the table,
independently of the check the reference model already applies when it quantizes them.

### The TX interpolator

`rx/fir_interpolate.sv` is a polyphase realization, not literal zero-stuffing, so it has to
be checked against something proving the two are actually equal, not just plausible.
`test_polyphase_decomposition_matches_zero_stuffed_convolution` builds the polyphase answer
by hand in Python and checks it bit-for-bit against `fir_interpolate()`'s zero-stuffed
reference before the RTL is ever trusted against either one — this is also where an earlier
mistake was caught: `fir_interpolate()` originally used `'valid'`-mode convolution, which
offsets the correspondence by `n_taps-1` against the polyphase formula's plain
`y[n*interp+p] = sum_k coef[p+k*interp]*x[n-k]`; switching to causal, zero-history
convolution (matching what a real reset filter does, and matching that the interpolator —
unlike the decimator — has no window-fill period to wait out) fixed it. `rx/run_sim_fir_interp.sh`
then checks the RTL itself: 4096/4096 outputs bit-exact against `interp_i.hex`/`interp_q.hex`.

The coefficient ROM is generated the same way the decimator's is, but flat rather than
folded — a polyphase sub-filter's taps are an arbitrary stride through the array, not a
mirror pair, so there is no symmetry to exploit — and paired with a per-phase tap-count
table (`FIR_INTERP_PHASE_LEN`), since 63 taps over 8 phases leaves one phase with 7 instead
of 8: the RTL reads that count rather than assuming every phase is the same length.

### `tx_top`: closing the loop between two very different paces

The interpolator produces its 8 outputs for one baseband sample as fast as its own MAC
engine allows — no pacing built in, since nothing required it in isolation — while the
mixer accepts new samples only once every 19 clocks. Wiring one straight into the other
would silently drop most of the 8 samples: the mixer only samples `in_valid` while idle,
and it spends most of its time busy. `tx_top.sv` bridges this with a small elastic queue
(depth 8, matching the interpolation factor): every interpolator output is captured as it
arrives and drained into the mixer one entry per rotation, and the next baseband sample is
not accepted until the queue is *fully drained* — not merely until the interpolator is
idle, which happens much earlier — since accepting early would start overwriting queue
slots the mixer had not yet read.

This composition of two blocks at very different paces is exactly what no other testbench
exercises, which is why `tx/tb_tx_top.sv` exists rather than treating the interpolator and
mixer tests as sufficient on their own: it drives baseband-rate stimulus in and checks
4096/4096 RF-rate outputs bit-exact against `tx_mix_i.hex`/`tx_mix_q.hex`, catching a
dropped, duplicated, or reordered sample that neither block's own test could see. It passed
on the first attempt, which is the payoff of designing the queue's drain condition
(`interpolator idle AND queue empty`, not just the first) on paper before writing the RTL.

### Design facts from the reference model

The fused mixer's output is K·x·e^(−jθ) with K > 1, so a full-scale input overflows a
same-width output — the datapath carries one extra bit to absorb it. The signal itself
carries the K, with no free CORDIC seed value to fold it into, so the 1/K correction lives
in the FIR/interpolator coefficients instead.

That guard bit is sized against the *complex envelope*, not the per-axis word, and the two
differ by up to √2. The rotation stays exact only while
|xi + j·xq| ≤ (2^(cordic_bits−1) − 1)/(K·2^Guard) ≈ **1.21 × full scale**. A rotating tone
sits at exactly 1.0 × full scale and is safe. Arbitrary IQ — a QPSK corner point, or two
tones summing in phase — reaches √2 ≈ 1.41 × full scale and clips inside the CORDIC. This
matters most on TX, whose input *is* arbitrary IQ: budget the interpolator's output
backoff against 1.21, not 1.0.

That 1.21 is **invariant under `cordic_bits`**, which is not obvious. `Guard` is defined as
`cordic_bits − data_bits − 1`, so `2^(cordic_bits−1)/2^Guard` is always `2^data_bits`, and
the limit collapses to `2/K` regardless of datapath width. Widening the CORDIC buys
internal precision, never headroom — only `data_bits` moves the clipping point.

Only fully-loaded filter outputs are real outputs. Hardware never produces the `n_taps-1`
tail samples where a filter runs off the end of its input buffer, so the model uses
valid-only convolution to match.

### NCO widths: M = 24, N = 14

Three separate numbers, and conflating them loses information:

- **M = 24** (`phase_bits`) — accumulator width. Sets frequency resolution, fs/2^M =
  0.024 Hz at 400 kS/s. Any LO is placed essentially exactly: the default 80 kHz lands
  0.005 Hz off.
- **N = 14** (`phase_trunc_bits`) — phase bits reaching the angle path. Sets spectral
  purity. Truncating M→N discards information every sample, and the error is periodic, so
  it shows up as discrete spurs: worst-case bound ~6.02·N = 84 dBc. Nothing downstream
  buys past it. N costs no flip-flops at all — it is a bit slice, not a register — so
  there is never an area reason to trim it.
- **`ang_bits` = 17** — the CORDIC's internal angle register, wider than N with the
  truncated phase zero-padded into it, so the rotation converges on the truncated angle
  instead of quantising it a second time. 17 is the floor at `n_iter = 16`: at 16 the last
  atan entries round to zero and those iterations stop doing anything.

These are trimmed from an earlier 32/14/18 because the TinyTapeout target makes flip-flops
the scarce resource. Dropping M 32→24 costs only LO placement precision — 0.09 mHz to
0.024 Hz, both far finer than any modem needs — and nothing in SNR or SFDR, because spectral
purity is N's job. Narrowing `cordic_bits` 20→18 alongside them *improved* SNR by 1.16 dB:
fewer guard bits means fewer LSBs discarded by the output shift, and floor-mode truncation
error is biased rather than symmetric, so less of it accumulates.
