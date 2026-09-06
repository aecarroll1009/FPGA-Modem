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

## Components

- **CORDIC (rotation mode)** — the shared engine behind both directions: fused NCO +
  mixer, rotating by −θ when `downconvert` is high (RX) and by +θ when it is low (TX).
  Both directions run the same 16 iterations through the same adders, so they cost the
  same and neither is a slow path.
- **Decimating FIR** (`rx/fir_decimate.sv`) — the RX-side filter: one 63-tap linear-phase
  lowpass decimating by 8, with the CORDIC gain K ≈ 1.6467 folded into its coefficients
  rather than spent on a separate scaling stage. Deliberately not a CIC — a CIC earns its
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

The CORDIC is iterative — one rotation per clock, `n_iter = 16` — so the mixer is not a
one-sample-per-clock block. Measured sustained throughput of `ddc_frontend` with
`in_valid` held high is **19.0 clocks per sample**: 16 iterations plus the
`IDLE → WAIT_BUSY → RUN` handshake. Everything downstream is budgeted from that number,
which `./rx/run_throughput.sh` re-measures — rerun it whenever the iteration count or the
mixer handshake changes, since both move every budget below:

| | rate | cycle budget |
|---|---|---|
| Input samples | 2.4 MS/s | 19 clocks each → **45.6 MHz minimum clock** |
| Mixer outputs | 2.4 MS/s | one per 19 clocks |
| FIR outputs (÷8) | 300 kS/s | 152 clocks per I/Q output pair |

Two consequences worth stating up front. First, the FIR's 63 taps fold around their own
symmetry (`h[k] == h[62-k]`) into 32 multiply-accumulate steps per rail — one pre-add
replaces one multiply, exact rather than approximate because the folded pair is only
correct if the taps are precisely palindromic, which `fir_taps_quantized()` enforces at
generation time. Run with one multiplier per rail (both rails computed in parallel, not
time-shared — DSP blocks are abundant on this device, 2 of 66), that is 32 cycles against
the 152-clock budget: **21%**, not the 83% an unfolded, rail-shared design would cost.
Second, 19 clocks/sample is a ceiling on input rate: 2.4 MS/s needs 45.6 MHz and scales
linearly, so a 10 MS/s capture would demand 190 MHz. If the input rate ever rises that
far, the fix is to unroll the CORDIC into 16 pipeline stages for one sample per clock,
trading ~16× the adders for the rate — not to push the clock.

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
instead of only against simulation. Three tops are buildable, and they answer different
questions:

```
powershell -File syn/run_syn.ps1                          # rx_top, the FPGA RX chain
powershell -File syn/run_syn.ps1 -Top tx_top              # tx_top, the FPGA TX chain
powershell -File syn/run_syn.ps1 -Top tt_um_cordic_ddc    # the unit that tapes out
```

The project is generated by `syn/build.tcl` rather than checked in, so the file list and
device cannot drift away from the RTL. Everything it writes goes to the gitignored
`syn/output/`.

Measured on a Cyclone V 5CEBA4F23C7 (speed grade 7 — the slow common grade, so the faster
parts only do better), Quartus Lite 17.0, constrained at 50 MHz:

| | `rx_top` (CORDIC + decimator) | `tx_top` (CORDIC + interpolator) | `tt_um_cordic_ddc` (CORDIC only) |
|---|---|---|---|
| Fmax (slow 1100 mV 85 °C) | **69.55 MHz** | **87.05 MHz** | **102.81 MHz** |
| Setup / hold slack | +5.622 / +0.256 ns | +8.513 / +0.259 ns | +10.273 / +0.236 ns |
| Logic | 375 ALMs | 492 ALMs | 251 ALMs |
| Registers | 389 | 841 | 255 |
| DSP blocks | **2** | **2** | **0** |
| Block memory | 8,704 bits | 0 bits | 0 bits |

Three things worth reading off that table. The rate budget is not close to binding on any
build — even `rx_top`'s 69.55 MHz, the tightest of the three, is still 1.53× the 45.6 MHz
the CORDIC needs, so the iterative CORDIC remains the right call and the unrolled version
stays unnecessary. The CORDIC itself still spends **no** DSP blocks, because shift-and-add
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

The top level's egress is a stub — a valid/ready IQ stream with the I/O false-pathed in
`syn/rx_top.sdc` — so these are core-datapath numbers. Real I/O constraints arrive with
the physical link.

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

The numpy reference model is `cordic/reference/ddc_reference.py`, with 44 tests in
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

Measured at the default 16-bit config (`--report`):

| | SNR | SFDR | ENOB |
|---|---|---|---|
| NCO alone | 91.6 dB | 99.3 dB | — |
| NCO at an LO that exercises the N-bit truncation | — | 84.3 dB | — |
| DDC (fused mixer) | 80.4 dB | 83.8 dB | 13.06 |

### Both mixing directions

Because the direction is a port, one build has to prove both. Nothing here would catch a
direction bit that was wired but ignored, so each check is paired with the case that
should fail:

| check | result |
|---|---|
| up-convert vs analytic K·x·e^(+jθ) | 86.1 dB |
| up-convert vs the *down-convert* reference (must fail) | −3.0 dB |
| up-convert then down-convert, vs K²·x | 83.5 dB |
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
recovering the original at 77.9 dB SNR. That one test exercises the interpolator, both
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
  0.14 Hz at 2.4 MS/s. Any LO is placed essentially exactly.
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
the scarce resource. Dropping M 32→24 costs only LO placement precision — 0.56 mHz to
0.14 Hz, both far finer than any modem needs — and nothing in SNR or SFDR, because spectral
purity is N's job. Narrowing `cordic_bits` 20→18 alongside them *improved* SNR by 1.16 dB:
fewer guard bits means fewer LSBs discarded by the output shift, and floor-mode truncation
error is biased rather than symmetric, so less of it accumulates.
