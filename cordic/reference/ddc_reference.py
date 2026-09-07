"""Numpy reference model of the DDC front-end.

    RF samples --> [ Mixer ] --> [ Decimating FIR ] --> baseband IQ
                       ^
                   [  NCO  ]  phase accumulator -> rotation-mode CORDIC

`ddc_ideal()` computes the exact float64 answer. `DDC.run()` computes the
bit-exact fixed-point answer the RTL must match. Run with --report,
--compare-arch, or --emit-vectors.
"""

from __future__ import annotations

import argparse
import json
import math
import os
import sys
from dataclasses import dataclass, asdict, replace

import numpy as np

# Full circle in CORDIC angle units is 2**ang_bits, so pi/2 is 2**(ang_bits-2).
# Keeping the circle a power of two is what makes the quadrant split a bit slice.

MIX_SEPARATE = "separate"
MIX_FUSED = "fused"

TRUNC = "trunc"
ROUND = "round"


# --------------------------------------------------------------------------
# fixed-point primitives
#
# Everything is a plain signed integer. A DATA_BITS word represents a value in
# [-1, 1) with the binary point just below the sign bit, so full scale is
# 2**(bits-1). Python/numpy int64 holds all intermediates exactly; assert_fits()
# is the guard that we never silently exceed it.
# --------------------------------------------------------------------------


def full_scale(bits: int) -> int:
    """Integer value representing 1.0 in a `bits`-wide signed word."""
    return 1 << (bits - 1)


def sat(x, bits: int):
    """Saturate to a `bits`-wide two's-complement range.

    Clips rather than wraps, so an overflow does not corrupt the whole band.

    Args:
        x: Values to saturate.
        bits: Target word width.

    Returns:
        `x` clipped to the representable range of a `bits`-wide signed word.
    """
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    return np.clip(np.asarray(x, dtype=np.int64), lo, hi)


def saturation_mask(x, bits: int):
    """Boolean mask of the elements sat() would clip.

    Args:
        x: Values to test.
        bits: Target word width.

    Returns:
        A boolean array, True where the value is outside the representable
        range.
    """
    lo = -(1 << (bits - 1))
    hi = (1 << (bits - 1)) - 1
    a = np.asarray(x, dtype=np.int64)
    return (a < lo) | (a > hi)


def would_saturate(x, bits: int) -> int:
    """Count how many elements sat() would clip."""
    return int(np.count_nonzero(saturation_mask(x, bits)))


def assert_fits(x, name: str, bits: int = 62) -> None:
    """Guard against silent int64 wrap in an intermediate."""
    a = np.asarray(x, dtype=np.int64)
    if a.size and int(np.max(np.abs(a))) >= (1 << bits):
        raise OverflowError(
            f"{name} exceeded {bits} bits -- int64 intermediates are no longer "
            f"exact; reduce widths or split the accumulation"
        )


def shr(x, s: int, mode: str = TRUNC):
    """Right-shift `x` by `s`, matching the RTL's shift behavior.

    TRUNC floors, like Verilog's `>>>`. ROUND is round-half-up.

    Args:
        x: Values to shift.
        s: Shift amount; values with s <= 0 are returned unchanged.
        mode: TRUNC or ROUND.

    Returns:
        `x` shifted right by `s`.
    """
    a = np.asarray(x, dtype=np.int64)
    if s <= 0:
        return a
    if mode == ROUND:
        return (a + (np.int64(1) << np.int64(s - 1))) >> np.int64(s)
    if mode == TRUNC:
        return a >> np.int64(s)
    raise ValueError(f"unknown shift mode {mode!r}; expected {TRUNC!r} or {ROUND!r}")


# --------------------------------------------------------------------------
# CORDIC
# --------------------------------------------------------------------------


def cordic_gain(n_iter: int) -> float:
    """K = prod_{i<n} sqrt(1 + 2^-2i). Converges to ~1.6467602581210656."""
    k = 1.0
    for i in range(n_iter):
        k *= math.sqrt(1.0 + 2.0 ** (-2 * i))
    return k


def cordic_convergence_limit(n_iter: int) -> float:
    """The largest |z0| the rotation mode can drive to zero: sum atan(2^-i)."""
    return float(sum(math.atan(2.0 ** -i) for i in range(n_iter)))


def atan_table(n_iter: int, ang_bits: int) -> np.ndarray:
    """Compute atan(2^-i) in angle LSBs for each CORDIC iteration.

    Entries round to zero past about ang_bits iterations, so extra stages
    beyond that add no accuracy.

    Args:
        n_iter: Number of CORDIC iterations to generate entries for.
        ang_bits: Angle word width; a full circle is 2**ang_bits.

    Returns:
        One table entry per iteration, in angle LSBs.
    """
    scale = (1 << ang_bits) / (2.0 * math.pi)
    return np.array(
        [int(round(math.atan(2.0**-i) * scale)) for i in range(n_iter)],
        dtype=np.int64,
    )


def cordic_rotate(x, y, z, table: np.ndarray, width: int, shift_mode: str = TRUNC):
    """Bit-exact rotation-mode CORDIC, vectorised over a whole sample array.

    Rotates (x, y) by angle z, scaling the result by K. Pass z0=-theta to
    rotate by -theta.

    The rotation grows the vector's magnitude monotonically toward K*|v|, so a
    vector that starts inside the datapath can still clip partway through. That
    clipping is counted and returned rather than left silent: it is the failure
    mode a caller most needs to know about, and it is invisible from the output
    alone.

    Args:
        x, y: Initial vector components, at `width` bits.
        z: Initial angle, in the same LSB units as `table`.
        table: Per-iteration atan values from `atan_table()`.
        width: Datapath width for x and y.
        shift_mode: TRUNC or ROUND, for the per-iteration shifts.

    Returns:
        The rotated (x, y), the residual angle z after all iterations, and the
        number of *samples* that clipped anywhere in the rotation.
    """
    n_iter = len(table)
    x = np.asarray(x, dtype=np.int64)
    y = np.asarray(y, dtype=np.int64)
    z = np.asarray(z, dtype=np.int64)

    # One flag per sample, not per event. A sample that clips on twelve
    # consecutive iterations is still one clipped sample, and this count is
    # summed with fir_decimate's, which counts elements -- so the two have to
    # be in the same unit or the total means nothing.
    clipped = saturation_mask(x, width) | saturation_mask(y, width)
    x = sat(x, width)
    y = sat(y, width)

    for i in range(n_iter):
        d = np.where(z < 0, np.int64(-1), np.int64(1))
        xs = shr(x, i, shift_mode)
        ys = shr(y, i, shift_mode)
        xn_raw = x - d * ys
        yn_raw = y + d * xs
        clipped = clipped | saturation_mask(xn_raw, width) | saturation_mask(
            yn_raw, width
        )
        x = sat(xn_raw, width)
        y = sat(yn_raw, width)
        z = z - d * table[i]
    return x, y, z, int(np.count_nonzero(clipped))


def quadrant_split(phase, ang_bits: int):
    """Split an unsigned phase word into (quadrant 0..3, residual in [0, pi/2)).

    In RTL this is a bit slice, not arithmetic. The top two bits give the
    quadrant, and the rest gives the residual.

    Args:
        phase: Angle-domain phase values, at ang_bits width.
        ang_bits: Angle word width.

    Returns:
        A (quadrant, residual) tuple.
    """
    p = np.asarray(phase, dtype=np.int64) & ((1 << ang_bits) - 1)
    return p >> np.int64(ang_bits - 2), p & ((1 << (ang_bits - 2)) - 1)


def apply_quadrant_sincos(q, c, s):
    """Lift the residual's (cos, sin) pair to the full circle.

    Uses sign swaps only, no multiplier.

    Args:
        q: Quadrant, 0..3.
        c, s: (cos, sin) of the residual angle.

    Returns:
        A (cos, sin) tuple lifted to the full circle.
    """
    q = np.asarray(q, dtype=np.int64)
    conds = [q == 0, q == 1, q == 2, q == 3]
    cos = np.select(conds, [c, -s, -c, s])
    sin = np.select(conds, [s, c, -s, -c])
    return cos.astype(np.int64), sin.astype(np.int64)


def prerotate_conj(q, xi, xq, downconvert: bool = True):
    """Multiply (xi + j*xq) by exp(-/+ j*q*pi/2), per the direction.

    Applies the quadrant part of the rotation before the CORDIC handles the
    residual. Being a multiple of 90 degrees, this needs only sign swaps.

    Up-conversion wants exp(+j*q*pi/2), which is exp(-j*(-q)*pi/2), so
    negating the quadrant mod 4 reaches it through the same four cases.
    That is why the RTL needs one case table rather than two: the direction
    is a select on the table's index, not a second table.

    Args:
        q: Quadrant, 0..3.
        xi, xq: Input I/Q samples.
        downconvert: True to rotate by -q*pi/2, False by +q*pi/2.

    Returns:
        The (i, q) input rotated by -/+ q*pi/2.
    """
    q = np.asarray(q, dtype=np.int64)
    if not downconvert:
        q = (-q) & 3
    conds = [q == 0, q == 1, q == 2, q == 3]
    i = np.select(conds, [xi, xq, -xi, -xq])
    Q = np.select(conds, [xq, -xi, -xq, xi])
    return i.astype(np.int64), Q.astype(np.int64)


# --------------------------------------------------------------------------
# FIR design and quantization
# --------------------------------------------------------------------------


def firwin_lowpass(n_taps: int, cutoff_norm: float) -> np.ndarray:
    """Design a window-method lowpass FIR with unit DC gain.

    Uses a Blackman window, whose -74 dB sidelobes suit a 16-bit datapath.
    Implemented directly rather than via scipy, so this module depends only
    on numpy.

    Args:
        n_taps: Number of taps; must be odd, for exact linear phase.
        cutoff_norm: Cutoff frequency, normalised as fc/(fs/2), in (0, 1).

    Returns:
        The filter taps, with unit DC gain.
    """
    if n_taps % 2 == 0:
        raise ValueError("use an odd tap count so the filter is exactly linear phase")
    if not 0.0 < cutoff_norm < 1.0:
        raise ValueError(f"cutoff_norm must be in (0, 1), got {cutoff_norm}")
    n = np.arange(n_taps) - (n_taps - 1) / 2.0
    h = cutoff_norm * np.sinc(cutoff_norm * n)
    m = np.arange(n_taps)
    w = (
        0.42
        - 0.5 * np.cos(2.0 * np.pi * m / (n_taps - 1))
        + 0.08 * np.cos(4.0 * np.pi * m / (n_taps - 1))
    )
    h = h * w
    return h / h.sum()


def fir_taps_quantized(
    h: np.ndarray, coef_bits: int, target_dc: float
) -> np.ndarray:
    """Quantize taps to `coef_bits`, targeting an exact DC gain.

    Any rounding error is absorbed into the largest tap, so the quantized
    coefficient sum matches `target_dc` exactly rather than only
    approximately. The caller picks target_dc for the filter's position in
    the chain: 1/k_gain for the RX decimator (undoing the mixer's K, which
    ran before it), decim/k_gain for the TX interpolator (undoing the
    mixer's K, which runs after it, on top of restoring the amplitude
    zero-stuffing removes), or 1.0 for a filter with no mixer to compensate.

    Args:
        h: Float-precision filter taps, unit DC gain.
        coef_bits: Target coefficient word width.
        target_dc: The exact DC gain the quantized taps must sum to.

    Returns:
        The quantized, saturated taps at `coef_bits`.
    """
    scale = full_scale(coef_bits)
    q = np.round(h * target_dc * scale).astype(np.int64)
    want = int(round(target_dc * scale))
    q[int(np.argmax(np.abs(q)))] += want - int(q.sum())

    # Checked after the residue correction, not before: the correction lands on
    # the largest tap, so it is exactly the step most likely to push one out of
    # range, and clipping it in sat() below would silently lose the DC gain the
    # correction exists to make exact.
    if would_saturate(q, coef_bits):
        raise ValueError(
            f"coefficients overflow {coef_bits} bits; widen coef_bits or lower the gain"
        )
    q = sat(q, coef_bits)

    # The residue correction above lands on the largest tap, which for a
    # windowed lowpass is the centre one -- and a centre tap is its own mirror,
    # so symmetry survives. That is a property of this filter shape, not a
    # guarantee: at narrow coef_bits the argmax can move off centre and quietly
    # cost the exact linear phase firwin_lowpass went out of its way to build
    # (and break any symmetric-folding FIR in RTL, which assumes h[k]==h[N-1-k]).
    if np.allclose(h, h[::-1]) and not np.array_equal(q, q[::-1]):
        raise ValueError(
            f"quantizing to {coef_bits} bits broke the taps' symmetry, so the "
            f"filter is no longer linear phase: the rounding residue landed on "
            f"tap {int(np.argmax(np.abs(q)))} rather than the centre tap "
            f"{(len(q) - 1) // 2}. Widen coef_bits."
        )
    return q


def fir_decimate(xi, xq, coef, decim, coef_bits, acc_bits, out_bits, shift_mode):
    """Run a decimating FIR on a complex stream.

    Uses valid-only convolution, so every returned sample is a complete
    filter output with no partial edge samples.

    Args:
        xi, xq: Input I/Q samples.
        coef: Quantized filter taps.
        decim: Decimation factor.
        coef_bits: Coefficient word width.
        acc_bits: Accumulator width.
        out_bits: Output word width.
        shift_mode: TRUNC or ROUND, for the output shift.

    Returns:
        An (i, q, n_saturated) tuple: decimated output at `out_bits`, and
        the count of saturated samples across both stages.
    """
    xi = np.asarray(xi, dtype=np.int64)
    xq = np.asarray(xq, dtype=np.int64)
    n_taps = len(coef)
    if xi.size < n_taps:
        raise ValueError(f"need at least {n_taps} samples to fill the filter")

    acc_i = np.convolve(xi, coef, mode="valid")[::decim]
    acc_q = np.convolve(xq, coef, mode="valid")[::decim]
    assert_fits(acc_i, "FIR accumulator")
    assert_fits(acc_q, "FIR accumulator")

    n_sat = would_saturate(acc_i, acc_bits) + would_saturate(acc_q, acc_bits)
    acc_i = sat(acc_i, acc_bits)
    acc_q = sat(acc_q, acc_bits)

    sh = coef_bits - 1
    yi = shr(acc_i, sh, shift_mode)
    yq = shr(acc_q, sh, shift_mode)
    n_sat += would_saturate(yi, out_bits) + would_saturate(yq, out_bits)
    return sat(yi, out_bits), sat(yq, out_bits), n_sat


def fir_interpolate(xi, xq, coef, interp, coef_bits, acc_bits, out_bits, shift_mode):
    """Run an interpolating FIR on a complex stream.

    Zero-stuffs by `interp` (inserts interp-1 zeros between input samples,
    raising the sample rate by that factor) then filters causally, with the
    delay line starting at zero -- the same assumption a real reset filter
    makes, and the reason this is 'full' convolution truncated to the
    zero-stuffed length, not 'valid': unlike fir_decimate, there is no
    window-fill requirement to wait out here, so every output sample counts,
    including the startup transient while the delay line is still filling.
    Correct amplitude depends on the taps already targeting a DC gain that
    includes `interp` (see fir_taps_quantized's target_dc) -- zero-stuffing
    attenuates by 1/interp on its own, and the filter is what restores it.

    This is the direct (zero-stuffed) realization, not the polyphase one the
    RTL implements -- the two are exactly equal (skipping multiplies by
    known zeros changes nothing about the result) only because both are
    causal with the same zero-history convention; using 'valid' convolution
    here would offset the correspondence by n_taps-1 against the polyphase
    formula's plain y[n*interp+p] = sum_k coef[p+k*interp]*x[n-k].

    Args:
        xi, xq: Input I/Q samples, at the pre-interpolation rate.
        coef: Quantized filter taps (DC gain already includes `interp`).
        interp: Interpolation factor.
        coef_bits: Coefficient word width.
        acc_bits: Accumulator width.
        out_bits: Output word width.
        shift_mode: TRUNC or ROUND, for the output shift.

    Returns:
        An (i, q, n_saturated) tuple: interpolated output at `out_bits`,
        length len(xi)*interp (including the startup transient -- there is
        no separate "not yet valid" region the way fir_decimate has), and
        the count of saturated samples across both stages.
    """
    xi = np.asarray(xi, dtype=np.int64)
    xq = np.asarray(xq, dtype=np.int64)

    def zero_stuff(x):
        y = np.zeros(x.size * interp, dtype=np.int64)
        y[::interp] = x
        return y

    zi = zero_stuff(xi)
    zq = zero_stuff(xq)

    # 'full', truncated to the zero-stuffed length: causal, zero initial
    # history, one output per zero-stuffed input sample -- see the docstring
    # for why 'valid' would misalign against the RTL's polyphase formula.
    acc_i = np.convolve(zi, coef, mode="full")[: zi.size]
    acc_q = np.convolve(zq, coef, mode="full")[: zq.size]
    assert_fits(acc_i, "interpolator accumulator")
    assert_fits(acc_q, "interpolator accumulator")

    n_sat = would_saturate(acc_i, acc_bits) + would_saturate(acc_q, acc_bits)
    acc_i = sat(acc_i, acc_bits)
    acc_q = sat(acc_q, acc_bits)

    sh = coef_bits - 1
    yi = shr(acc_i, sh, shift_mode)
    yq = shr(acc_q, sh, shift_mode)
    n_sat += would_saturate(yi, out_bits) + would_saturate(yq, out_bits)
    return sat(yi, out_bits), sat(yq, out_bits), n_sat


def polyphase_decompose(coef, interp):
    """Split flat filter taps into per-phase index lists for a polyphase interpolator.

    Phase p (0 <= p < interp) uses taps at indices p, p+interp, p+2*interp,
    ..., matching y[n*interp+p] = sum_k coef[p+k*interp] * x[n-k] -- the
    standard polyphase identity, equal to fir_interpolate()'s zero-stuffed
    convolution term for term, not an approximation of it (see
    fir_interpolate()'s docstring). When len(coef) is not a multiple of
    interp, the phases are uneven by construction: one phase gets one fewer
    tap than the rest. The RTL reads each phase's tap count from this
    decomposition rather than assuming they are equal.

    Args:
        coef: Quantized filter taps, flat, length N.
        interp: Interpolation factor.

    Returns:
        A list of `interp` index arrays; phase p's array holds the indices
        into `coef` for that phase, in ascending k order.
    """
    n_taps = len(coef)
    return [np.arange(p, n_taps, interp) for p in range(interp)]


# --------------------------------------------------------------------------
# configuration
# --------------------------------------------------------------------------


def _validate_modes(cfg: "DDCConfig") -> None:
    """Validate that mix_arch and shift_mode name a recognised mode.

    Args:
        cfg: The config being validated.

    Raises:
        ValueError: If mix_arch or shift_mode is not one of the defined
            constants.
    """
    if cfg.mix_arch not in (MIX_SEPARATE, MIX_FUSED):
        raise ValueError(f"mix_arch must be {MIX_SEPARATE!r} or {MIX_FUSED!r}")
    if cfg.shift_mode not in (TRUNC, ROUND):
        raise ValueError(f"shift_mode must be {TRUNC!r} or {ROUND!r}")


def _validate_widths(cfg: "DDCConfig") -> None:
    """Validate the phase, angle, and datapath bit-width relationships.

    Args:
        cfg: The config being validated.

    Raises:
        ValueError: If any width relationship the NCO/CORDIC/mixer datapath
            depends on is violated.
    """
    if cfg.ang_bits > cfg.phase_bits:
        raise ValueError("ang_bits cannot exceed phase_bits")
    if cfg.phase_trunc_bits > cfg.phase_bits:
        raise ValueError("phase_trunc_bits (N) cannot exceed phase_bits (M)")
    if cfg.phase_trunc_bits < 3:
        raise ValueError("phase_trunc_bits below 3 cannot even index a quadrant")
    if cfg.ang_bits < cfg.phase_trunc_bits:
        raise ValueError(
            "ang_bits below phase_trunc_bits would truncate the phase a second "
            "time inside the CORDIC; widen ang_bits or lower N"
        )
    if cfg.cordic_bits < cfg.data_bits:
        raise ValueError("cordic_bits below data_bits throws away input precision")
    if cfg.mix_arch == MIX_FUSED and cfg.cordic_bits <= cfg.data_bits:
        raise ValueError(
            "the fused mixer puts the signal through the CORDIC, so cordic_bits "
            "must exceed data_bits to leave headroom for the K ~= 1.647 growth"
        )


def _validate_no_aliasing(cfg: "DDCConfig") -> None:
    """Validate that the FIR cutoff sits below the decimated Nyquist frequency.

    Args:
        cfg: The config being validated.

    Raises:
        ValueError: If fir_cutoff is at or above fs_in / (2 * decim).
    """
    if cfg.fir_cutoff >= cfg.fs_in / (2 * cfg.decim):
        raise ValueError(
            f"cutoff {cfg.fir_cutoff:g} Hz is at or above the decimated Nyquist "
            f"{cfg.fs_in / (2 * cfg.decim):g} Hz -- the output would alias"
        )


def _validate_lo_below_nyquist(cfg: "DDCConfig") -> None:
    """Validate that the LO sits below the input Nyquist frequency.

    An LO above fs_in/2 is not synthesizable as a distinct frequency: the
    phase accumulator wraps and produces its alias instead, so the mixer
    quietly down-converts the wrong band. Deliberate bandpass sampling
    still has an LO inside the first Nyquist zone -- it is the *signal*
    that folds, not the LO -- so this rejects a genuine configuration
    error rather than a valid technique.

    Args:
        cfg: The config being validated.

    Raises:
        ValueError: If f_lo is at or above fs_in / 2.
    """
    if abs(cfg.f_lo) >= cfg.fs_in / 2:
        raise ValueError(
            f"f_lo {cfg.f_lo:g} Hz is at or above Nyquist {cfg.fs_in / 2:g} Hz -- "
            f"the phase accumulator would wrap and mix with the alias instead"
        )


def _validate_cordic_iterations(cfg: "DDCConfig") -> None:
    """Validate n_iter is neither wasted past ang_bits nor short of convergence.

    Args:
        cfg: The config being validated.

    Raises:
        ValueError: If n_iter exceeds what ang_bits can resolve, or is too
            small for the convergence limit to cover the quadrant residual.
    """
    tbl = atan_table(cfg.n_iter, cfg.ang_bits)
    if int(tbl[-1]) == 0:
        raise ValueError(
            f"n_iter={cfg.n_iter} exceeds what ang_bits={cfg.ang_bits} can "
            f"resolve: the last atan entries are 0, so those stages do nothing"
        )
    lim = cordic_convergence_limit(cfg.n_iter)
    if lim < math.pi / 2:
        raise ValueError(
            f"n_iter={cfg.n_iter} gives convergence limit {lim:.4f} rad, below "
            f"the pi/2 the quadrant range reduction needs"
        )


@dataclass(frozen=True)
class DDCConfig:
    """Every value the RTL needs, as a frozen dataclass.

    Defaults target the DE1-SoC's on-board LTC2308 ADC: a 400 kS/s capture
    at an 80 kHz carrier, decimated by 8 to a 50 kS/s complex baseband with
    a 20 kHz passband.

    The rate is the converter's, not a choice, but it is not the LTC2308's
    500 kS/s ceiling either: closing the LTC2308's own conversion timing
    against its *datasheet maximum* -- tCONV up to 1.6us, not the 1.3us
    typical -- needs a 2.5us sample period, i.e. 400 kS/s, on a 50 MHz
    SCK-generating clock. 500 kS/s only closes if the part performs at its
    typical timing, which is a real part in a fixed corner, not a margin.
    fir_cutoff then has to clear the decimated Nyquist of
    fs_in/(2*decim) = 25 kHz, which _validate_no_aliasing() enforces.

    f_lo is deliberately not a binary fraction of fs_in. At 100 kHz
    (fs_in/4) the phase accumulator would divide exactly, exercising no
    phase truncation at all and flattering every spur measurement; 80 kHz
    (fs_in/5) leaves a truncation residue, so the reported SFDR is the one
    the hardware will actually show.
    """

    fs_in: float = 400_000.0
    f_lo: float = 80_000.0
    decim: int = 8
    fir_cutoff: float = 20_000.0
    n_taps: int = 63

    # Widths are trimmed for the TinyTapeout target, where flip-flops are the
    # scarce resource. M=24 still places any LO to 0.14 Hz; ang_bits=17 is the
    # floor at n_iter=16 (at 16 the last atan entries round to zero); and
    # cordic_bits=18 measures *better* than 20, since fewer guard bits means
    # fewer LSBs truncated at the output and floor-mode error is biased.
    phase_bits: int = 24  # M: accumulator width -> frequency resolution
    phase_trunc_bits: int = 14  # N: phase bits that reach the angle path
    ang_bits: int = 17  # CORDIC internal angle width (>= N, zero-padded)
    n_iter: int = 16
    cordic_bits: int = 18  # datapath width inside the CORDIC (data + guard)
    data_bits: int = 16
    coef_bits: int = 16
    acc_bits: int = 40
    out_bits: int = 16

    # Defaults to fused because that is what the RTL implements. Emitting
    # vectors under the separate architecture would produce a set the RTL
    # cannot match, differing in both mix_bits and the coefficients.
    mix_arch: str = MIX_FUSED
    shift_mode: str = TRUNC

    def __post_init__(self):
        _validate_modes(self)
        _validate_widths(self)
        _validate_no_aliasing(self)
        _validate_lo_below_nyquist(self)
        _validate_cordic_iterations(self)

    @property
    def fs_out(self) -> float:
        return self.fs_in / self.decim

    @property
    def phase_inc(self) -> int:
        return int(round(self.f_lo / self.fs_in * (1 << self.phase_bits))) & (
            (1 << self.phase_bits) - 1
        )

    @property
    def f_lo_actual(self) -> float:
        """The LO frequency the hardware actually produces.

        Use this instead of the requested f_lo when comparing against RTL.

        Returns:
            The actual LO frequency in Hz, given the quantized phase_inc.
        """
        return self.phase_inc / (1 << self.phase_bits) * self.fs_in

    @property
    def k_gain(self) -> float:
        return cordic_gain(self.n_iter)

    @property
    def phase_trunc_residue(self) -> int:
        """FCW bits discarded when truncating the phase to N bits.

        Zero means this LO exercises no phase-truncation error, so its
        measured NCO purity should not be quoted as representative.

        Returns:
            The discarded FCW bits; zero if this LO exercises no truncation.
        """
        return self.phase_inc & ((1 << (self.phase_bits - self.phase_trunc_bits)) - 1)

    @property
    def phase_trunc_sfdr_bound_db(self) -> float:
        """Worst-case phase-truncation spur bound, ~6.02*N dBc.

        Depends only on N, not on CORDIC iterations or datapath width.

        Returns:
            The bound in dBc.
        """
        return 6.02 * self.phase_trunc_bits

    @property
    def mix_bits(self) -> int:
        """Width of the mixer output word.

        The fused mixer's output carries the CORDIC gain K > 1, so it needs
        one more bit than the separate mixer's to avoid overflow.

        Returns:
            The mixer output width in bits: data_bits, plus one for the
            fused architecture.
        """
        return self.data_bits + (1 if self.mix_arch == MIX_FUSED else 0)


# --------------------------------------------------------------------------
# the model
# --------------------------------------------------------------------------


class DDC:
    """Bit-exact fixed-point DDC model.

    `run()` returns every intermediate stage's output, so an RTL mismatch
    can be localized to one stage.
    """

    def __init__(self, cfg: DDCConfig | None = None):
        self.cfg = cfg or DDCConfig()
        c = self.cfg
        self.atan = atan_table(c.n_iter, c.ang_bits)
        self.h_float = firwin_lowpass(c.n_taps, c.fir_cutoff / (c.fs_in / 2))
        self.fold_inv_k = c.mix_arch == MIX_FUSED
        rx_target_dc = (1.0 / c.k_gain) if self.fold_inv_k else 1.0
        self.coef = fir_taps_quantized(self.h_float, c.coef_bits, rx_target_dc)

        # TX interpolator: same filter shape, but sits *before* the mixer, so
        # it has to both restore the amplitude zero-stuffing removes (a
        # factor of `decim`, reused here as the interpolation factor -- RX
        # and TX are a mirror image at the same rate change) and pre-cancel
        # the mixer's K, which now runs after it rather than before. Only
        # meaningful for the fused mixer, which is the only one with an
        # up-convert path (see mix_stage()); computed unconditionally anyway
        # since it is cheap and mix_stage() is what actually gates TX use.
        self.coef_interp = fir_taps_quantized(
            self.h_float, c.coef_bits, c.decim / c.k_gain
        )

    # -- phase -----------------------------------------------------------

    def angle_word(self, phase: np.ndarray) -> np.ndarray:
        """Convert the M-bit accumulator phase to the CORDIC's angle input.

        Truncates to N bits, then zero-pads to ang_bits so the CORDIC
        converges without re-quantizing. Shared by the NCO and the fused
        mixer.

        Args:
            phase: M-bit phase accumulator values.

        Returns:
            The ang_bits-wide angle word the CORDIC receives.
        """
        c = self.cfg
        truncated = shr(phase, c.phase_bits - c.phase_trunc_bits)
        return truncated << np.int64(c.ang_bits - c.phase_trunc_bits)

    def phase(self, n: int, phase0: int = 0, inc: int | None = None) -> np.ndarray:
        """Compute phase accumulator output: (phase0 + n*inc) mod 2**phase_bits.

        Args:
            n: Number of samples to generate.
            phase0: Initial phase.
            inc: FCW to use instead of the configured one; `report()` uses
                this to measure the NCO at an LO that exercises phase
                truncation.

        Returns:
            The phase accumulator sequence, one value per sample.
        """
        c = self.cfg
        mask = (1 << c.phase_bits) - 1
        step = c.phase_inc if inc is None else (int(inc) & mask)
        return (phase0 + np.arange(n, dtype=np.int64) * step) & mask

    def nco(self, phase: np.ndarray):
        """Convert a phase word to (cos, sin) at data_bits, unit amplitude.

        Saturates at full_scale-1 rather than +1.0, since a signed word
        cannot represent exactly 1.0.

        Args:
            phase: Angle-domain phase values, at the accumulator's M-bit
                width.

        Returns:
            A (cos, sin) tuple, each at data_bits.
        """
        c = self.cfg
        q, rem = quadrant_split(self.angle_word(phase), c.ang_bits)
        x0 = np.full(rem.shape, int(round(full_scale(c.cordic_bits) / c.k_gain)), np.int64)
        y0 = np.zeros(rem.shape, np.int64)
        # The seed is round(full_scale/K), so the K growth lands on full_scale
        # -- one LSB above the largest representable value. At the extreme ends
        # of the residual range (about ten of 32768 residuals) the result does
        # therefore clip, by exactly that one LSB. The count is discarded rather
        # than propagated because the clip is invisible downstream: shifting
        # down to data_bits maps both full_scale and full_scale-1 to the same
        # saturated output. Reporting it would make n_saturated fire on half of
        # all NCO samples for a benign off-by-one.
        x, y, _, _ = cordic_rotate(x0, y0, rem, self.atan, c.cordic_bits, c.shift_mode)
        cos, sin = apply_quadrant_sincos(q, x, y)
        sh = c.cordic_bits - c.data_bits
        return sat(shr(cos, sh, c.shift_mode), c.data_bits), sat(
            shr(sin, sh, c.shift_mode), c.data_bits
        )

    # -- mixers ----------------------------------------------------------

    def mix_separate(self, xi, xq, cos, sin):
        """Mix (xi + j*xq) with (cos - j*sin), four real multiplies.

        Multiplies by the NCO's conjugate to down-convert. With a real
        input, two of the four multiplies are zero.

        Args:
            xi, xq: Input I/Q samples, at data_bits.
            cos, sin: NCO output, at data_bits.

        Returns:
            A (i, q) tuple of mixed output, each at data_bits.
        """
        c = self.cfg
        xi = np.asarray(xi, np.int64)
        xq = np.asarray(xq, np.int64)
        pi = xi * cos + xq * sin
        pq = xq * cos - xi * sin
        assert_fits(pi, "mixer product")
        assert_fits(pq, "mixer product")
        sh = c.data_bits - 1
        return sat(shr(pi, sh, c.shift_mode), c.data_bits), sat(
            shr(pq, sh, c.shift_mode), c.data_bits
        )

    def mix_fused(self, xi, xq, phase, downconvert: bool = True):
        """Rotate the input vector by -/+theta directly: the rotation is the mix.

        No complex multiplier at all. The CORDIC output carries the gain K,
        removed later in the FIR/interpolator coefficients.

        `downconvert` is a runtime input on silicon, not a build-time
        parameter, since the taped-out part must serve both RX and TX. Both
        values therefore have to be verified against this same model; a
        parameter would let one of them reach the die unexercised.

        Args:
            xi, xq: Input I/Q samples, at data_bits.
            phase: Accumulator phase for each sample.
            downconvert: True to rotate by -theta (RX), False by +theta (TX).

        Returns:
            A (i, q) tuple of mixed output, each at mix_bits.
        """
        c = self.cfg
        q, rem = quadrant_split(self.angle_word(phase), c.ang_bits)
        ri, rq = prerotate_conj(
            q, np.asarray(xi, np.int64), np.asarray(xq, np.int64), downconvert
        )
        # One guard bit for the K growth. The headroom this buys is against the
        # complex envelope, not the per-axis word: the rotation is exact only
        # while |xi + j*xq| <= 2/K ~= 1.21 x full scale, and arbitrary IQ can
        # reach sqrt(2). Clipping past that happens *inside* the rotation, so
        # the count comes back from cordic_rotate. Checking only the seeding,
        # as this used to, reports zero while the band is being corrupted --
        # and could not have reported anything anyway, since g leaves the
        # seeded value a factor of two inside cordic_bits by construction.
        g = c.cordic_bits - c.data_bits - 1
        z0 = -rem if downconvert else rem
        x, y, _, n_rot = cordic_rotate(
            ri << np.int64(g), rq << np.int64(g), z0, self.atan,
            c.cordic_bits, c.shift_mode,
        )
        self._fused_sat = n_rot
        return sat(shr(x, g, c.shift_mode), c.mix_bits), sat(
            shr(y, g, c.shift_mode), c.mix_bits
        )

    # -- top level -------------------------------------------------------

    def mix_stage(self, xi, xq=None, phase0: int = 0, downconvert: bool = True) -> dict:
        """Run phase -> NCO -> mixer, stopping before the filter.

        This is exactly the scope of the taped-out design: the FIR is not on
        the die, so the mixer stage is what RTL vectors have to cover, in
        both directions.

        Args:
            xi: Input I samples, at data_bits.
            xq: Input Q samples, at data_bits. None for a real-valued input,
                in which case Q is treated as zero.
            phase0: Initial NCO phase.
            downconvert: True for RX (rotate by -theta), False for TX (+theta).

        Returns:
            A dict of phase, cos, sin, mix_i, mix_q, stim_i, stim_q, and
            n_mix_saturated.
        """
        c = self.cfg
        xi = sat(np.asarray(xi, np.int64), c.data_bits)
        xq = np.zeros_like(xi) if xq is None else sat(np.asarray(xq, np.int64), c.data_bits)
        if xi.shape != xq.shape:
            raise ValueError(f"I/Q length mismatch: {xi.shape} vs {xq.shape}")

        ph = self.phase(len(xi), phase0)
        cos, sin = self.nco(ph)
        self._fused_sat = 0
        if c.mix_arch == MIX_SEPARATE:
            if not downconvert:
                raise ValueError(
                    "mix_arch='separate' models down-conversion only; the "
                    "up-convert path exists solely in the fused architecture, "
                    "which is what the RTL implements"
                )
            mi, mq = self.mix_separate(xi, xq, cos, sin)
        else:
            mi, mq = self.mix_fused(xi, xq, ph, downconvert)
        n_mix_sat = self._fused_sat + would_saturate(mi, c.mix_bits) + would_saturate(
            mq, c.mix_bits
        )
        return {
            "phase": ph, "cos": cos, "sin": sin,
            "mix_i": mi, "mix_q": mq,
            "stim_i": xi, "stim_q": xq,
            "n_mix_saturated": n_mix_sat,
        }

    def run(self, xi, xq=None, phase0: int = 0) -> dict:
        """Run the full DDC over a stimulus.

        Down-convert only: the decimating FIR that follows the mixer is the
        RX filter. The TX chain interpolates *before* the mixer, so it is not
        this function with a flag flipped; use mix_stage() for the TX mixer
        until the interpolator exists.

        Args:
            xi: Input I samples, at data_bits.
            xq: Input Q samples, at data_bits. None for a real-valued input,
                in which case Q is treated as zero.
            phase0: Initial NCO phase.

        Returns:
            A dict of every stage's output: phase, cos, sin, mix_i, mix_q,
            out_i, out_q, stim_i, stim_q, and n_saturated.
        """
        c = self.cfg
        m = self.mix_stage(xi, xq, phase0, downconvert=True)
        yi, yq, n_sat = fir_decimate(
            m["mix_i"], m["mix_q"], self.coef, c.decim, c.coef_bits, c.acc_bits,
            c.out_bits, c.shift_mode,
        )
        n_sat += m.pop("n_mix_saturated")
        return {**m, "out_i": yi, "out_q": yq, "n_saturated": n_sat}

    def tx_stage(self, xi, xq=None, phase0: int = 0) -> dict:
        """Run the full TX chain: interpolate, then up-convert.

        The mirror of run(), but not run() with a flag: run() is
        mixer(down) -> decimate, this is interpolate -> mixer(up) -- the
        filter and mixer swap order, so it is a different pipeline, not the
        same one reversed.

        Args:
            xi: Input baseband I samples, at data_bits.
            xq: Input baseband Q samples, at data_bits. None for a
                real-valued input, in which case Q is treated as zero.
            phase0: Initial NCO phase.

        Returns:
            A dict: interp_i, interp_q (the pre-mixer, interpolated-rate
            signal, at data_bits), mix_i, mix_q (the RF-rate output, at
            mix_bits), stim_i, stim_q, and n_saturated.
        """
        c = self.cfg
        xi = sat(np.asarray(xi, np.int64), c.data_bits)
        xq = np.zeros_like(xi) if xq is None else sat(np.asarray(xq, np.int64), c.data_bits)
        if xi.shape != xq.shape:
            raise ValueError(f"I/Q length mismatch: {xi.shape} vs {xq.shape}")

        ii, iq, n_interp_sat = fir_interpolate(
            xi, xq, self.coef_interp, c.decim, c.coef_bits, c.acc_bits,
            c.data_bits, c.shift_mode,
        )
        m = self.mix_stage(ii, iq, phase0, downconvert=False)
        n_sat = n_interp_sat + m.pop("n_mix_saturated")
        return {
            "interp_i": ii, "interp_q": iq,
            "mix_i": m["mix_i"], "mix_q": m["mix_q"],
            "stim_i": xi, "stim_q": xq,
            "n_saturated": n_sat,
        }


# --------------------------------------------------------------------------
# the ideal (float) model
# --------------------------------------------------------------------------


def ddc_ideal(xi, xq, cfg: DDCConfig, h: np.ndarray, phase0: int = 0):
    """Compute the float64 DDC output: the intended answer, with no quantization.

    Normalized so full scale is 1.0, matching the fixed-point model's scale.
    Uses the actual quantized LO frequency and the float filter taps, so
    the result isolates datapath error from LO placement and filter design.

    Args:
        xi, xq: Input I/Q samples, integers at cfg.data_bits.
        cfg: The DDC configuration.
        h: Float-precision FIR taps.
        phase0: Initial NCO phase.

    Returns:
        The normalised complex baseband output, decimated and valid-only.
    """
    x = (np.asarray(xi, float) + 1j * np.asarray(xq, float)) / full_scale(cfg.data_bits)
    n = np.arange(len(x))
    ph = 2 * np.pi * cfg.f_lo_actual / cfg.fs_in * n + 2 * np.pi * phase0 / (
        1 << cfg.phase_bits
    )
    # Same valid-only convolution and decimation phase as fir_decimate, so
    # the two models stay sample-aligned.
    y = np.convolve(x * np.exp(-1j * ph), h, mode="valid")[:: cfg.decim]
    return y


def mix_ideal(xi, xq, cfg: DDCConfig, phase0: int = 0, downconvert: bool = True):
    """Compute the float64 mixer output: K * x * exp(-/+ j*theta), unfiltered.

    The K is kept rather than divided out, because the fixed-point mixer's
    output carries it -- the 1/K correction lives downstream in the filter
    coefficients. Comparing against a K-free reference would report the gain
    as error and hide everything smaller.

    Args:
        xi, xq: Input I/Q samples, integers at cfg.data_bits.
        cfg: The DDC configuration.
        phase0: Initial NCO phase.
        downconvert: True to rotate by -theta, False by +theta.

    Returns:
        The normalised complex mixer output, one value per input sample.
    """
    x = (np.asarray(xi, float) + 1j * np.asarray(xq, float)) / full_scale(cfg.data_bits)
    n = np.arange(len(x))
    ph = 2 * np.pi * cfg.f_lo_actual / cfg.fs_in * n + 2 * np.pi * phase0 / (
        1 << cfg.phase_bits
    )
    sign = -1.0 if downconvert else 1.0
    return cfg.k_gain * x * np.exp(sign * 1j * ph)


# --------------------------------------------------------------------------
# metrics
# --------------------------------------------------------------------------


def snr_db(ref: np.ndarray, test: np.ndarray, skip: int = 0) -> float:
    """Compute the SNR of `test` against `ref`, both complex, in dB.

    Args:
        ref: Reference signal.
        test: Signal under test.
        skip: Leading samples to drop before scoring.

    Returns:
        SNR in dB, or inf if the two signals are identical.
    """
    r, t = ref[skip:], test[skip:]
    p_sig = float(np.mean(np.abs(r) ** 2))
    p_err = float(np.mean(np.abs(t - r) ** 2))
    if p_err == 0.0:
        return float("inf")
    return 10.0 * math.log10(p_sig / p_err)


def sfdr_db(y: np.ndarray, skip: int = 0) -> float:
    """Compute the spurious-free dynamic range of a single-tone output, in dB.

    Compares the carrier bin against the largest other bin. Requires a
    single-tone input. On a two-tone stimulus the largest other bin is just
    the second tone.

    Args:
        y: Complex output signal, single-tone.
        skip: Leading samples to drop.

    Returns:
        SFDR in dB, nan if too few samples remain, inf if no spur is found.
    """
    y = y[skip:]
    if len(y) < 64:
        return float("nan")

    # Blackman-Harris window: -92 dB sidelobes keep off-bin leakage below the
    # spurs being measured. The 8-bin guard matches its wider main lobe.
    n = len(y)
    m_ = np.arange(n)
    a = (0.35875, 0.48829, 0.14128, 0.01168)
    w = (
        a[0]
        - a[1] * np.cos(2 * np.pi * m_ / (n - 1))
        + a[2] * np.cos(4 * np.pi * m_ / (n - 1))
        - a[3] * np.cos(6 * np.pi * m_ / (n - 1))
    )
    spec = np.abs(np.fft.fft(y * w))
    peak = int(np.argmax(spec))
    guard = 8
    masked = spec.copy()
    for d in range(-guard, guard + 1):
        masked[(peak + d) % n] = 0.0
    spur = float(np.max(masked))
    if spur == 0.0:
        return float("inf")
    return 20.0 * math.log10(spec[peak] / spur)


def effective_bits(snr: float) -> float:
    """SNR -> ENOB, via the usual 6.02N + 1.76 sine-wave relation."""
    return (snr - 1.76) / 6.02


# --------------------------------------------------------------------------
# stimulus
# --------------------------------------------------------------------------


def tone(n: int, fs: float, f: float, amp_dbfs: float, bits: int, phase: float = 0.0):
    """Generate a complex tone at `f` Hz, quantized to `bits`.

    Args:
        n: Number of samples.
        fs: Sample rate in Hz.
        f: Tone frequency in Hz.
        amp_dbfs: Amplitude relative to full scale, in dB.
        bits: Output word width.
        phase: Starting phase in radians.

    Returns:
        An (i, q) tuple of integer samples at `bits`.
    """
    a = full_scale(bits) * (10.0 ** (amp_dbfs / 20.0))
    t = np.arange(n)
    z = a * np.exp(1j * (2 * np.pi * f / fs * t + phase))
    return (
        sat(np.round(z.real).astype(np.int64), bits),
        sat(np.round(z.imag).astype(np.int64), bits),
    )


def two_tone(n: int, cfg: DDCConfig, offsets=(5_000.0, -12_000.0), amp_dbfs=-6.0):
    """Generate an in-band tone plus a second one, both offset from the LO.

    Includes one negative-offset tone, so a mirrored spectrum swaps the two
    tones instead of passing silently.

    Both defaults sit inside the FIR's passband, which is what makes an SNR
    measured on this stimulus meaningful: a tone beyond fir_cutoff is
    attenuated *by design*, and scoring the output against an ideal model
    that also filters it measures mostly filtered-out noise. The offsets are
    fixed rather than tied to fir_cutoff -- 5/12 kHz clears the current
    20 kHz cutoff with comfortable margin, but a future rescale that shrinks
    the passband below 12 kHz would need these revisited.

    Args:
        n: Number of samples.
        cfg: The DDC configuration, for fs_in, f_lo_actual, and data_bits.
        offsets: Frequency offsets from the LO, in Hz. Keep |offset| below
            cfg.fir_cutoff or the tone is filtered rather than measured.
        amp_dbfs: Combined amplitude relative to full scale, in dB.

    Returns:
        An (i, q) tuple of integer samples at cfg.data_bits.
    """
    for off in offsets:
        if abs(off) >= cfg.fir_cutoff:
            raise ValueError(
                f"tone offset {off:g} Hz is at or beyond the FIR cutoff "
                f"{cfg.fir_cutoff:g} Hz, so it is attenuated by design -- "
                f"measuring against it reports filter rolloff as datapath error"
            )
    zi = np.zeros(n, np.int64)
    zq = np.zeros(n, np.int64)
    per = amp_dbfs - 20 * math.log10(len(offsets))
    for k, off in enumerate(offsets):
        i, q = tone(n, cfg.fs_in, cfg.f_lo_actual + off, per, cfg.data_bits, 0.3 * k)
        zi, zq = zi + i, zq + q
    return sat(zi, cfg.data_bits), sat(zq, cfg.data_bits)


# --------------------------------------------------------------------------
# test-vector emission
# --------------------------------------------------------------------------


def _hex_lines(a: np.ndarray, bits: int) -> list[str]:
    """Format values as two's-complement hex, one per line, for $readmemh.

    Args:
        a: Values to format.
        bits: Word width.

    Returns:
        One hex string per value, zero-padded to the word width.
    """
    mask = (1 << bits) - 1
    nib = (bits + 3) // 4
    return [format(int(v) & mask, f"0{nib}x") for v in np.asarray(a).ravel()]


def _write_hex_files(out_dir: str, files: dict) -> None:
    """Write each array in `files` to its own $readmemh-style hex file.

    Args:
        out_dir: Directory to write into.
        files: Maps file name to an (array, bits) pair.
    """
    for name, (arr, bits) in files.items():
        with open(os.path.join(out_dir, name), "w", newline="\n") as f:
            f.write("\n".join(_hex_lines(arr, bits)) + "\n")


def emit_vectors(ddc: DDC, out_dir: str, n: int = 4096) -> dict:
    """Write stimulus, per-stage expected values, and the RTL parameter header.

    The testbench reads these values rather than recomputing them, so a
    sign error shared by both implementations cannot hide.

    Args:
        ddc: The DDC model to generate vectors from.
        out_dir: Directory to write the hex files, params header, and
            manifest into.
        n: Stimulus length in samples.

    Returns:
        The manifest dict that was also written to manifest.json.
    """
    c = ddc.cfg
    os.makedirs(out_dir, exist_ok=True)
    xi, xq = two_tone(n, c)
    r = ddc.run(xi, xq)

    files = {
        "stim_i.hex": (r["stim_i"], c.data_bits),
        "stim_q.hex": (r["stim_q"], c.data_bits),
        "nco_cos.hex": (r["cos"], c.data_bits),
        "nco_sin.hex": (r["sin"], c.data_bits),
        "mix_i.hex": (r["mix_i"], c.mix_bits),
        "mix_q.hex": (r["mix_q"], c.mix_bits),
        "out_i.hex": (r["out_i"], c.out_bits),
        "out_q.hex": (r["out_q"], c.out_bits),
        "fir_coef.hex": (ddc.coef, c.coef_bits),
    }

    # The up-convert direction, over the same stimulus and the same phase0, so
    # a testbench can flip the direction input mid-stream and check both
    # against one stimulus set. Only the fused mixer has an up-convert path.
    up = None
    if c.mix_arch == MIX_FUSED:
        up = ddc.mix_stage(xi, xq, downconvert=False)
        files["mix_up_i.hex"] = (up["mix_i"], c.mix_bits)
        files["mix_up_q.hex"] = (up["mix_q"], c.mix_bits)

    # TX chain vectors: baseband-rate stimulus in, both the pre-mixer
    # (interp_i/q, checks fir_interpolate.sv standalone) and post-mixer
    # (tx_mix_i/q, checks tx_top end to end) outputs, from one call to
    # tx_stage() so the two stages cannot desync from each other.
    n_tx = 512
    tx_i = tx_q = None
    if c.mix_arch == MIX_FUSED:
        t = np.arange(n_tx)
        a = full_scale(c.data_bits) * (10.0 ** (-6.0 / 20.0)) / 2.0
        z = a * np.exp(1j * 2 * np.pi * 40_000.0 / c.fs_out * t) + \
            a * np.exp(1j * 2 * np.pi * -25_000.0 / c.fs_out * t + 0.7j)
        tx_i = sat(np.round(z.real).astype(np.int64), c.data_bits)
        tx_q = sat(np.round(z.imag).astype(np.int64), c.data_bits)
        tx = ddc.tx_stage(tx_i, tx_q)
        files["tx_stim_i.hex"] = (tx_i, c.data_bits)
        files["tx_stim_q.hex"] = (tx_q, c.data_bits)
        files["interp_i.hex"] = (tx["interp_i"], c.data_bits)
        files["interp_q.hex"] = (tx["interp_q"], c.data_bits)
        files["tx_mix_i.hex"] = (tx["mix_i"], c.mix_bits)
        files["tx_mix_q.hex"] = (tx["mix_q"], c.mix_bits)

    _write_hex_files(out_dir, files)

    svh = os.path.join(out_dir, "ddc_params.svh")
    with open(svh, "w", newline="\n") as f:
        f.write(_params_svh(ddc, n, len(r["out_i"]), n_tx, None if tx_i is None else len(tx["interp_i"])))

    manifest = {
        "config": asdict(c),
        "derived": {
            "fs_out": c.fs_out,
            "phase_inc": c.phase_inc,
            "f_lo_actual": c.f_lo_actual,
            "k_gain": c.k_gain,
            "inv_k_folded_into_coefficients": ddc.fold_inv_k,
            "n_input_samples": n,
            "n_output_samples": len(r["out_i"]),
            "n_saturated": r["n_saturated"],
            "n_saturated_upconvert": None if up is None else up["n_mix_saturated"],
            "n_tx_stim_samples": None if tx_i is None else n_tx,
            "n_interp_samples": None if tx_i is None else len(tx["interp_i"]),
            "n_saturated_tx": None if tx_i is None else tx["n_saturated"],
        },
        "files": sorted(files) + ["ddc_params.svh"],
    }
    with open(os.path.join(out_dir, "manifest.json"), "w", newline="\n") as f:
        json.dump(manifest, f, indent=2)
        f.write("\n")
    return manifest


def _params_svh(ddc: DDC, n_in: int, n_out: int, n_tx: int | None = None, n_interp: int | None = None) -> str:
    """Render the RTL parameter header for the given DDC configuration.

    Args:
        ddc: The DDC model the parameters are drawn from.
        n_in: Stimulus length in samples, for the N_STIM localparam.
        n_out: Output length in samples, for the N_OUT localparam.
        n_tx: TX baseband stimulus length, for N_TX_STIM. None if TX vectors
            were not emitted (mix_arch is not fused).
        n_interp: Interpolator output length, for N_INTERP_OUT. None along
            with n_tx.

    Returns:
        The contents of ddc_params.svh as a string.
    """
    c = ddc.cfg
    return f"""// Generated by cordic/reference/ddc_reference.py -- do not edit by hand.
// Regenerate:  python cordic/reference/ddc_reference.py --emit-vectors <dir>
`ifndef DDC_PARAMS_SVH
`define DDC_PARAMS_SVH

// M: phase accumulator width. Sets frequency resolution, fs/2^M =
// {c.fs_in / (1 << c.phase_bits):.6f} Hz.
localparam int PHASE_BITS  = {c.phase_bits};
// N: phase bits that reach the angle path. Sets spectral purity -- the
// worst-case phase-truncation spur bound is ~6.02*N = {c.phase_trunc_sfdr_bound_db:.1f} dBc,
// and no CORDIC width or iteration count buys past it.
localparam int PHASE_TRUNC_BITS = {c.phase_trunc_bits};
// CORDIC internal angle width. >= N, with the truncated phase zero-padded into
// it. Kept wider than N so the rotation converges on the truncated angle
// instead of quantizing it a second time; at N={c.phase_trunc_bits} an N-wide z register
// would cap useful iterations at 13.
localparam int ANG_BITS    = {c.ang_bits};
localparam int N_ITER      = {c.n_iter};
localparam int CORDIC_BITS = {c.cordic_bits};
localparam int DATA_BITS   = {c.data_bits};
localparam int COEF_BITS   = {c.coef_bits};
localparam int MIX_BITS    = {c.mix_bits};   // {"data_bits + 1: headroom for the fused mixer's K growth"
                                if c.mix_arch == MIX_FUSED else
                                "= data_bits: the separate mixer preserves magnitude"}
localparam int ACC_BITS    = {c.acc_bits};
localparam int OUT_BITS    = {c.out_bits};
localparam int N_TAPS      = {c.n_taps};
localparam int DECIM       = {c.decim};

// Phase accumulator increment for f_lo = {c.f_lo:.0f} Hz at fs = {c.fs_in:.0f} Hz.
// The LO the hardware actually produces is {c.f_lo_actual:.6f} Hz.
// Bits falling below the N-bit truncation point: {c.phase_trunc_residue}.
// {"Note: zero -- this LO is a binary fraction of fs, so it exercises no phase" if c.phase_trunc_residue == 0 else "This LO exercises phase truncation, so the spurs are real here."}
// {"truncation at all. Do not characterise the NCO at this LO alone." if c.phase_trunc_residue == 0 else ""}
localparam logic [PHASE_BITS-1:0] PHASE_INC = {c.phase_bits}'h{c.phase_inc:0{(c.phase_bits + 3) // 4}x};

// CORDIC gain K = {c.k_gain:.10f} for N_ITER={c.n_iter}.
// 1/K is {"folded into FIR_COEF below (fused mixer scales the signal by K)"
         if ddc.fold_inv_k else
         "applied at the NCO seed X0 (separate mixer: sin/cos are unit amplitude)"}.
localparam logic signed [CORDIC_BITS-1:0] CORDIC_X0 =
    {c.cordic_bits}'sd{int(round(full_scale(c.cordic_bits) / c.k_gain))};

localparam int SHIFT_ROUNDS = {1 if c.shift_mode == ROUND else 0};  // 0 = truncate

localparam int N_STIM = {n_in};
localparam int N_OUT  = {n_out};
{f'''
// TX interpolator vectors -- see rx/gen_fir_coef.py for the coefficient
// table these check against (fir_interp_coef_table.svh), generated
// separately since it is not folded the way the decimator's is.
localparam int N_TX_STIM   = {n_tx};
localparam int N_INTERP_OUT = {n_interp};
''' if n_tx is not None else ''}
`endif
"""


# --------------------------------------------------------------------------
# reporting
# --------------------------------------------------------------------------


def _measure_nco_purity(ddc: DDC, cfg: DDCConfig, n: int) -> dict:
    """Measure NCO spectral purity at the configured LO and at a harder one.

    Args:
        ddc: The DDC model to measure.
        cfg: The DDC configuration.
        n: Number of NCO samples to generate.

    Returns:
        A dict with nco_snr_db, nco_sfdr_db, nco_sfdr_hard_lo_db, and
        hard_lo_hz.
    """
    # Purity at the configured LO, independent of the signal path.
    ph = ddc.phase(n)
    cos, sin = ddc.nco(ph)
    nco_c = (cos + 1j * sin).astype(complex) / full_scale(cfg.data_bits)
    ideal_nco = np.exp(1j * 2 * np.pi * cfg.f_lo_actual / cfg.fs_in * np.arange(n))

    # And at an LO whose FCW has nonzero low bits, so truncation actually
    # occurs.
    hard_inc = (cfg.phase_inc + 0x0002AAAB) & ((1 << cfg.phase_bits) - 1)
    hard_cos, hard_sin = ddc.nco(ddc.phase(n, inc=hard_inc))
    hard_c = (hard_cos + 1j * hard_sin).astype(complex) / full_scale(cfg.data_bits)

    return {
        "nco_snr_db": snr_db(ideal_nco, nco_c),
        "nco_sfdr_db": sfdr_db(nco_c),
        "nco_sfdr_hard_lo_db": sfdr_db(hard_c),
        "hard_lo_hz": hard_inc / (1 << cfg.phase_bits) * cfg.fs_in,
    }


def _measure_ddc_quality(ddc: DDC, cfg: DDCConfig, n: int) -> dict:
    """Measure the fixed-point DDC's SNR/SFDR against the ideal model.

    Args:
        ddc: The DDC model to measure.
        cfg: The DDC configuration.
        n: Stimulus length in samples.

    Returns:
        A dict with ddc_snr_db, ddc_enob, ddc_sfdr_db, and n_saturated.
    """
    # Normalised by data_bits, not out_bits. The FIR's coefficients carry a DC
    # gain of 1 (with 1/K folded in for the fused mixer), so the output lands
    # back at *input* scale regardless of how wide the output word is. Dividing
    # by full_scale(out_bits) instead would make any out_bits != data_bits
    # config report a scale mismatch as if it were datapath error -- at
    # data_bits=14, out_bits=16 that reads 2.5 dB for output which is in fact
    # bit-identical to the out_bits=14 case and scores 67.4 dB.
    scale = full_scale(cfg.data_bits)

    xi, xq = two_tone(n, cfg)
    r = ddc.run(xi, xq)
    ref = ddc_ideal(xi, xq, cfg, ddc.h_float)
    fixed = (r["out_i"] + 1j * r["out_q"]).astype(complex) / scale

    # SFDR needs a single tone, measured separately at an offset away from
    # DC and the band edge. The offset is derived from fir_cutoff rather
    # than fixed: a hardcoded 37 kHz was comfortably inside the passband at
    # an earlier, wider config, but at fir_cutoff=20 kHz (decimated Nyquist
    # 25 kHz) it aliased back into the measured band, and the measurement
    # collapsed from ~58 dB to ~8 dB -- not a datapath regression, just a
    # tone that had quietly stopped being in-band.
    si, sq = tone(n, cfg.fs_in, cfg.f_lo_actual + cfg.fir_cutoff / 2.0, -6.0, cfg.data_bits)
    rs = ddc.run(si, sq)
    single = (rs["out_i"] + 1j * rs["out_q"]).astype(complex) / scale

    skip = 0
    snr = snr_db(ref, fixed, skip)
    return {
        "ddc_snr_db": snr,
        "ddc_enob": effective_bits(snr),
        "ddc_sfdr_db": sfdr_db(single, skip),
        "n_saturated": r["n_saturated"] + rs["n_saturated"],
    }


def report(cfg: DDCConfig, n: int = 8192) -> dict:
    """Measure and collect the DDC's key SNR/SFDR figures for one config.

    Args:
        cfg: The DDC configuration to measure.
        n: Stimulus length in samples.

    Returns:
        A dict of the figures printed by `_print_report()`.
    """
    ddc = DDC(cfg)
    out = {
        "fs_out": cfg.fs_out,
        "f_lo_actual": cfg.f_lo_actual,
        "f_lo_error_hz": cfg.f_lo_actual - cfg.f_lo,
        "k_gain": cfg.k_gain,
        "inv_k_in_coefficients": ddc.fold_inv_k,
        "coef_dc_gain": float(ddc.coef.sum()) / full_scale(cfg.coef_bits),
        "phase_trunc_residue": cfg.phase_trunc_residue,
        "phase_trunc_bound_db": cfg.phase_trunc_sfdr_bound_db,
        "convergence_limit_rad": cordic_convergence_limit(cfg.n_iter),
    }
    out.update(_measure_nco_purity(ddc, cfg, n))
    out.update(_measure_ddc_quality(ddc, cfg, n))
    return out


def _print_report(cfg: DDCConfig, m: dict) -> None:
    """Print the figures from `report()` in human-readable form.

    Args:
        cfg: The DDC configuration the figures were measured under.
        m: The dict returned by `report(cfg, ...)`.
    """
    print(f"  mixer architecture     {cfg.mix_arch}")
    print(f"  shift mode             {cfg.shift_mode}")
    print(f"  fs in / out            {cfg.fs_in / 1e6:.3f} MS/s -> {m['fs_out'] / 1e3:.1f} kS/s  (/{cfg.decim})")
    print(f"  LO requested / actual  {cfg.f_lo / 1e3:.3f} kHz / {m['f_lo_actual'] / 1e3:.6f} kHz  (err {m['f_lo_error_hz']:+.6f} Hz)")
    print(f"  phase accum (M)        {cfg.phase_bits} bits  ->  resolution "
          f"{cfg.fs_in / (1 << cfg.phase_bits):.6f} Hz")
    print(f"  phase to angle (N)     {cfg.phase_trunc_bits} bits  ->  angle LSB "
          f"{2 * math.pi / (1 << cfg.phase_trunc_bits):.3e} rad, "
          f"spur bound ~{m['phase_trunc_bound_db']:.1f} dBc")
    print(f"  CORDIC angle width     {cfg.ang_bits} bits internal "
          f"(N zero-padded by {cfg.ang_bits - cfg.phase_trunc_bits})")
    print(f"  CORDIC K               {m['k_gain']:.10f}  ({cfg.n_iter} iterations)")
    print(f"  1/K removed at         {'FIR coefficients' if m['inv_k_in_coefficients'] else 'NCO seed'}")
    print(f"  FIR DC gain            {m['coef_dc_gain']:.6f}  (target {1 / m['k_gain']:.6f})"
          if m["inv_k_in_coefficients"] else
          f"  FIR DC gain            {m['coef_dc_gain']:.6f}  (target 1.000000)")
    print(f"  convergence limit      {m['convergence_limit_rad']:.4f} rad  (need >= {math.pi / 2:.4f})")
    print()
    print(f"  NCO   SNR {m['nco_snr_db']:7.2f} dB    SFDR {m['nco_sfdr_db']:7.2f} dB "
          f"(at the configured LO)")
    if m["phase_trunc_residue"] == 0:
        print(f"        ^ this LO is a binary fraction of fs, so no phase truncation")
        print(f"          occurs and N={cfg.phase_trunc_bits} costs nothing here. Do not")
        print(f"          quote this figure as the NCO's spectral purity.")
    print(f"  NCO   SFDR {m['nco_sfdr_hard_lo_db']:6.2f} dB at {m['hard_lo_hz'] / 1e3:.3f} kHz "
          f"-- an LO that does exercise the N-bit truncation")
    print(f"  DDC   SNR {m['ddc_snr_db']:7.2f} dB    SFDR {m['ddc_sfdr_db']:7.2f} dB    ENOB {m['ddc_enob']:.2f} bits")
    if m["n_saturated"]:
        print(f"  !! {m['n_saturated']} samples saturated -- back the input off or widen the datapath")


def _run_compare_arch(cfg: DDCConfig, n: int) -> None:
    """Print the separate and fused architectures side by side.

    Args:
        cfg: Base configuration; mix_arch is overridden per architecture.
        n: Stimulus length in samples.
    """
    print("DDC reference model -- architecture comparison\n")
    results = {}
    for arch in (MIX_SEPARATE, MIX_FUSED):
        c = replace(cfg, mix_arch=arch)
        results[arch] = report(c, n)
        print(f"[{arch}]")
        _print_report(c, results[arch])
        print()
    d = results[MIX_FUSED]["ddc_snr_db"] - results[MIX_SEPARATE]["ddc_snr_db"]
    print(f"  fused - separate: {d:+.2f} dB SNR")
    print("  The synthesis comparison is only meaningful at matched SNR. If this")
    print("  gap is large, equalise it (usually via cordic_bits) before comparing")
    print("  area -- otherwise you are comparing a cheap design to an accurate one.")


def _run_emit_vectors(cfg: DDCConfig, out_dir: str, n: int) -> None:
    """Write RTL test vectors and print a summary of what was written.

    Args:
        cfg: Configuration to generate vectors for.
        out_dir: Destination directory.
        n: Stimulus length in samples.
    """
    man = emit_vectors(DDC(cfg), out_dir, n)
    d = man["derived"]
    print(f"\nwrote {len(man['files'])} files to {out_dir}")
    print(f"  {d['n_input_samples']} input samples -> {d['n_output_samples']} output samples")
    print(f"  phase_inc = 0x{d['phase_inc']:08x}, K = {d['k_gain']:.10f}")


def main(argv=None) -> int:
    """Run the CLI: parse arguments and dispatch to report/compare/emit.

    Args:
        argv: Argument list to parse; defaults to sys.argv[1:].

    Returns:
        Process exit code.
    """
    p = argparse.ArgumentParser(
        description="Numpy reference model of the DDC front-end.",
        formatter_class=argparse.ArgumentDefaultsHelpFormatter,
    )
    p.add_argument("--report", action="store_true", help="print SNR/SFDR for the configuration")
    p.add_argument("--compare-arch", action="store_true",
                   help="run separate and fused side by side (the synthesis study's premise)")
    p.add_argument("--emit-vectors", metavar="DIR", help="write RTL test vectors to DIR")
    p.add_argument("--n", type=int, default=8192, help="stimulus length in samples")
    p.add_argument("--mix-arch", choices=(MIX_SEPARATE, MIX_FUSED),
                   default=DDCConfig.mix_arch)
    p.add_argument("--shift-mode", choices=(TRUNC, ROUND), default=TRUNC)
    p.add_argument("--n-iter", type=int, default=DDCConfig.n_iter)
    p.add_argument("--data-bits", type=int, default=DDCConfig.data_bits)
    p.add_argument("--cordic-bits", type=int, default=DDCConfig.cordic_bits)
    p.add_argument("--phase-bits", type=int, default=DDCConfig.phase_bits,
                   help="M: accumulator width, sets frequency resolution")
    p.add_argument("--phase-trunc-bits", type=int, default=DDCConfig.phase_trunc_bits,
                   help="N: phase bits reaching the angle path, sets spur floor")
    p.add_argument("--ang-bits", type=int, default=DDCConfig.ang_bits,
                   help="CORDIC internal angle width")
    p.add_argument("--out-bits", type=int, default=None,
                   help="output word width; defaults to --data-bits, which is "
                        "where the FIR's unity DC gain puts the output anyway")
    p.add_argument("--fs-in", type=float, default=DDCConfig.fs_in)
    p.add_argument("--f-lo", type=float, default=DDCConfig.f_lo)
    p.add_argument("--decim", type=int, default=DDCConfig.decim)
    a = p.parse_args(argv)

    try:
        cfg = DDCConfig(
            fs_in=a.fs_in, f_lo=a.f_lo, decim=a.decim,
            mix_arch=a.mix_arch, shift_mode=a.shift_mode, n_iter=a.n_iter,
            data_bits=a.data_bits, cordic_bits=a.cordic_bits,
            phase_bits=a.phase_bits, phase_trunc_bits=a.phase_trunc_bits,
            ang_bits=a.ang_bits,
            out_bits=a.data_bits if a.out_bits is None else a.out_bits,
        )
    except (ValueError, OverflowError) as e:
        print(f"error: {e}", file=sys.stderr)
        return 2

    did = False
    if a.compare_arch:
        did = True
        _run_compare_arch(cfg, a.n)
    elif a.report:
        did = True
        print("DDC reference model\n")
        _print_report(cfg, report(cfg, a.n))

    if a.emit_vectors:
        did = True
        _run_emit_vectors(cfg, a.emit_vectors, a.n)

    if not did:
        p.print_help()
    return 0


if __name__ == "__main__":
    raise SystemExit(main())
