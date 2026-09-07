"""Tests for the DDC reference model.

Several tests construct a known failure case directly and confirm the
corresponding check flags it, since a test that cannot fail is not evidence.

Run:  python cordic/reference/test_ddc_reference.py
"""

import json
import math
import os
import re
import shutil
import tempfile

import numpy as np

# --- repo layout bootstrap --------------------------------------------------
# The reference model sits in cordic/reference/ next to this test; add its directory
# so the test runs from the repo root (the project-wide convention) as well as
# from here.
import os as _os
import sys as _sys
_HERE = _os.path.dirname(_os.path.abspath(__file__))
if _HERE not in _sys.path:
    _sys.path.insert(0, _HERE)
# ----------------------------------------------------------------------------

import ddc_reference as G
from ddc_reference import DDCConfig, DDC, MIX_SEPARATE, MIX_FUSED, TRUNC, ROUND


# --------------------------------------------------------------------------
# helpers
# --------------------------------------------------------------------------


def _in_band_offset(cfg):
    """Pick a test-tone offset from the LO that survives the whole RX chain.

    Tests that follow a tone through to the decimated output need it inside
    the FIR's passband *and* inside the decimated Nyquist, or the tone is
    either attenuated by the filter or folded by the decimation -- and a
    folded tone looks exactly like a mirrored spectrum, which is what
    several of these tests are trying to detect. Half the cutoff clears both
    limits with margin at any rate, which a hardcoded frequency does not:
    this project has been rescaled twice already, and each time moved
    fs_out enough that a fixed offset picked for the old rate landed outside
    the new decimated Nyquist.

    Args:
        cfg: The DDC configuration.

    Returns:
        A tone offset in Hz, inside the passband.
    """
    return cfg.fir_cutoff / 2.0


def _peak_bin_hz(y, fs):
    """Find the frequency of the largest FFT bin, signed.

    Args:
        y: Complex signal.
        fs: Sample rate in Hz.

    Returns:
        The peak bin's frequency in Hz, negative for the lower half of the
        spectrum.
    """
    spec = np.abs(np.fft.fft(y * np.hanning(len(y))))
    k = int(np.argmax(spec))
    if k > len(y) // 2:
        k -= len(y)
    return k * fs / len(y)


def _mix_mirrored(ddc, xi, xq, cos, sin):
    """Mix with Q negated, producing a mirrored spectrum instead of a correct mix.

    Same amplitude and bandwidth as a correct mix, but mirrored about DC.
    Implements the failure test_sign_convention_is_not_mirrored must detect.

    Args:
        ddc: The DDC model providing the config and shift/saturation
            behavior.
        xi, xq: Input I/Q samples.
        cos, sin: NCO output.

    Returns:
        The mirrored (i, q) mix result.
    """
    c = ddc.cfg
    pi_ = np.asarray(xi, np.int64) * cos + np.asarray(xq, np.int64) * sin
    pq_ = np.asarray(xi, np.int64) * sin - np.asarray(xq, np.int64) * cos
    sh = c.data_bits - 1
    return G.sat(G.shr(pi_, sh), c.data_bits), G.sat(G.shr(pq_, sh), c.data_bits)


# --------------------------------------------------------------------------
# CORDIC
# --------------------------------------------------------------------------


def test_cordic_gain_matches_the_published_constant():
    k = G.cordic_gain(40)
    assert abs(k - 1.6467602581210656) < 1e-12, f"K = {k!r}"
    # K grows monotonically with iterations and is already converged by 16.
    assert abs(G.cordic_gain(16) - k) < 1e-9
    assert G.cordic_gain(4) < G.cordic_gain(8) < k
    print(f"cordic gain: K = {k:.13f} OK")


def test_convergence_limit_covers_the_quadrant_residual():
    lim = G.cordic_convergence_limit(16)
    assert abs(lim - 1.7432561028942164) < 1e-12, lim
    # It keeps creeping up toward ~1.74328 as iterations are added, but the
    # 16-iteration value is the one this design actually gets.
    assert G.cordic_convergence_limit(64) > lim
    assert lim > math.pi / 2, "range reduction to [0, pi/2) would not converge"
    # The margin is only ~0.17 rad; if someone shortens the CORDIC it vanishes.
    assert G.cordic_convergence_limit(2) < math.pi / 2, (
        "a 2-iteration CORDIC should not cover pi/2 -- if it does, the limit "
        "calculation is wrong and the guard in DDCConfig is vacuous"
    )
    print(f"convergence limit: {lim:.6f} rad > pi/2 OK")


def test_cordic_reproduces_sin_cos_across_the_full_circle():
    """Sweeps every quadrant, since the fixups are per-quadrant."""
    cfg = DDCConfig()
    ddc = DDC(cfg)
    n = 4096
    phase = np.linspace(0, (1 << cfg.phase_bits) - 1, n).astype(np.int64)
    cos, sin = ddc.nco(phase)
    fs = G.full_scale(cfg.data_bits)
    theta = phase / (1 << cfg.phase_bits) * 2 * np.pi
    ec = np.abs(cos / fs - np.cos(theta)).max()
    es = np.abs(sin / fs - np.sin(theta)).max()
    assert ec < 2e-3, f"cos error {ec}"
    assert es < 2e-3, f"sin error {es}"
    # And all four quadrants were actually exercised.
    q, _ = G.quadrant_split(ddc.angle_word(phase), cfg.ang_bits)
    assert set(np.unique(q).tolist()) == {0, 1, 2, 3}, "sweep missed a quadrant"
    print(f"nco vs math: max cos err {ec:.2e}, sin err {es:.2e} OK")


def test_cordic_converges_at_the_range_reduction_boundary():
    """The worst case is a residual just under pi/2, the top of the input range."""
    cfg = DDCConfig()
    tbl = G.atan_table(cfg.n_iter, cfg.ang_bits)
    quarter = 1 << (cfg.ang_bits - 2)
    z0 = np.array([0, 1, quarter // 2, quarter - 2, quarter - 1], np.int64)
    x0 = np.full(z0.shape, int(round(G.full_scale(cfg.cordic_bits) / cfg.k_gain)), np.int64)
    x, y, z, _ = G.cordic_rotate(x0, np.zeros_like(z0), z0, tbl, cfg.cordic_bits)
    # The residual cannot go below the last rotation step -- that is the
    # finest correction the CORDIC has left. Asserting a tighter bound than
    # the algorithm can reach would just be a test tuned to today's numbers,
    # so the criterion is the step size itself.
    last_step = int(tbl[-1])
    assert np.abs(z).max() <= last_step, (
        f"residual angle {np.abs(z).max()} LSB exceeds the final rotation step "
        f"{last_step} LSB -- not converged"
    )
    # Unit amplitude preserved (the 1/K seed did its job) at every angle.
    mag = np.hypot(x, y) / G.full_scale(cfg.cordic_bits)
    assert np.abs(mag - 1.0).max() < 3e-3, f"amplitude drift {np.abs(mag - 1.0).max()}"
    print(f"boundary convergence: |z| <= {np.abs(z).max()} of {last_step} LSB step, "
          f"|mag-1| < 3e-3 OK")


def test_nco_amplitude_is_unit_because_of_the_inv_k_seed():
    """Confirms the seeded NCO is unit amplitude, and an unseeded one measures K."""
    cfg = DDCConfig()
    ddc = DDC(cfg)
    phase = np.linspace(0, (1 << cfg.phase_bits) - 1, 512).astype(np.int64)
    cos, sin = ddc.nco(phase)
    mag = np.hypot(cos, sin) / G.full_scale(cfg.data_bits)
    assert abs(mag.mean() - 1.0) < 2e-3, f"seeded NCO amplitude {mag.mean()}"

    # Unseeded, i.e. x0 not divided by K: amplitude comes out K instead of 1.
    # Seeded at half scale deliberately -- at full scale the K growth
    # saturates the CORDIC word and the measurement would read the clip
    # level (~1.11) rather than K. That saturation is real, and is why the
    # fused mixer needs its extra bit; here it just has to be kept out of
    # the way.
    tbl = ddc.atan
    q, rem = G.quadrant_split(ddc.angle_word(phase), cfg.ang_bits)
    half = G.full_scale(cfg.cordic_bits) // 2
    x0 = np.full(rem.shape, half, np.int64)
    x, y, _, _ = G.cordic_rotate(x0, np.zeros_like(rem), rem, tbl, cfg.cordic_bits)
    assert G.would_saturate(np.hypot(x, y).astype(np.int64), cfg.cordic_bits) == 0
    bad = np.hypot(x, y) / half
    assert abs(bad.mean() - cfg.k_gain) < 5e-3, (
        f"unseeded amplitude {bad.mean()} should be K={cfg.k_gain}"
    )
    print(f"inv-K seed: amplitude 1.000 seeded vs {bad.mean():.4f} unseeded OK")


def test_atan_table_exhaustion_is_rejected():
    """Iterations past what ang_bits can resolve are dead hardware, not accuracy."""
    try:
        DDCConfig(ang_bits=12, phase_trunc_bits=12, n_iter=24)
        raised = False
    except ValueError as e:
        raised = "resolve" in str(e)
    assert raised, "a CORDIC longer than its angle table allows was accepted"
    print("atan table exhaustion rejected OK")


# --------------------------------------------------------------------------
# fixed-point primitives
# --------------------------------------------------------------------------


def test_trunc_shift_matches_verilog_not_c():
    """Verilog's >>> floors. C's / truncates toward zero instead."""
    x = np.array([-9, -1, 1, 9], np.int64)
    got = G.shr(x, 1, TRUNC)
    assert got.tolist() == [-5, -1, 0, 4], got.tolist()
    assert (x // 2).tolist() == got.tolist(), "should match floor division"
    assert (x.astype(float) / 2).astype(np.int64).tolist() != got.tolist(), (
        "should not match round-toward-zero -- that would be the C semantics"
    )
    rnd = G.shr(x, 1, ROUND)
    assert rnd.tolist() == [-4, 0, 1, 5], rnd.tolist()
    print("shift semantics: trunc floors like >>>, round differs OK")


def test_saturation_clips_and_is_counted():
    v = np.array([-40000, -100, 100, 40000], np.int64)
    assert G.sat(v, 16).tolist() == [-32768, -100, 100, 32767]
    assert G.would_saturate(v, 16) == 2
    assert G.would_saturate(v, 32) == 0
    print("saturation clips and is counted OK")


def test_int64_overflow_is_caught_not_silent():
    try:
        G.assert_fits(np.array([1 << 62], np.int64), "probe")
        raised = False
    except OverflowError:
        raised = True
    assert raised, "an intermediate past int64 exactness went unreported"
    print("int64 overflow guard fires OK")


# --------------------------------------------------------------------------
# the sign convention -- the one this file exists for
# --------------------------------------------------------------------------


def test_sign_convention_is_not_mirrored():
    """A tone at f_lo + delta must land at +delta, not -delta.

    A mirrored spectrum has the same magnitude, so nothing downstream would
    otherwise catch it.
    """
    cfg = DDCConfig()
    ddc = DDC(cfg)
    n = 8192
    delta = _in_band_offset(cfg)

    for sign in (+1.0, -1.0):
        want = sign * delta
        xi, xq = G.tone(n, cfg.fs_in, cfg.f_lo_actual + want, -6.0, cfg.data_bits)
        r = ddc.run(xi, xq)
        skip = 0  # fir_decimate is valid-only: no fill transient to trim
        y = (r["out_i"] + 1j * r["out_q"])[skip:]
        got = _peak_bin_hz(y, cfg.fs_out)
        assert abs(got - want) < cfg.fs_out / 100, (
            f"tone at f_lo{want:+.0f} Hz landed at {got:+.0f} Hz -- "
            f"spectrum is mirrored (conjugate backwards)"
        )
    print(f"sign convention: +/-{delta / 1e3:.0f} kHz land on the correct sides OK")


def test_mirrored_mixer_is_detected():
    """Confirms the sign-convention check flags a deliberately mirrored mixer.

    The mirrored output must match the correct one in amplitude and land on
    the opposite side of the carrier.
    """
    # Pinned to the separate architecture because _mix_mirrored implements the
    # separate mixer's cos/sin multiplies. Comparing it against the fused
    # default would put a stray factor of K between the two paths and the
    # amplitude check below would be measuring the gain, not the mirroring.
    cfg = DDCConfig(mix_arch=MIX_SEPARATE)
    ddc = DDC(cfg)
    n = 8192
    delta = _in_band_offset(cfg)
    xi, xq = G.tone(n, cfg.fs_in, cfg.f_lo_actual + delta, -6.0, cfg.data_bits)

    ph = ddc.phase(n)
    cos, sin = ddc.nco(ph)
    mi, mq = _mix_mirrored(ddc, xi, xq, cos, sin)
    yi, yq, _ = G.fir_decimate(
        mi, mq, ddc.coef, cfg.decim, cfg.coef_bits, cfg.acc_bits, cfg.out_bits, cfg.shift_mode
    )
    skip = 0  # fir_decimate is valid-only: no fill transient to trim
    bad = (yi + 1j * yq)[skip:]
    got = _peak_bin_hz(bad, cfg.fs_out)
    assert abs(got + delta) < cfg.fs_out / 100, (
        f"the deliberately-mirrored mixer landed at {got:+.0f} Hz; expected "
        f"{-delta:+.0f} Hz. The sign test cannot discriminate."
    )
    # Same amplitude as the correct path.
    good = (ddc.run(xi, xq)["out_i"] + 1j * ddc.run(xi, xq)["out_q"])[skip:]
    ratio = np.abs(bad).mean() / np.abs(good).mean()
    assert 0.98 < ratio < 1.02, (
        f"mirrored output amplitude ratio {ratio:.3f} -- if it differed this "
        f"much, magnitude alone would already reveal the mirroring, and the "
        f"test would be too easy"
    )
    print(
        f"mirrored mixer lands at {got / 1e3:+.1f} kHz at {ratio:.3f}x amplitude "
        f"-- same magnitude, opposite side, test discriminates OK"
    )


def test_dc_lands_at_dc():
    """A tone exactly at the LO must come out at DC with a steady phase."""
    cfg = DDCConfig()
    ddc = DDC(cfg)
    n = 4096
    xi, xq = G.tone(n, cfg.fs_in, cfg.f_lo_actual, -6.0, cfg.data_bits)
    r = ddc.run(xi, xq)
    skip = 0  # fir_decimate is valid-only: no fill transient to trim
    y = (r["out_i"] + 1j * r["out_q"])[skip:]
    got = _peak_bin_hz(y, cfg.fs_out)
    assert abs(got) < cfg.fs_out / 200, f"LO tone landed at {got:+.1f} Hz, not DC"
    # Constant phase: the residual frequency is zero, not merely small in |X|.
    ph = np.unwrap(np.angle(y))
    drift = abs(ph[-1] - ph[0]) / (2 * np.pi) * cfg.fs_out / len(y)
    assert drift < 1.0, f"residual frequency {drift:.3f} Hz -- LO is not exact"
    print(f"LO tone -> DC, residual {drift:.4f} Hz OK")


# --------------------------------------------------------------------------
# K scaling
# --------------------------------------------------------------------------


def test_k_folding_lands_both_architectures_on_the_same_scale():
    """Separate removes K at the seed. Fused removes it in the coefficients."""
    sep = DDC(DDCConfig(mix_arch=MIX_SEPARATE))
    fus = DDC(DDCConfig(mix_arch=MIX_FUSED))
    assert not sep.fold_inv_k and fus.fold_inv_k

    dc_sep = sep.coef.sum() / G.full_scale(sep.cfg.coef_bits)
    dc_fus = fus.coef.sum() / G.full_scale(fus.cfg.coef_bits)
    assert abs(dc_sep - 1.0) < 1e-4, f"separate FIR DC gain {dc_sep}"
    assert abs(dc_fus - 1.0 / fus.cfg.k_gain) < 1e-4, f"fused FIR DC gain {dc_fus}"
    # The ratio equals K -- this is the assertion that catches K vs 1/K inverted.
    assert abs(dc_sep / dc_fus - fus.cfg.k_gain) < 1e-3, (
        f"coefficient ratio {dc_sep / dc_fus} should equal K={fus.cfg.k_gain}"
    )
    print(f"K folding: DC gains {dc_sep:.4f} / {dc_fus:.4f}, ratio = K OK")


def test_k_folded_the_wrong_way_is_4_3_db_hot():
    """Measure the level error from folding K instead of 1/K into the FIR."""
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    h = G.firwin_lowpass(cfg.n_taps, cfg.fir_cutoff / (cfg.fs_in / 2))
    right = G.fir_taps_quantized(h, cfg.coef_bits, 1.0 / cfg.k_gain)
    wrong = G.fir_taps_quantized(h, cfg.coef_bits, 1.0)
    db = 20 * math.log10(wrong.sum() / right.sum())
    assert 4.2 < db < 4.4, f"expected ~4.34 dB error, got {db}"
    print(f"K folded the wrong way = {db:+.2f} dB level error OK")


def test_fused_mixer_carries_one_extra_bit():
    """The fused K growth needs headroom, and that cost must show in the config."""
    assert DDCConfig(mix_arch=MIX_SEPARATE).mix_bits == 16
    assert DDCConfig(mix_arch=MIX_FUSED).mix_bits == 17
    # And a fused config with no CORDIC guard bits is rejected outright.
    try:
        DDCConfig(mix_arch=MIX_FUSED, cordic_bits=16, data_bits=16)
        raised = False
    except ValueError as e:
        raised = "headroom" in str(e)
    assert raised, "fused mixer accepted with no headroom for K"
    print("fused mixer: 17-bit output, zero-headroom config rejected OK")


# --------------------------------------------------------------------------
# the two architectures must compute the same function
# --------------------------------------------------------------------------


def test_separate_and_fused_agree():
    """The synthesis comparison is meaningless unless both compute the same answer.

    Not bit-exact, since they quantize differently. Both must track the ideal
    model closely and agree with each other.
    """
    n = 8192
    cs = DDCConfig(mix_arch=MIX_SEPARATE)
    cf = DDCConfig(mix_arch=MIX_FUSED)
    ds, df = DDC(cs), DDC(cf)
    xi, xq = G.two_tone(n, cs)

    skip = 0  # fir_decimate is valid-only: no fill transient to trim
    fs_ = G.full_scale(cs.out_bits)
    ys = (ds.run(xi, xq)["out_i"] + 1j * ds.run(xi, xq)["out_q"]) / fs_
    yf = (df.run(xi, xq)["out_i"] + 1j * df.run(xi, xq)["out_q"]) / fs_
    ref = G.ddc_ideal(xi, xq, cs, ds.h_float)

    snr_s = G.snr_db(ref, ys, skip)
    snr_f = G.snr_db(ref, yf, skip)
    snr_sf = G.snr_db(ys, yf, skip)
    assert snr_s > 60, f"separate SNR only {snr_s:.1f} dB"
    assert snr_f > 60, f"fused SNR only {snr_f:.1f} dB"
    assert snr_sf > 55, f"the two architectures disagree at {snr_sf:.1f} dB"
    print(f"separate {snr_s:.1f} dB / fused {snr_f:.1f} dB / mutual {snr_sf:.1f} dB OK")


def test_wrong_rotation_direction_in_fused_is_caught():
    """Confirms a reversed CORDIC rotation direction is caught by SNR, not power.

    Reversing the rotation direction distorts phase rather than shifting
    frequency, so amplitude drops only slightly. SNR against the ideal model
    collapses from ~79 dB to single digits, which is what this test checks.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    n = 8192
    delta = _in_band_offset(cfg)
    xi, xq = G.tone(n, cfg.fs_in, cfg.f_lo_actual + delta, -6.0, cfg.data_bits)

    ph = ddc.phase(n)
    q, rem = G.quadrant_split(ddc.angle_word(ph), cfg.ang_bits)
    ri, rq = G.prerotate_conj(q, xi, xq)
    g = cfg.cordic_bits - cfg.data_bits - 1
    # Seed with +rem instead of -rem to reverse the rotation direction.
    x, y, _, _ = G.cordic_rotate(
        ri << np.int64(g), rq << np.int64(g), rem, ddc.atan, cfg.cordic_bits, cfg.shift_mode
    )
    mi = G.sat(G.shr(x, g), cfg.mix_bits)
    mq = G.sat(G.shr(y, g), cfg.mix_bits)
    yi, yq, _ = G.fir_decimate(
        mi, mq, ddc.coef, cfg.decim, cfg.coef_bits, cfg.acc_bits, cfg.out_bits, cfg.shift_mode
    )
    fs_ = G.full_scale(cfg.out_bits)
    r = ddc.run(xi, xq)
    good = (r["out_i"] + 1j * r["out_q"]) / fs_
    bad = (yi + 1j * yq) / fs_
    ref = G.ddc_ideal(xi, xq, cfg, ddc.h_float)

    snr_good = G.snr_db(ref, good)
    snr_bad = G.snr_db(ref, bad)
    assert snr_good > 60, f"the correct fused path only scored {snr_good:.1f} dB"
    assert snr_bad < 20, (
        f"the inverted rotation scored {snr_bad:.1f} dB against the ideal model; "
        f"if a sign error can score that well the SNR check is not discriminating"
    )
    # And confirm the trap: power alone does not separate them.
    ratio = np.abs(good).mean() / np.abs(bad).mean()
    assert ratio < 2.0, (
        f"amplitude ratio {ratio:.2f} -- if power alone separated these, the "
        f"docstring's warning is wrong and worth revisiting"
    )
    print(
        f"inverted rotation: SNR {snr_bad:.1f} dB vs {snr_good:.1f} dB correct, "
        f"but only {ratio:.2f}x in amplitude -- caught by SNR, not power OK"
    )


# --------------------------------------------------------------------------
# mixing direction (RX/TX), which on silicon is a runtime input
# --------------------------------------------------------------------------


def test_upconvert_matches_the_analytic_rotation():
    """Confirms downconvert=False rotates by +theta, not by -theta.

    Checked against the analytic K*x*exp(+j*theta) and, as the trap, against
    the down-convert reference too. A direction bit that did nothing would
    still score well on one of those; only scoring well on the right one and
    badly on the wrong one shows the rotation actually reversed.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    n = 8192
    xi, xq = G.tone(n, cfg.fs_in, 40_000.0, -6.0, cfg.data_bits)

    fs_ = G.full_scale(cfg.data_bits)
    up = ddc.mix_stage(xi, xq, downconvert=False)
    got = (up["mix_i"] + 1j * up["mix_q"]) / fs_

    ref_up = G.mix_ideal(xi, xq, cfg, downconvert=False)
    ref_down = G.mix_ideal(xi, xq, cfg, downconvert=True)

    snr_right = G.snr_db(ref_up, got)
    snr_wrong = G.snr_db(ref_down, got)
    assert snr_right > 55, f"up-convert scored only {snr_right:.1f} dB against +theta"
    assert snr_wrong < 20, (
        f"up-convert scored {snr_wrong:.1f} dB against the -theta reference too; "
        f"the direction bit is not actually changing the rotation"
    )
    print(
        f"up-convert: {snr_right:.1f} dB vs +theta, {snr_wrong:.1f} dB vs -theta OK"
    )


def test_upconvert_then_downconvert_returns_the_input():
    """Confirms the two directions invert each other, up to the gain K^2.

    Independent of the analytic model: if both directions shared one sign
    error this still catches it, because the round trip would not close.

    Amplitudes are chosen so nothing clips. A -6 dBFS complex tone has a
    constant 0.5 envelope; one rotation takes it to 0.82 of data-bits full
    scale, which still fits data_bits, and the second to 1.36, which fits
    mix_bits. Both stay under the CORDIC's own 1.21 input limit.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    n = 8192
    xi, xq = G.tone(n, cfg.fs_in, 40_000.0, -6.0, cfg.data_bits)

    up = ddc.mix_stage(xi, xq, downconvert=False)
    assert np.abs(up["mix_i"]).max() < G.full_scale(cfg.data_bits), (
        "the intermediate does not fit data_bits, so the round trip would be "
        "measuring clipping rather than the rotation"
    )
    back = ddc.mix_stage(up["mix_i"], up["mix_q"], downconvert=True)

    fs_ = G.full_scale(cfg.data_bits)
    got = (back["mix_i"] + 1j * back["mix_q"]) / fs_
    want = cfg.k_gain**2 * (np.asarray(xi, float) + 1j * np.asarray(xq, float)) / fs_

    snr = G.snr_db(want, got)
    assert snr > 50, f"round trip closed to only {snr:.1f} dB"
    print(f"up then down returns the input at K^2, {snr:.1f} dB OK")


def test_direction_is_a_port_not_a_parameter():
    """Guards the tapeout decision: the die has to do both directions.

    A parameter is frozen at tapeout, so one direction would reach silicon
    unexercised and the other would not exist. This asserts against the RTL
    source because that is where the mistake would be reintroduced -- the
    Python model cannot tell a parameter from a port.
    """
    src_path = os.path.join(os.path.dirname(__file__), "..", "mixer_fused.sv")
    with open(src_path) as f:
        src = f.read()

    assert re.search(r"input\s+logic\s+downconvert\s*,", src), (
        "mixer_fused.sv does not declare downconvert as an input port"
    )
    assert not re.search(r"parameter\s+\w+\s+DOWNCONVERT", src), (
        "mixer_fused.sv declares DOWNCONVERT as a parameter again -- that "
        "freezes the direction at tapeout, which is exactly what the port "
        "was introduced to avoid"
    )
    print("mixer direction is a runtime port, not a build-time parameter OK")


def test_separate_mixer_refuses_to_upconvert():
    """Confirms the separate architecture rejects up-convert instead of lying.

    Only the fused mixer has an up-convert path; mix_separate() hardcodes the
    conjugate. Silently returning a down-converted result would be worse than
    an error, so this pins the error.
    """
    ddc = DDC(DDCConfig(mix_arch=MIX_SEPARATE))
    cfg = ddc.cfg
    xi, xq = G.tone(256, cfg.fs_in, _in_band_offset(cfg), -6.0, cfg.data_bits)
    try:
        ddc.mix_stage(xi, xq, downconvert=False)
    except ValueError as e:
        assert "up-convert" in str(e), e
        print("separate mixer refuses to up-convert OK")
        return
    raise AssertionError("mix_arch='separate' silently accepted downconvert=False")


# --------------------------------------------------------------------------
# TX interpolator
# --------------------------------------------------------------------------


def test_interpolator_targets_decim_over_k_gain():
    """The interpolator's DC gain must restore decim's attenuation, not just 1/K.

    Zero-stuffing by `decim` cuts the average amplitude by 1/decim on its
    own; the interpolator's filter has to put that back on top of
    pre-cancelling the mixer's K, or the TX chain comes out `decim` times too
    quiet. Paired with the wrong-gain case (using the decimator's own
    target_dc, 1/K, with no decim factor) so a low-effort answer -- reusing
    fir_decimate's coefficients wholesale -- is caught, not just described.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)

    dc_interp = ddc.coef_interp.sum() / G.full_scale(cfg.coef_bits)
    assert abs(dc_interp - cfg.decim / cfg.k_gain) < 1e-3, (
        f"interpolator DC gain {dc_interp} should be decim/K = {cfg.decim / cfg.k_gain:.4f}"
    )

    wrong = G.fir_taps_quantized(ddc.h_float, cfg.coef_bits, 1.0 / cfg.k_gain)
    ratio = ddc.coef_interp.sum() / wrong.sum()
    assert abs(ratio - cfg.decim) < 1e-2, (
        f"reusing the decimator's 1/K coefficients wholesale should be decim="
        f"{cfg.decim}x too quiet, measured {ratio:.3f}x -- if this drifted to "
        f"~1x the two coefficient sets stopped being distinguishable"
    )
    print(f"interpolator DC gain {dc_interp:.4f} = decim/K OK ({ratio:.2f}x the RX-only gain)")


def test_polyphase_decomposition_matches_zero_stuffed_convolution():
    """The RTL's polyphase realization must equal fir_interpolate()'s reference term for term.

    fir_interpolate() zero-stuffs and convolves -- correct but wasteful,
    since interp-1 out of every interp multiplies are against a known zero.
    The RTL instead runs each phase directly against the un-stuffed input
    history. These are mathematically identical, not merely close, so this
    builds the direct-polyphase answer by hand and checks it bit-for-bit
    against fir_interpolate()'s output before trusting the RTL against
    either one.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    n = 300
    rng = np.random.default_rng(1)
    xi = rng.integers(-G.full_scale(cfg.data_bits), G.full_scale(cfg.data_bits), n)
    xq = rng.integers(-G.full_scale(cfg.data_bits), G.full_scale(cfg.data_bits), n)

    ii, iq, _ = G.fir_interpolate(
        xi, xq, ddc.coef_interp, cfg.decim, cfg.coef_bits, cfg.acc_bits,
        cfg.data_bits, cfg.shift_mode,
    )
    assert len(ii) == n * cfg.decim, "fir_interpolate should return one output per zero-stuffed sample"

    phases = G.polyphase_decompose(ddc.coef_interp, cfg.decim)
    lengths = [len(idxs) for idxs in phases]
    assert max(lengths) - min(lengths) == 1 and lengths.count(min(lengths)) == 1, (
        f"n_taps={cfg.n_taps} is not a multiple of decim={cfg.decim}, so exactly "
        f"one phase should be uneven by one tap -- this pins that shape so the "
        f"RTL's per-phase tap-count table cannot silently assume they are equal"
    )

    # Direct polyphase: y[n*interp+p] = sum_k coef_interp[phase[p][k]] * x[n-k],
    # x[negative] = 0 -- the same causal, zero-history convention
    # fir_interpolate() now uses, so no alignment offset is needed here.
    poly_i = np.zeros_like(ii)
    poly_q = np.zeros_like(iq)
    for m in range(len(ii)):
        n_idx, p = divmod(m, cfg.decim)
        acc_i = 0
        acc_q = 0
        for k, coef_idx in enumerate(phases[p]):
            src = n_idx - k
            if src < 0:
                continue
            acc_i += int(ddc.coef_interp[coef_idx]) * int(xi[src])
            acc_q += int(ddc.coef_interp[coef_idx]) * int(xq[src])
        poly_i[m] = G.sat(G.shr(acc_i, cfg.coef_bits - 1, cfg.shift_mode), cfg.data_bits)
        poly_q[m] = G.sat(G.shr(acc_q, cfg.coef_bits - 1, cfg.shift_mode), cfg.data_bits)

    assert np.array_equal(poly_i, ii), "polyphase I does not match the zero-stuffed reference"
    assert np.array_equal(poly_q, iq), "polyphase Q does not match the zero-stuffed reference"
    print(f"polyphase decomposition matches zero-stuffed convolution bit-for-bit ({len(ii)} samples) OK")


def test_interpolate_then_decimate_round_trip():
    """Interpolating then decimating the same signal should approximately return it.

    A strong, cheap correctness signal that does not depend on the mixer at
    all: if the interpolator's gain or filtering were wrong, this would not
    close to a clean single complex gain times the input, regardless of the
    exact expected scale (which includes both filters' passband gain and is
    not 1.0 on its own -- see the mixer-inclusive round trip below for the
    unity-gain version).
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    n = 2048
    xi, xq = G.tone(n, cfg.fs_out, _in_band_offset(cfg), -6.0, cfg.data_bits)

    ii, iq, n_sat_i = G.fir_interpolate(
        xi, xq, ddc.coef_interp, cfg.decim, cfg.coef_bits, cfg.acc_bits,
        cfg.data_bits, cfg.shift_mode,
    )
    assert n_sat_i == 0, f"unexpected clipping in the interpolator: {n_sat_i}"
    yi, yq, n_sat_d = G.fir_decimate(
        ii, iq, ddc.coef, cfg.decim, cfg.coef_bits, cfg.acc_bits, cfg.out_bits, cfg.shift_mode
    )
    assert n_sat_d == 0, f"unexpected clipping in the decimator: {n_sat_d}"

    fs = G.full_scale(cfg.data_bits)
    a = (xi.astype(float) + 1j * xq.astype(float)) / fs
    b = (yi.astype(float) + 1j * yq.astype(float)) / fs
    snr = _best_delay_snr(a, b, max_offset=30)
    assert snr > 50, f"interpolate-then-decimate round trip only scored {snr:.1f} dB"
    print(f"interpolate-then-decimate round trip: {snr:.1f} dB OK")


def test_tx_then_rx_round_trip():
    """The full TX chain into the full RX chain should recover the original baseband signal.

    The end-to-end check that matters: TX interpolates and up-converts,
    the result stands in for an RF-rate signal, and RX down-converts and
    decimates it. This is the only test exercising the interpolator, the
    up-convert mixer, the down-convert mixer, and the decimator together --
    exactly the two K factors (mixer-introduces-K on TX, mixer-removes-K on
    RX) and the decim factor (interpolator adds it, decimator's own 1/K does
    not remove it a second time) have to net out to a clean unity-gain
    passthrough, or a wrong sign or factor anywhere in the chain shows up
    here even if it happened to cancel in a narrower test.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    n = 4096
    xi, xq = G.tone(n, cfg.fs_out, _in_band_offset(cfg), -6.0, cfg.data_bits)

    tx = ddc.tx_stage(xi, xq)
    assert tx["n_saturated"] == 0, f"unexpected clipping in the TX chain: {tx['n_saturated']}"

    # Stand-in for an ADC capturing the upconverted RF signal: mix_bits is
    # one bit wider than data_bits (the fused mixer's K headroom), so this
    # truncates back down, same as a real ADC would only ever see data_bits.
    rf_i = G.sat(tx["mix_i"], cfg.data_bits)
    rf_q = G.sat(tx["mix_q"], cfg.data_bits)
    rx = ddc.run(rf_i, rf_q)
    assert rx["n_saturated"] == 0, f"unexpected clipping in the RX chain: {rx['n_saturated']}"

    fs = G.full_scale(cfg.data_bits)
    a = (xi.astype(float) + 1j * xq.astype(float)) / fs
    b = (rx["out_i"].astype(float) + 1j * rx["out_q"].astype(float)) / fs
    snr = _best_delay_snr(a, b, max_offset=30)
    assert snr > 60, f"TX-then-RX round trip only scored {snr:.1f} dB"
    print(f"TX-then-RX round trip: {snr:.1f} dB OK")


def test_tx_stage_refuses_the_separate_mixer():
    """tx_stage() has to inherit mix_stage()'s guard against the separate architecture.

    tx_stage() does not repeat that check itself; this confirms the guard
    still reaches the caller through the composed pipeline rather than only
    being tested at the mix_stage() layer directly.
    """
    ddc = DDC(DDCConfig(mix_arch=MIX_SEPARATE))
    cfg = ddc.cfg
    xi, xq = G.tone(256, cfg.fs_out, _in_band_offset(cfg), -6.0, cfg.data_bits)
    try:
        ddc.tx_stage(xi, xq)
    except ValueError as e:
        assert "up-convert" in str(e), e
        print("tx_stage refuses the separate mixer OK")
        return
    raise AssertionError("tx_stage() silently accepted mix_arch='separate'")


def _best_delay_snr(a: np.ndarray, b: np.ndarray, max_offset: int) -> float:
    """SNR of `b` against `a`, best-aligned over an integer delay and a single complex gain.

    Two cascaded FIR stages (and, in the TX/RX case, two CORDIC rotations)
    introduce a group delay this repo does not track symbolically, and the
    round-trip tests above care whether the *waveform* survived, not what
    the exact delay or overall complex gain happened to be. Solving for the
    best single complex gain also absorbs any fixed rotation from a
    non-integer true delay, which is why a fitted gain here is not
    meaningful on its own and only the resulting SNR is asserted on.

    Args:
        a: Reference complex sequence.
        b: Sequence to score, at the same sample rate as `a`.
        max_offset: Largest integer delay (either direction) to search.

    Returns:
        The best SNR found, in dB.
    """
    best = None
    for off in range(0, max_offset):
        aa = a[: len(a) - off] if off > 0 else a
        bb = b[off : off + len(aa)]
        m = min(len(aa), len(bb))
        if m < 200:
            continue
        aa2, bb2 = aa[:m], bb[:m]
        denom = np.vdot(bb2, bb2)
        if denom == 0:
            continue
        g = np.vdot(bb2, aa2) / denom
        err = aa2 - g * bb2
        snr = 10 * np.log10(np.mean(np.abs(aa2) ** 2) / np.mean(np.abs(err) ** 2))
        if best is None or snr > best:
            best = snr
    return best


# --------------------------------------------------------------------------
# filter and decimation
# --------------------------------------------------------------------------


def test_fir_has_unit_dc_gain_and_linear_phase():
    h = G.firwin_lowpass(63, 0.1)
    assert abs(h.sum() - 1.0) < 1e-12, h.sum()
    assert np.allclose(h, h[::-1]), "taps are not symmetric -- not linear phase"
    try:
        G.firwin_lowpass(64, 0.1)
        raised = False
    except ValueError:
        raised = True
    assert raised, "an even tap count was accepted"
    print("fir: unit DC gain, symmetric, even taps rejected OK")


def test_fir_rejects_out_of_band():
    """A tone past the cutoff must be attenuated, or decimation aliases it back in."""
    cfg = DDCConfig()
    ddc = DDC(cfg)
    n = 8192
    skip = 0  # fir_decimate is valid-only: no fill transient to trim

    in_band = G.tone(n, cfg.fs_in, cfg.f_lo_actual + _in_band_offset(cfg),
                     -6.0, cfg.data_bits)
    # Past the cutoff and past the decimated Nyquist, so it would fold back --
    # but still under fs_in/2, or the stimulus itself aliases at the sampling
    # step and this measures the wrong rejection.
    out_offset = 4.0 * cfg.fir_cutoff
    assert cfg.f_lo_actual + out_offset < cfg.fs_in / 2, (
        "the out-of-band stimulus must stay under Nyquist to test filter "
        "rejection rather than sampling alias"
    )
    out_band = G.tone(n, cfg.fs_in, cfg.f_lo_actual + out_offset, -6.0, cfg.data_bits)

    a = ddc.run(*in_band)
    b = ddc.run(*out_band)
    pa = np.abs(a["out_i"][skip:] + 1j * a["out_q"][skip:]).mean()
    pb = np.abs(b["out_i"][skip:] + 1j * b["out_q"][skip:]).mean()
    rej = 20 * math.log10(pa / max(pb, 1e-9))
    assert rej > 40, f"stopband rejection only {rej:.1f} dB -- aliases will get in"
    print(f"stopband rejection {rej:.1f} dB OK")


def test_decimation_takes_the_right_phase():
    """An off-by-one decimation offset just looks like a delay, which hides easily.

    Checked against an independently computed convolution, not the model's
    own path.
    """
    cfg = DDCConfig(decim=4, n_taps=15)
    coef = np.arange(1, 16, dtype=np.int64)
    x = np.arange(100, dtype=np.int64)
    yi, _, _ = G.fir_decimate(x, np.zeros_like(x), coef, 4, 16, 40, 16, TRUNC)
    want = [
        G.shr(np.int64(sum(int(coef[k]) * int(x[m * 4 + 14 - k]) for k in range(15))), 15)
        for m in range((100 - 14) // 4 + 1)
    ]
    got = yi.tolist()[: len(want)]
    assert got == [int(w) for w in want], f"decimation phase wrong:\n{got}\n{want}"
    print(f"decimation phase matches direct convolution ({len(want)} samples) OK")


def test_aliasing_cutoff_is_rejected():
    # A cutoff above the *decimated* Nyquist, derived from the defaults rather
    # than hardcoded, so this keeps testing the validator and not a rate the
    # project has since moved off.
    cfg = DDCConfig()
    bad = cfg.fs_in / cfg.decim / 2.0 * 1.5
    try:
        DDCConfig(fir_cutoff=bad, decim=cfg.decim, fs_in=cfg.fs_in)
        raised = False
    except ValueError as e:
        raised = "alias" in str(e)
    assert raised, "a cutoff above the decimated Nyquist was accepted"
    print("aliasing cutoff rejected OK")


# --------------------------------------------------------------------------
# quality of the whole thing
# --------------------------------------------------------------------------


def test_fixed_point_tracks_the_ideal_model():
    """Whole-chain quality at the default config.

    The NCO threshold is deliberately not the ~90 dB an LO like fs/4 or fs/8
    scores. Those divide the phase accumulator exactly (phase_trunc_residue
    == 0), exercising no phase truncation at all, and the default LO no
    longer does: at 80 kHz on a 400 kS/s clock the residue is non-zero, so
    truncation spurs set the floor and the honest number is ~74 dB. That is
    the same hardware measured at a representative LO, not a regression --
    see test_phase_truncation_only_bites_when_the_fcw_exercises_it, which
    pins both cases against each other.
    """
    cfg = DDCConfig()
    m = G.report(cfg, n=8192)
    assert m["ddc_snr_db"] > 65, f"DDC SNR {m['ddc_snr_db']:.1f} dB"
    assert m["ddc_sfdr_db"] > 50, f"DDC SFDR {m['ddc_sfdr_db']:.1f} dB"
    assert m["nco_snr_db"] > 70, f"NCO SNR {m['nco_snr_db']:.1f} dB"
    # The mechanism, not just a number: with a truncating LO the NCO's spurs
    # should sit at the 6.02*N bound, so a measurement far above it would
    # mean the LO stopped being representative.
    assert m["nco_sfdr_db"] < cfg.phase_trunc_sfdr_bound_db + 6.0, (
        f"NCO SFDR {m['nco_sfdr_db']:.1f} dB is well above the {cfg.phase_trunc_sfdr_bound_db:.1f} dBc "
        f"phase-truncation bound -- the default LO has become a binary fraction "
        f"of fs and no longer exercises truncation, which flatters every spur number"
    )
    assert m["n_saturated"] == 0, f"{m['n_saturated']} samples saturated at -6 dBFS"
    assert m["ddc_enob"] > 10, f"ENOB {m['ddc_enob']:.2f}"
    print(
        f"quality: SNR {m['ddc_snr_db']:.1f} dB, SFDR {m['ddc_sfdr_db']:.1f} dB, "
        f"ENOB {m['ddc_enob']:.2f}, NCO {m['nco_snr_db']:.1f} dB at a truncating LO OK"
    )


def test_narrower_datapath_is_measurably_worse():
    """Confirms the SNR metric responds to datapath width."""
    wide = G.report(DDCConfig(), n=4096)["ddc_snr_db"]
    narrow = G.report(DDCConfig(data_bits=10, cordic_bits=14, out_bits=10), n=4096)[
        "ddc_snr_db"
    ]
    assert narrow < wide - 20, (
        f"a 10-bit datapath scored {narrow:.1f} dB against 16-bit's {wide:.1f} dB; "
        f"the metric is not tracking quantization"
    )
    print(f"width sensitivity: 16-bit {wide:.1f} dB vs 10-bit {narrow:.1f} dB OK")


def test_lo_quantization_is_reported_honestly():
    """A frequency the accumulator cannot hit must be reported, not rounded away.

    The target LO is built half an accumulator step away from a
    representable value, which is the worst case for a given phase_bits,
    rather than being a fixed frequency: a hardcoded target's error depends
    on how it happens to land relative to fs_in, so at one sample rate it
    proves the point and at another it is representable by luck.
    """
    coarse_bits = 12
    base = DDCConfig()
    step = base.fs_in / (1 << coarse_bits)
    # Half a step above a representable multiple, and comfortably in band.
    k = int((base.fs_in / 5.0) / step)
    target = (k + 0.5) * step

    cfg = DDCConfig(
        phase_bits=coarse_bits, phase_trunc_bits=coarse_bits, ang_bits=12,
        n_iter=9, f_lo=target,
    )
    err = cfg.f_lo_actual - cfg.f_lo
    assert abs(err) > step / 4.0, (
        f"a {coarse_bits}-bit accumulator (step {step:.1f} Hz) placed this LO to "
        f"within {abs(err):.1f} Hz; the model should be showing that error, not "
        f"hiding it"
    )

    fine = DDCConfig(phase_bits=32, f_lo=target)
    fine_step = base.fs_in / (1 << 32)
    assert abs(fine.f_lo_actual - fine.f_lo) <= fine_step, (
        "a 32-bit accumulator should place the same LO to within one of its own steps"
    )
    print(
        f"LO quantization: {coarse_bits}-bit err {err:+.1f} Hz (step {step:.1f}), "
        f"32-bit err {fine.f_lo_actual - fine.f_lo:+.2e} Hz OK"
    )


def test_lo_above_nyquist_is_rejected():
    """An LO past fs_in/2 is a configuration error, not a usable setting.

    The accumulator wraps and the mixer silently uses the alias, which is
    indistinguishable downstream from having asked for the alias on purpose.
    """
    base = DDCConfig()
    try:
        DDCConfig(f_lo=base.fs_in / 2.0 + 1.0)
    except ValueError as e:
        assert "Nyquist" in str(e), e
        print("LO above Nyquist rejected OK")
        return
    raise AssertionError("an LO above Nyquist was silently accepted")


# --------------------------------------------------------------------------
# test-vector emission
# --------------------------------------------------------------------------


def test_m_and_n_are_independent_knobs():
    """M sets frequency resolution. N sets spectral purity, a separate concern."""
    c = DDCConfig()
    # The invariant, not the literal widths: the accumulator has to be wider
    # than the phase that reaches the angle path, or there is no truncation to
    # reason about in the first place.
    assert c.phase_bits > c.phase_trunc_bits

    # M controls how exactly an LO can be placed. The target is derived from
    # fs_in rather than fixed, so it stays in band at any sample rate and its
    # awkwardness does not depend on how it happens to divide fs_in.
    target = c.fs_in / 5.0 + c.fs_in / (1 << 17)
    coarse = DDCConfig(phase_bits=16, phase_trunc_bits=14, ang_bits=14, n_iter=13,
                       f_lo=target)
    fine = DDCConfig(phase_bits=32, f_lo=target)
    assert abs(coarse.f_lo_actual - target) > abs(fine.f_lo_actual - target)

    # ...while N controls the spur bound, independently of M.
    assert DDCConfig(phase_trunc_bits=10).phase_trunc_sfdr_bound_db < (
        DDCConfig(phase_trunc_bits=16).phase_trunc_sfdr_bound_db
    )
    assert abs(c.phase_trunc_sfdr_bound_db - 84.28) < 0.01
    # N cannot exceed M, and ang_bits cannot be narrower than N.
    for kw in (dict(phase_bits=12, phase_trunc_bits=14),
               dict(phase_trunc_bits=14, ang_bits=12)):
        try:
            DDCConfig(**kw)
            raised = False
        except ValueError:
            raised = True
        assert raised, f"invalid width combination accepted: {kw}"
    print("M and N are independent, both validated OK")


def test_phase_truncation_only_bites_when_the_fcw_exercises_it():
    """Confirms phase truncation only costs SFDR when the FCW has nonzero low bits.

    An LO that is a binary fraction of fs discards only zero bits, so
    truncation costs it nothing; any other LO pays the ~6.02*N spur penalty.
    Both cases are constructed here rather than one of them being inherited
    from the default config: the default LO used to be the benign case and is
    now deliberately the truncating one (see DDCConfig's docstring), and a
    test that silently depends on which it is stops testing the mechanism the
    moment that choice changes.
    """
    cfg = DDCConfig()
    ddc = DDC(cfg)
    n = 8192
    mask = (1 << (cfg.phase_bits - cfg.phase_trunc_bits)) - 1

    fs_ = G.full_scale(cfg.data_bits)
    # Benign: an FCW that is exactly representable in the truncated phase.
    benign_inc = cfg.phase_inc & ~mask
    assert benign_inc & mask == 0
    benign = ddc.nco(ddc.phase(n, inc=benign_inc))
    # Truncating: the same FCW with nonzero bits below the truncation point.
    hard_inc = (benign_inc + 0x0002AAAB) & ((1 << cfg.phase_bits) - 1)
    assert hard_inc & mask != 0
    hard = ddc.nco(ddc.phase(n, inc=hard_inc))

    s_benign = G.sfdr_db((benign[0] + 1j * benign[1]) / fs_)
    s_hard = G.sfdr_db((hard[0] + 1j * hard[1]) / fs_)
    assert s_benign > s_hard + 5, (
        f"benign LO {s_benign:.1f} dB vs truncating LO {s_hard:.1f} dB -- phase "
        f"truncation is not being modelled, or the FCWs do not differ below N"
    )
    # And the truncating case should sit near the 6.02*N bound, not far past it.
    assert s_hard < cfg.phase_trunc_sfdr_bound_db + 3, (
        f"{s_hard:.1f} dB beats the {cfg.phase_trunc_sfdr_bound_db:.1f} dBc bound "
        f"for N={cfg.phase_trunc_bits}; the truncation is being skipped"
    )
    print(
        f"phase truncation: {s_benign:.1f} dB benign vs {s_hard:.1f} dB truncating "
        f"(bound {cfg.phase_trunc_sfdr_bound_db:.1f}) OK"
    )


def test_widening_n_improves_spectral_purity():
    """Confirms N is the knob that controls NCO spectral purity."""
    n = 8192
    got = {}
    for N in (10, 14, 18):
        cfg = DDCConfig(phase_trunc_bits=N, ang_bits=max(N, 18))
        ddc = DDC(cfg)
        inc = (cfg.phase_inc + 0x0002AAAB) & ((1 << cfg.phase_bits) - 1)
        c_, s_ = ddc.nco(ddc.phase(n, inc=inc))
        got[N] = G.sfdr_db((c_ + 1j * s_) / G.full_scale(cfg.data_bits))
    assert got[10] < got[14] < got[18], f"SFDR did not improve with N: {got}"
    assert got[14] - got[10] > 15, (
        f"4 more phase bits bought only {got[14] - got[10]:.1f} dB; the classic "
        f"bound predicts ~24"
    )
    print("N sweep: " + ", ".join(f"N={k} -> {v:.1f} dB" for k, v in got.items()) + " OK")


def test_angle_word_zero_pads_rather_than_requantising():
    """After truncating to N bits, the low ang_bits-N padding bits must be zero."""
    cfg = DDCConfig()
    ddc = DDC(cfg)
    pad = cfg.ang_bits - cfg.phase_trunc_bits
    w = ddc.angle_word(ddc.phase(512, inc=(cfg.phase_inc + 12345)))
    assert pad > 0
    assert np.all((w & ((1 << pad) - 1)) == 0), "zero-padding is not zero"
    assert int(w.max()) < (1 << cfg.ang_bits)
    # Distinct truncated phases must stay distinct -- padding adds no collisions.
    assert len(np.unique(w)) == len(np.unique(G.shr(
        ddc.phase(512, inc=(cfg.phase_inc + 12345)), cfg.phase_bits - cfg.phase_trunc_bits
    )))
    print(f"angle word: N={cfg.phase_trunc_bits} truncated, zero-padded by {pad} OK")


def test_vectors_round_trip():
    """What the testbench reads back must be exactly what the model produced."""
    d = tempfile.mkdtemp(prefix="ddcvec_")
    try:
        cfg = DDCConfig()
        ddc = DDC(cfg)
        man = G.emit_vectors(ddc, d, n=1024)

        for name in man["files"]:
            assert os.path.isfile(os.path.join(d, name)), f"missing {name}"

        xi, xq = G.two_tone(1024, cfg)
        r = ddc.run(xi, xq)

        def read(name, bits):
            with open(os.path.join(d, name)) as f:
                vals = [int(line, 16) for line in f if line.strip()]
            return np.array(
                [v - (1 << bits) if v >= (1 << (bits - 1)) else v for v in vals], np.int64
            )

        for name, arr, bits in (
            ("stim_i.hex", r["stim_i"], cfg.data_bits),
            ("nco_cos.hex", r["cos"], cfg.data_bits),
            ("mix_q.hex", r["mix_q"], cfg.mix_bits),
            ("out_i.hex", r["out_i"], cfg.out_bits),
            ("fir_coef.hex", ddc.coef, cfg.coef_bits),
        ):
            back = read(name, bits)
            assert np.array_equal(back, arr), f"{name} did not round-trip"

        assert man["derived"]["n_output_samples"] == len(r["out_i"])
        assert man["derived"]["phase_inc"] == cfg.phase_inc
        json.load(open(os.path.join(d, "manifest.json")))

        svh = open(os.path.join(d, "ddc_params.svh")).read()
        # Nibbles follow the word width rather than being fixed at 8, so this
        # keeps checking the emitted literal when phase_bits changes.
        nib = (cfg.phase_bits + 3) // 4
        assert f"PHASE_INC = {cfg.phase_bits}'h{cfg.phase_inc:0{nib}x}" in svh
        assert f"localparam int N_ITER      = {cfg.n_iter};" in svh
        assert "`endif" in svh
        print(f"vectors round-trip ({len(man['files'])} files) OK")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_fused_vectors_round_trip_at_mix_bits():
    """mix_i/mix_q must be hex-encoded at mix_bits, not data_bits.

    mix_bits equals data_bits for the separate architecture, so a width bug
    here is invisible to test_vectors_round_trip's default config. Encoding
    a negative value at a narrower width than declared, then zero- rather
    than sign-extending it back, flips it positive -- that only shows up
    for the fused architecture, where mix_bits is one bit wider.
    """
    d = tempfile.mkdtemp(prefix="ddcvec_fused_")
    try:
        cfg = DDCConfig(mix_arch=MIX_FUSED)
        ddc = DDC(cfg)
        man = G.emit_vectors(ddc, d, n=1024)

        xi, xq = G.two_tone(1024, cfg)
        r = ddc.run(xi, xq)
        assert np.any(r["mix_i"] < 0) and np.any(r["mix_q"] < 0), (
            "stimulus produced no negative mix values -- test cannot catch the bug"
        )

        def read(name, bits):
            with open(os.path.join(d, name)) as f:
                vals = [int(line, 16) for line in f if line.strip()]
            return np.array(
                [v - (1 << bits) if v >= (1 << (bits - 1)) else v for v in vals], np.int64
            )

        for name, arr in (("mix_i.hex", r["mix_i"]), ("mix_q.hex", r["mix_q"])):
            back = read(name, cfg.mix_bits)
            assert np.array_equal(back, arr), f"{name} did not round-trip at mix_bits"

        # The up-convert set the RTL testbench's second and third passes read.
        # It has to be over the same stimulus and the same phase0, or those
        # passes would be comparing against a different sample alignment.
        up = ddc.mix_stage(xi, xq, downconvert=False)
        for name, arr in (("mix_up_i.hex", up["mix_i"]), ("mix_up_q.hex", up["mix_q"])):
            assert name in man["files"], f"{name} is missing from the manifest"
            back = read(name, cfg.mix_bits)
            assert np.array_equal(back, arr), f"{name} did not round-trip at mix_bits"
        assert not np.array_equal(up["mix_i"], r["mix_i"]), (
            "the up-convert vectors are identical to the down-convert ones, so "
            "the testbench's direction passes would pass without a direction bit"
        )

        print("fused mix_i/mix_q and mix_up_* round-trip at mix_bits OK")
    finally:
        shutil.rmtree(d, ignore_errors=True)


def test_clipping_inside_the_rotation_is_counted():
    """A vector that starts in range can still clip mid-rotation.

    The magnitude grows monotonically toward K*|v|, so the seeding check alone
    reports zero while the band is being corrupted. Drives a complex envelope
    past the 2/K limit and confirms the count comes back non-zero.
    """
    cfg = DDCConfig(mix_arch=MIX_FUSED)
    ddc = DDC(cfg)
    fs = G.full_scale(cfg.data_bits)
    n = 256

    # I and Q both at full scale: |v| = sqrt(2) x FS, past the 2/K ~= 1.21 x
    # limit. Every individual component is still inside data_bits, so nothing
    # is detectable at the input -- the clip happens partway through the
    # rotation, once K has grown the vector onto an axis.
    xi = np.full(n, fs - 1, np.int64)
    xq = np.full(n, fs - 1, np.int64)
    g = cfg.cordic_bits - cfg.data_bits - 1
    assert G.would_saturate(np.array([(fs - 1) << g], np.int64), cfg.cordic_bits) == 0, (
        "the seeded value must be in range, or this test would be exercising "
        "input overflow rather than the mid-rotation path it claims to"
    )

    ddc.mix_fused(xi, xq, ddc.phase(n))
    assert ddc._fused_sat > 0, (
        "a sqrt(2) x full-scale envelope clips inside the CORDIC but was "
        "reported as zero saturations"
    )
    # Counted per sample, not per iteration: a sample clipping on many
    # iterations must not inflate the total past the number of samples, or it
    # cannot be summed with fir_decimate's count.
    assert ddc._fused_sat <= n, (
        f"{ddc._fused_sat} clips reported for {n} samples -- the count is "
        f"per-iteration events, not samples, and is no longer comparable with "
        f"fir_decimate's"
    )

    # And a rotating tone, which sits at exactly 1.0 x full scale, does not.
    ti, tq = G.tone(n, cfg.fs_in, cfg.f_lo_actual + 11_000.0, 0.0, cfg.data_bits)
    ddc.mix_fused(ti, tq, ddc.phase(n))
    assert ddc._fused_sat == 0, (
        f"a full-scale rotating tone is inside the 1.21 x limit and must not "
        f"clip, but {ddc._fused_sat} saturations were counted"
    )
    print("mid-rotation clipping counted per sample; full-scale tone clean OK")


def test_quantization_that_breaks_linear_phase_is_rejected():
    """firwin_lowpass builds exact symmetry; the residue fixup can destroy it.

    The breaking width is searched for rather than hardcoded, since which
    coef_bits first moves the rounding residue off the centre tap depends on
    the filter's shape and moves whenever fir_cutoff does. A fixed number
    would silently stop testing anything the moment the filter is retuned.
    """
    cfg = DDCConfig()
    h = G.firwin_lowpass(cfg.n_taps, cfg.fir_cutoff / (cfg.fs_in / 2))

    # The configured width must keep symmetry, or the RTL's folded FIR is
    # computing a different filter than the one that was designed.
    q = G.fir_taps_quantized(h, cfg.coef_bits, 1.0 / cfg.k_gain)
    assert np.array_equal(q, q[::-1]), (
        f"{cfg.coef_bits}-bit taps are not symmetric -- fir_decimate.sv folds "
        f"on the assumption that they are"
    )

    # Somewhere below it, the argmax moves off centre and symmetry breaks.
    # If no width does, the guard has gone vacuous and this test says so.
    broke_at = None
    for bits in range(cfg.coef_bits - 1, 3, -1):
        try:
            G.fir_taps_quantized(h, bits, 1.0 / cfg.k_gain)
        except ValueError as e:
            if "linear phase" in str(e):
                broke_at = bits
                break
    assert broke_at is not None, (
        f"no coefficient width below {cfg.coef_bits} bits broke tap symmetry, so "
        f"the linear-phase guard is never exercised and may be vacuous"
    )
    print(f"linear-phase-breaking quantization rejected at {broke_at} bits OK")


def test_snr_is_measured_at_data_scale_not_out_bits():
    """The FIR's unity DC gain returns the output to input scale.

    So the SNR metric must normalise by data_bits. Normalising by out_bits
    instead reports a pure scale mismatch as if it were datapath error: at
    data_bits=14, out_bits=16 it read 2.5 dB for output that is bit-identical
    to the out_bits=14 case.
    """
    # A wider output word changes nothing about the samples themselves...
    narrow = DDC(DDCConfig(data_bits=14, out_bits=14))
    wide = DDC(DDCConfig(data_bits=14, out_bits=16))
    xi, xq = G.tone(2048, narrow.cfg.fs_in,
                    narrow.cfg.f_lo_actual + _in_band_offset(narrow.cfg),
                    -6.0, narrow.cfg.data_bits)
    rn, rw = narrow.run(xi, xq), wide.run(xi, xq)
    assert np.array_equal(rn["out_i"], rw["out_i"]), (
        "widening out_bits changed the output samples; then the scale argument "
        "below does not hold and this test is checking the wrong thing"
    )

    # ...so it must not change the score either.
    a = G.report(DDCConfig(data_bits=14, out_bits=14), n=4096)["ddc_snr_db"]
    b = G.report(DDCConfig(data_bits=14, out_bits=16), n=4096)["ddc_snr_db"]
    assert abs(a - b) < 0.01, (
        f"identical output scored {a:.2f} dB at out_bits=14 but {b:.2f} dB at "
        f"out_bits=16 -- the metric is normalising by the word width instead of "
        f"the signal's actual scale"
    )

    # And narrowing data_bits, which is a real loss, costs ~6 dB a bit -- but
    # only in the regime where data_bits is the *worst* quantizer present.
    # Two other 16-bit-class noise sources sit alongside it: the default LO's
    # phase truncation (a ~74 dB floor) and coef_bits=16. Measured at 16-bit
    # data all three contribute comparably and the 16->14 step collapses to
    # ~7 dB, which is not a metric failure but the point at which the other
    # two take over. A non-truncating LO removes one of them; the slope is
    # then asserted over 14/12/10, where data_bits is unambiguously dominant,
    # and 16 is kept only in the monotonicity check.
    benign_lo = DDCConfig().fs_in / 8.0
    assert DDCConfig(f_lo=benign_lo).phase_trunc_residue == 0, (
        "the LO chosen to isolate data_bits still exercises phase truncation, "
        "which would put a second noise source back into the measurement"
    )
    widths = (16, 14, 12, 10)
    snr = [G.report(DDCConfig(data_bits=w, out_bits=w, f_lo=benign_lo), n=4096)["ddc_snr_db"]
           for w in widths]
    assert all(a > b for a, b in zip(snr, snr[1:])), (
        f"SNR should fall monotonically with data_bits: {dict(zip(widths, snr))}"
    )
    for (wh, hi), (wl, lo) in zip(list(zip(widths, snr))[1:], list(zip(widths, snr))[2:]):
        assert 8.0 < hi - lo < 16.0, (
            f"two bits should cost roughly 12 dB between {wh} and {wl}, got {hi - lo:.1f} dB"
        )
    print("SNR normalised at data scale; "
          + "/".join(f"{s:.1f}" for s in snr)
          + f" dB across {'/'.join(str(w) for w in widths)} bits OK")


def test_default_architecture_is_the_one_the_rtl_implements():
    """Emitting vectors under the wrong arch yields a set the RTL cannot match."""
    assert DDCConfig().mix_arch == MIX_FUSED
    # The two really are incompatible, so the default is load-bearing.
    assert DDCConfig(mix_arch=MIX_SEPARATE).mix_bits != DDCConfig().mix_bits
    assert not np.array_equal(
        DDC(DDCConfig(mix_arch=MIX_SEPARATE)).coef, DDC(DDCConfig()).coef
    )
    print("default mix_arch is fused, matching the RTL OK")


def test_negative_values_encode_as_twos_complement():
    assert G._hex_lines(np.array([-1], np.int64), 16) == ["ffff"]
    assert G._hex_lines(np.array([-32768], np.int64), 16) == ["8000"]
    assert G._hex_lines(np.array([32767], np.int64), 16) == ["7fff"]
    assert G._hex_lines(np.array([-1], np.int64), 17) == ["1ffff"]
    print("two's-complement hex encoding OK")


def main():
    test_cordic_gain_matches_the_published_constant()
    test_convergence_limit_covers_the_quadrant_residual()
    test_cordic_reproduces_sin_cos_across_the_full_circle()
    test_cordic_converges_at_the_range_reduction_boundary()
    test_nco_amplitude_is_unit_because_of_the_inv_k_seed()
    test_atan_table_exhaustion_is_rejected()

    test_trunc_shift_matches_verilog_not_c()
    test_saturation_clips_and_is_counted()
    test_int64_overflow_is_caught_not_silent()

    test_sign_convention_is_not_mirrored()
    test_mirrored_mixer_is_detected()
    test_dc_lands_at_dc()

    test_k_folding_lands_both_architectures_on_the_same_scale()
    test_k_folded_the_wrong_way_is_4_3_db_hot()
    test_fused_mixer_carries_one_extra_bit()

    test_separate_and_fused_agree()
    test_wrong_rotation_direction_in_fused_is_caught()

    test_upconvert_matches_the_analytic_rotation()
    test_upconvert_then_downconvert_returns_the_input()
    test_direction_is_a_port_not_a_parameter()
    test_separate_mixer_refuses_to_upconvert()

    test_interpolator_targets_decim_over_k_gain()
    test_polyphase_decomposition_matches_zero_stuffed_convolution()
    test_interpolate_then_decimate_round_trip()
    test_tx_then_rx_round_trip()
    test_tx_stage_refuses_the_separate_mixer()

    test_fir_has_unit_dc_gain_and_linear_phase()
    test_fir_rejects_out_of_band()
    test_decimation_takes_the_right_phase()
    test_aliasing_cutoff_is_rejected()

    test_fixed_point_tracks_the_ideal_model()
    test_narrower_datapath_is_measurably_worse()
    test_lo_quantization_is_reported_honestly()
    test_lo_above_nyquist_is_rejected()
    test_m_and_n_are_independent_knobs()
    test_phase_truncation_only_bites_when_the_fcw_exercises_it()
    test_widening_n_improves_spectral_purity()
    test_angle_word_zero_pads_rather_than_requantising()

    test_clipping_inside_the_rotation_is_counted()
    test_quantization_that_breaks_linear_phase_is_rejected()
    test_snr_is_measured_at_data_scale_not_out_bits()
    test_default_architecture_is_the_one_the_rtl_implements()

    test_vectors_round_trip()
    test_fused_vectors_round_trip_at_mix_bits()
    test_negative_values_encode_as_twos_complement()
    print("\nALL TESTS PASSED")


if __name__ == "__main__":
    main()
