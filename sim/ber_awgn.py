"""End-to-end QPSK BER simulation over the bit-exact TX/RX chain.

Bits -> Gray-coded QPSK symbols -> DDC.tx_stage() (interpolate, up-convert;
the same fixed-point math tx_top.sv implements) -> a channel model (AWGN,
carrier frequency offset, static timing offset) -> DDC.run() (down-convert,
decimate; the same fixed-point math rx_top.sv implements) -> nearest-point
QPSK demod -> BER, swept over Eb/N0 and compared against the theoretical
QPSK bound.

There is no carrier or timing recovery in this chain (see the README), so a
nonzero carrier offset rotates the constellation over the length of a burst
rather than only adding noise. The main sweep therefore runs a clean carrier
and timing to measure how close the datapath itself comes to the theoretical
bound; --cfo-hz and --timing-offset then characterize how much that costs.

Each symbol is held for --osf baseband samples as an unshaped rectangular
pulse (see upsample_rect()) rather than passed through a matched Nyquist
filter, since the interpolator/decimator here are a generic anti-imaging and
channel-select pair, not a root-raised-cosine pulse shaper. That costs
several dB against the theoretical bound, and the sweep reports it rather
than hiding it: the target Eb/N0 is achieved exactly, and the resulting
measured BER runs consistently to the right of the theoretical curve.

Run:
    python3 sim/ber_awgn.py
    python3 sim/ber_awgn.py --svg build/ber_curve.svg
    python3 sim/ber_awgn.py --cfo-hz 200 --skip-robustness
"""

from __future__ import annotations

import argparse
import math
import os
import sys

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_REF_DIR = os.path.join(os.path.dirname(_HERE), "cordic", "reference")
if _REF_DIR not in sys.path:
    sys.path.insert(0, _REF_DIR)

from ddc_reference import DDC, DDCConfig, full_scale, sat  # noqa: E402


def bits_to_qpsk(bits: np.ndarray, amp: float) -> tuple[np.ndarray, np.ndarray]:
    """Map bit pairs to QPSK symbols, one bit to I and one to Q.

    Mapping each bit independently onto I and onto Q is already Gray-coded:
    flipping one bit moves the symbol to its horizontal or vertical
    neighbor, never the diagonal.

    Args:
        bits: Flat array of 0/1 values, even length.
        amp: Target amplitude for each rail; full symbol magnitude is
            amp*sqrt(2).

    Returns:
        An (i, q) tuple of float symbol values.
    """
    b = bits.reshape(-1, 2)
    i = np.where(b[:, 0] == 0, amp, -amp)
    q = np.where(b[:, 1] == 0, amp, -amp)
    return i.astype(np.int64), q.astype(np.int64)


def qpsk_to_bits(i: np.ndarray, q: np.ndarray) -> np.ndarray:
    """Slice QPSK symbols to the nearest constellation point and recover bits."""
    b0 = (i < 0).astype(np.uint8)
    b1 = (q < 0).astype(np.uint8)
    return np.stack([b0, b1], axis=1).reshape(-1)


def fractional_delay(x: np.ndarray, frac: float) -> np.ndarray:
    """Delay a complex sequence by a fractional number of samples via linear interpolation.

    A real sampling-phase offset is not an integer number of RF samples;
    linear interpolation is the simplest fractional delay and, like a real
    ADC sampling at the wrong phase, adds a little lowpass distortion along
    with the shift.

    Args:
        x: Complex sequence to delay.
        frac: Delay in samples (may be fractional).

    Returns:
        The delayed sequence, same length as `x`.
    """
    if frac == 0.0:
        return x
    n = np.arange(len(x))
    idx = n - frac
    idx0 = np.clip(np.floor(idx).astype(np.int64), 0, len(x) - 1)
    idx1 = np.clip(idx0 + 1, 0, len(x) - 1)
    w = idx - np.floor(idx)
    return x[idx0] * (1 - w) + x[idx1] * w


def apply_channel(x: np.ndarray, fs: float, ebn0_db: float, sps: int,
                   cfo_hz: float, timing_offset: float,
                   rng: np.random.Generator) -> np.ndarray:
    """Apply a carrier offset, a timing offset, and AWGN to an RF-rate signal.

    Es (energy per symbol) is measured from the signal's own RF-rate power
    times the oversampling factor `sps`, so the requested Eb/N0 is exact
    regardless of the symbol amplitude chosen upstream. Per-sample noise
    variance is N0 itself, not N0*sps: summing sps noisy samples in an
    integrate-and-dump receiver scales signal energy by sps and noise
    variance by sps identically, so the sps factors cancel and only the
    per-sample variance needs to equal N0 for the post-integration SNR to
    land on Es/N0. The decimating FIR is not literally an integrate-and-dump,
    so its actual processing gain differs slightly from this ideal.

    Args:
        x: RF-rate complex samples, amplitude normalised so 1.0 is the ADC's
            full scale.
        fs: RF sample rate in Hz, for the carrier-offset phase ramp.
        ebn0_db: Target Eb/N0 in dB.
        sps: RF samples per symbol (the interpolation factor).
        cfo_hz: Carrier frequency offset in Hz.
        timing_offset: Static sampling-phase offset, in RF samples.
        rng: Seeded random generator, for reproducible noise.

    Returns:
        The channel-impaired RF-rate complex signal, same length as `x`.
    """
    n = np.arange(len(x))
    y = x * np.exp(1j * 2 * math.pi * cfo_hz * n / fs)
    y = fractional_delay(y, timing_offset)

    es = float(np.mean(np.abs(x) ** 2)) * sps
    eb = es / 2.0  # QPSK: 2 bits per symbol
    n0 = eb / (10.0 ** (ebn0_db / 10.0))
    noise_var = n0  # per RF sample; see docstring
    noise = (rng.normal(scale=math.sqrt(noise_var / 2), size=y.shape)
             + 1j * rng.normal(scale=math.sqrt(noise_var / 2), size=y.shape))
    return y + noise


def upsample_rect(xi: np.ndarray, xq: np.ndarray, osf: int) -> tuple[np.ndarray, np.ndarray]:
    """Hold each symbol for `osf` baseband IQ samples (a rectangular, unshaped pulse).

    The interpolator ahead of the mixer is an anti-imaging lowpass with a
    20 kHz cutoff against the 25 kHz baseband Nyquist, not a matched
    Nyquist/RRC pulse filter -- a symbol stream that fills the whole baseband
    bandwidth would smear into its neighbors before it ever reaches that
    filter. Holding each symbol for `osf` samples puts the rectangular
    pulse's first spectral null at fs_out/osf, comfortably inside the
    cutoff for osf as small as 8.

    Args:
        xi, xq: Per-symbol amplitudes.
        osf: Baseband samples to hold each symbol for.

    Returns:
        An (i, q) tuple of baseband-rate arrays, length len(xi)*osf.
    """
    return np.repeat(xi, osf), np.repeat(xq, osf)


def calibrate(ddc: DDC, amp: float, osf: int) -> tuple[int, int, complex]:
    """Find the fixed sample delay, symbol timing phase, and complex gain the clean chain introduces.

    Two cascaded FIR group delays and two CORDIC rotations shift and scale
    the recovered constellation by a fixed amount that does not depend on
    noise, and the rectangular pulse shape leaves `osf` equally-plausible
    sample instants per symbol, only one of which sits at the eye's center.
    Solving for all three once, on a clean burst, and reusing them for every
    Eb/N0 point avoids this search failing at low SNR and stands in for the
    symbol-timing recovery this chain does not otherwise have.

    Args:
        ddc: The DDC model to calibrate against.
        amp: The per-rail symbol amplitude the sweep will use.
        osf: Baseband samples held per symbol (see upsample_rect()).

    Returns:
        A (sample_offset, phase, gain) triple: `sample_offset` the baseband
        IQ sample delay to align to, `phase` which of the `osf` sample
        instants per symbol to decide on, and `gain` the complex scalar the
        recovered stream must be multiplied by to match the reference
        constellation.
    """
    cfg = ddc.cfg
    rng = np.random.default_rng(0)
    n_sym = 4000
    bits = rng.integers(0, 2, n_sym * 2)
    xi, xq = bits_to_qpsk(bits, amp)
    xi_bb, xq_bb = upsample_rect(xi, xq, osf)
    tx = ddc.tx_stage(xi_bb, xq_bb)
    assert tx["n_saturated"] == 0, "calibration burst clipped in the TX chain"
    rf = (tx["mix_i"].astype(float) + 1j * tx["mix_q"].astype(float)) / full_scale(cfg.data_bits)
    adc_i = sat(np.round(rf.real * full_scale(cfg.data_bits)), cfg.data_bits)
    adc_q = sat(np.round(rf.imag * full_scale(cfg.data_bits)), cfg.data_bits)
    rx = ddc.run(adc_i, adc_q)
    assert rx["n_saturated"] == 0, "calibration burst clipped in the RX chain"
    b = (rx["out_i"].astype(float) + 1j * rx["out_q"].astype(float)) / full_scale(cfg.out_bits)
    a_bb = (xi_bb.astype(float) + 1j * xq_bb.astype(float)) / amp

    # Coarse sample delay: correlate the full-rate recovered stream against
    # the full-rate repeated stimulus, so the filters' combined group delay
    # is found without yet committing to a symbol timing phase.
    coarse = None
    for off in range(0, 80):
        aa = a_bb[: len(a_bb) - off] if off > 0 else a_bb
        bb = b[off: off + len(aa)]
        m = min(len(aa), len(bb))
        if m < 2000:
            continue
        aa2, bb2 = aa[:m], bb[:m]
        denom = np.vdot(bb2, bb2)
        if denom == 0:
            continue
        g = np.vdot(bb2, aa2) / denom
        err = aa2 - g * bb2
        snr = 10 * np.log10(np.mean(np.abs(aa2) ** 2) / np.mean(np.abs(err) ** 2))
        if coarse is None or snr > coarse[0]:
            coarse = (snr, off)
    assert coarse is not None, "no usable coarse alignment found"
    base_off = coarse[1]

    # Fine symbol-timing phase: of the `osf` sample instants per symbol
    # period, pick the one that scores best per-symbol, against the
    # un-repeated per-symbol reference rather than the held pulse.
    a_sym = (xi.astype(float) + 1j * xq.astype(float)) / amp
    best = None
    for phase in range(osf):
        dec = b[base_off + phase::osf]
        m = min(len(dec), len(a_sym))
        if m < 500:
            continue
        aa2, bb2 = a_sym[:m], dec[:m]
        denom = np.vdot(bb2, bb2)
        if denom == 0:
            continue
        g = np.vdot(bb2, aa2) / denom
        err = aa2 - g * bb2
        snr = 10 * np.log10(np.mean(np.abs(aa2) ** 2) / np.mean(np.abs(err) ** 2))
        if best is None or snr > best[0]:
            best = (snr, phase, g)

    assert best is not None and best[0] > 40, f"calibration round trip only scored {best}"
    _, phase, gain = best
    return base_off, phase, gain


def simulate_point(ddc: DDC, ebn0_db: float, amp: float, osf: int,
                    sample_offset: int, phase: int, gain: complex,
                    cfo_hz: float, timing_offset: float, seed: int,
                    target_errors: int, max_bits: int, batch_bits: int) -> tuple[int, int]:
    """Run TX -> channel -> RX in batches until enough errors are seen or the bit cap is hit.

    Args:
        ddc: The DDC model.
        ebn0_db: Target Eb/N0 for this point.
        amp: Per-rail symbol amplitude.
        osf: Baseband samples held per symbol (see upsample_rect()).
        sample_offset: Baseband IQ sample delay from calibrate().
        phase: Symbol timing phase (0..osf-1) from calibrate().
        gain: Complex alignment gain from calibrate().
        cfo_hz: Carrier frequency offset in Hz.
        timing_offset: Static sampling-phase offset, in RF samples.
        seed: RNG seed for this point.
        target_errors: Stop once at least this many bit errors are seen.
        max_bits: Stop after this many bits regardless of error count.
        batch_bits: Bits simulated per iteration.

    Returns:
        An (n_errors, n_bits) pair.
    """
    cfg = ddc.cfg
    rng = np.random.default_rng(seed)
    n_errors = 0
    n_bits = 0
    while n_bits < max_bits and n_errors < target_errors:
        n_sym = batch_bits // 2
        bits = rng.integers(0, 2, n_sym * 2)
        xi, xq = bits_to_qpsk(bits, amp)
        xi_bb, xq_bb = upsample_rect(xi, xq, osf)
        tx = ddc.tx_stage(xi_bb, xq_bb)
        rf = (tx["mix_i"].astype(float) + 1j * tx["mix_q"].astype(float)) / full_scale(cfg.data_bits)
        ch = apply_channel(rf, cfg.fs_in, ebn0_db, sps=cfg.decim * osf,
                            cfo_hz=cfo_hz, timing_offset=timing_offset, rng=rng)
        adc_i = sat(np.round(ch.real * full_scale(cfg.data_bits)), cfg.data_bits)
        adc_q = sat(np.round(ch.imag * full_scale(cfg.data_bits)), cfg.data_bits)
        rx = ddc.run(adc_i, adc_q)
        b = (rx["out_i"].astype(float) + 1j * rx["out_q"].astype(float)) / full_scale(cfg.out_bits)

        dec = gain * b[sample_offset + phase::osf]
        m = min(len(dec), n_sym)
        rec_bits = qpsk_to_bits(dec[:m].real, dec[:m].imag)
        ref_bits = bits[: m * 2]

        n_errors += int(np.count_nonzero(rec_bits != ref_bits))
        n_bits += m * 2
    return n_errors, n_bits


def theoretical_qpsk_ber(ebn0_db: np.ndarray) -> np.ndarray:
    """QPSK bit-error probability over AWGN: Q(sqrt(2*Eb/N0)), the same as BPSK per rail."""
    ebn0 = 10.0 ** (np.asarray(ebn0_db, dtype=float) / 10.0)
    return 0.5 * np.vectorize(math.erfc)(np.sqrt(ebn0))


def _write_ber_svg(path: str, ebn0_db: list[float], measured: list[float],
                    theory: list[float]) -> None:
    """Write a hand-drawn semilog BER-vs-Eb/N0 plot as a standalone SVG.

    No plotting library is a project dependency (only numpy is), so this
    lays out axes, gridlines, and two polylines directly in SVG coordinates.

    Args:
        path: Output file path.
        ebn0_db: Eb/N0 sweep points, in dB.
        measured: Measured BER at each point (0 becomes a floor for the log
            scale, so it still plots as a labeled downward mark).
        theory: Theoretical QPSK BER at each point.
    """
    w, h = 640, 420
    ml, mr, mt, mb = 70, 20, 20, 50
    pw, ph = w - ml - mr, h - mt - mb

    x0, x1 = min(ebn0_db), max(ebn0_db)
    y_top, y_bot = 0, -7  # log10(BER) axis range: 1e0 down to 1e-7

    def xpix(x):
        return ml + (x - x0) / (x1 - x0) * pw

    def ypix(logber):
        logber = max(min(logber, y_top), y_bot)
        return mt + (y_top - logber) / (y_top - y_bot) * ph

    floor = 10.0 ** (y_bot - 0.3)

    def points(vals):
        pts = []
        for x, y in zip(ebn0_db, vals):
            ly = math.log10(y) if y > 0 else (y_bot - 0.3)
            pts.append(f"{xpix(x):.1f},{ypix(ly):.1f}")
        return " ".join(pts)

    grid = []
    labels = []
    for dec in range(y_top, y_bot - 1, -1):
        yy = ypix(dec)
        grid.append(f'<line x1="{ml}" y1="{yy:.1f}" x2="{ml + pw}" y2="{yy:.1f}" '
                     f'stroke="var(--grid)" stroke-width="1"/>')
        labels.append(f'<text x="{ml - 8}" y="{yy + 4:.1f}" text-anchor="end" '
                       f'font-size="11" fill="var(--fg)">1e{dec}</text>')
    for x in ebn0_db:
        xx = xpix(x)
        grid.append(f'<line x1="{xx:.1f}" y1="{mt}" x2="{xx:.1f}" y2="{mt + ph}" '
                     f'stroke="var(--grid)" stroke-width="1"/>')
        labels.append(f'<text x="{xx:.1f}" y="{mt + ph + 18}" text-anchor="middle" '
                       f'font-size="11" fill="var(--fg)">{x:g}</text>')

    svg = f'''<svg xmlns="http://www.w3.org/2000/svg" viewBox="0 0 {w} {h}" font-family="sans-serif">
<style>
  :root {{ --bg:#ffffff; --fg:#222222; --grid:#dddddd; --theory:#888888; --meas:#2266cc; }}
  @media (prefers-color-scheme: dark) {{
    :root {{ --bg:#1e1e1e; --fg:#e8e8e8; --grid:#3a3a3a; --theory:#999999; --meas:#6fb4ff; }}
  }}
</style>
<rect width="{w}" height="{h}" fill="var(--bg)"/>
{''.join(grid)}
<polyline points="{points(theory)}" fill="none" stroke="var(--theory)" stroke-width="2" stroke-dasharray="5,4"/>
<polyline points="{points(measured)}" fill="none" stroke="var(--meas)" stroke-width="2.5"/>
{''.join(f'<circle cx="{xpix(x):.1f}" cy="{ypix(math.log10(y) if y > 0 else (y_bot - 0.3)):.1f}" r="3" fill="var(--meas)"/>' for x, y in zip(ebn0_db, measured))}
{''.join(labels)}
<text x="{ml + pw / 2}" y="{h - 8}" text-anchor="middle" font-size="12" fill="var(--fg)">Eb/N0 (dB)</text>
<text x="14" y="{mt + ph / 2}" text-anchor="middle" font-size="12" fill="var(--fg)" transform="rotate(-90 14 {mt + ph / 2})">Bit error rate</text>
<rect x="{ml + pw - 190}" y="{mt + 4}" width="12" height="12" fill="var(--meas)"/>
<text x="{ml + pw - 174}" y="{mt + 14}" font-size="11" fill="var(--fg)">measured (tx_top/rx_top model)</text>
<line x1="{ml + pw - 190}" y1="{mt + 26}" x2="{ml + pw - 178}" y2="{mt + 26}" stroke="var(--theory)" stroke-width="2" stroke-dasharray="5,4"/>
<text x="{ml + pw - 174}" y="{mt + 30}" font-size="11" fill="var(--fg)">theoretical QPSK</text>
</svg>
'''
    with open(path, "w", newline="\n") as f:
        f.write(svg)


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--ebn0-min", type=float, default=0.0)
    p.add_argument("--ebn0-max", type=float, default=16.0)
    p.add_argument("--ebn0-step", type=float, default=2.0)
    p.add_argument("--amp-dbfs", type=float, default=-6.0,
                   help="per-rail symbol amplitude relative to data_bits full scale")
    p.add_argument("--osf", type=int, default=8,
                   help="baseband samples held per symbol (rectangular pulse); "
                        "sets the symbol rate to fs_out/osf")
    p.add_argument("--target-errors", type=int, default=50)
    p.add_argument("--max-bits", type=int, default=2_000_000)
    p.add_argument("--batch-bits", type=int, default=200_000)
    p.add_argument("--seed", type=int, default=1234)
    p.add_argument("--cfo-hz", type=float, default=0.0,
                   help="carrier offset for the main sweep (0 = clean carrier)")
    p.add_argument("--timing-offset", type=float, default=0.0,
                   help="static timing offset in RF samples for the main sweep")
    p.add_argument("--svg", metavar="PATH", help="write a BER-vs-Eb/N0 plot to PATH")
    p.add_argument("--skip-robustness", action="store_true",
                   help="skip the CFO/timing-offset sensitivity characterization")
    a = p.parse_args(argv)

    cfg = DDCConfig()
    ddc = DDC(cfg)
    amp = full_scale(cfg.data_bits) * (10.0 ** (a.amp_dbfs / 20.0))
    symbol_rate = cfg.fs_out / a.osf

    sample_offset, phase, gain = calibrate(ddc, amp, a.osf)
    print(f"symbol rate: {symbol_rate:g} Sym/s (osf={a.osf} against fs_out={cfg.fs_out:g} Hz)")
    print(f"calibration: sample_offset={sample_offset}, phase={phase}, gain={gain:.4f} "
          f"(|gain|={abs(gain):.4f}, angle={math.degrees(np.angle(gain)):.3f} deg)\n")

    ebn0_points = np.arange(a.ebn0_min, a.ebn0_max + 1e-9, a.ebn0_step)
    measured = []
    print(f"{'Eb/N0 (dB)':>10} {'bits':>10} {'errors':>8} {'measured BER':>14} {'theory BER':>12}")
    for k, ebn0_db in enumerate(ebn0_points):
        n_err, n_bits = simulate_point(
            ddc, float(ebn0_db), amp, a.osf, sample_offset, phase, gain,
            a.cfo_hz, a.timing_offset,
            seed=a.seed + k, target_errors=a.target_errors, max_bits=a.max_bits,
            batch_bits=a.batch_bits)
        ber = n_err / n_bits
        measured.append(ber)
        tag = "" if n_err >= a.target_errors else "  (bit cap reached)"
        print(f"{ebn0_db:10.1f} {n_bits:10d} {n_err:8d} {ber:14.3e} "
              f"{theoretical_qpsk_ber(np.array([ebn0_db]))[0]:12.3e}{tag}")

    theory = list(theoretical_qpsk_ber(ebn0_points))
    if a.svg:
        _write_ber_svg(a.svg, list(ebn0_points), measured, theory)
        print(f"\nwrote {a.svg}")

    if not a.skip_robustness:
        print("\ncarrier-offset sensitivity (Eb/N0 = 20 dB, effectively noise-free):")
        print(f"{'CFO (Hz)':>10} {'measured BER':>14}")
        for cfo in (0.0, 10.0, 50.0, 200.0, 1000.0):
            n_err, n_bits = simulate_point(
                ddc, 20.0, amp, a.osf, sample_offset, phase, gain, cfo, 0.0,
                seed=9000, target_errors=a.target_errors, max_bits=a.max_bits,
                batch_bits=a.batch_bits)
            print(f"{cfo:10.1f} {n_err / n_bits:14.3e}")

        print(f"\ntiming-offset sensitivity (Eb/N0 = 20 dB, effectively noise-free, "
              f"symbol period = {a.osf} RF samples):")
        print(f"{'offset (RF samples)':>20} {'measured BER':>14}")
        for toff in (0.0, 0.25, 0.5, 1.0, 2.0):
            n_err, n_bits = simulate_point(
                ddc, 20.0, amp, a.osf, sample_offset, phase, gain, 0.0, toff,
                seed=9100, target_errors=a.target_errors, max_bits=a.max_bits,
                batch_bits=a.batch_bits)
            print(f"{toff:20.2f} {n_err / n_bits:14.3e}")

    return 0


if __name__ == "__main__":
    raise SystemExit(main())
