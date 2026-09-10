"""Receives the DE1-SoC's baseband IQ stream over UDP and writes it to a file.

hps/iq_streamd.c on the board's ARM core drains the FPGA's FIFO and sends
raw interleaved little-endian int16 pairs, one datagram per 360 pairs. That
is what GNU Radio's udp_source reads directly (host/rx_qpsk.grc); this script
is for capturing to disk and for checking a board without a flowgraph.

--self-check runs offline, so CI covers the host side too.

Run:
    python host/iq_udp.py --out build/capture.cf32 --seconds 5
    python host/iq_udp.py --check-selftest
    python host/iq_udp.py --self-check
"""

from __future__ import annotations

import argparse
import os
import socket
import sys
import time

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_REF_DIR = os.path.join(os.path.dirname(_HERE), "cordic", "reference")
if _REF_DIR not in sys.path:
    sys.path.insert(0, _REF_DIR)

PAIRS_PER_DATAGRAM = 360
BYTES_PER_DATAGRAM = PAIRS_PER_DATAGRAM * 4
DEFAULT_PORT = 5000

FS_IN_HZ = 400_000.0
DECIM = 8
PHASE_BITS = 24


def encode_payload(iq_i, iq_q) -> bytes:
    """Build the bytes iq_streamd would send for these samples."""
    pairs = np.empty((len(iq_i), 2), dtype="<i2")
    pairs[:, 0] = np.asarray(iq_i, dtype="<i2")
    pairs[:, 1] = np.asarray(iq_q, dtype="<i2")
    return pairs.tobytes()


def decode_payload(data: bytes) -> np.ndarray:
    """Decode a datagram into an (N, 2) int16 array of I/Q.

    Raises:
        ValueError: If the datagram does not hold whole pairs.
    """
    if len(data) % 4 != 0:
        raise ValueError(f"{len(data)} bytes is not a whole number of IQ pairs")
    return np.frombuffer(data, dtype="<i2").reshape(-1, 2)


def phase_inc(lo_hz: float, fs_in: float = FS_IN_HZ,
              bits: int = PHASE_BITS) -> int:
    """Tuning word for an LO, mirroring iq_phase_inc() in hps/iq_streamd.c.

    The NCO advances once per ADC sample, so the word is a fraction of the
    converter's rate whichever tap is selected. Out-of-band and negative
    frequencies wrap.
    """
    scale = 1 << bits
    return int(round(lo_hz / fs_in * scale)) % scale


def write_samples(path: str, samples: np.ndarray, fmt: str) -> None:
    """Write decoded samples in the requested on-disk format.

    Args:
        path: Output file.
        samples: (N, 2) int16 array of I/Q.
        fmt: "cfloat" for complex64 normalised to +/-1.0, or "int16" for the
            raw interleaved words.
    """
    with open(path, "wb") as f:
        if fmt == "cfloat":
            scale = float(1 << 15)
            c = (samples[:, 0].astype(np.float32) / scale
                 + 1j * samples[:, 1].astype(np.float32) / scale)
            f.write(c.astype(np.complex64).tobytes())
        else:
            f.write(samples.astype("<i2").tobytes())


def receive(port: int, seconds: float, max_pairs: int = -1,
            quiet: bool = False):
    """Collect pairs from the socket until a time or sample limit.

    Returns:
        An (N, 2) int16 array and the number of datagrams received.
    """
    sock = socket.socket(socket.AF_INET, socket.SOCK_DGRAM)
    sock.setsockopt(socket.SOL_SOCKET, socket.SO_RCVBUF, 4 << 20)
    sock.settimeout(0.5)
    sock.bind(("0.0.0.0", port))

    chunks = []
    n_pairs = 0
    n_dgram = 0
    deadline = time.time() + seconds
    if not quiet:
        print(f"listening on udp/{port}")

    while time.time() < deadline:
        try:
            data, _ = sock.recvfrom(65535)
        except socket.timeout:
            continue
        block = decode_payload(data)
        chunks.append(block)
        n_pairs += len(block)
        n_dgram += 1
        if 0 <= max_pairs <= n_pairs:
            break

    sock.close()
    if not chunks:
        return np.zeros((0, 2), dtype=np.int16), 0
    return np.concatenate(chunks), n_dgram


def capture(port: int, seconds: float, out: str, fmt: str) -> int:
    """Record the stream to a file."""
    samples, n_dgram = receive(port, seconds)
    if len(samples) == 0:
        print("no datagrams arrived -- check the board's --host and the "
              "firewall", file=sys.stderr)
        return 1

    rate = len(samples) / seconds
    print(f"{len(samples)} pairs in {n_dgram} datagrams, {rate/1e3:.1f} kS/s")
    if out:
        write_samples(out, samples, fmt)
        print(f"wrote {out}")
    return 0


def _selftest_stim_len() -> int:
    """Read the self-test ROM's length from the generated include.

    Taken from the header rather than repeated, so a regenerated ROM cannot
    disagree with the host.
    """
    path = os.path.join(os.path.dirname(_HERE), "de1soc", "selftest_rom.svh")
    with open(path, encoding="utf-8") as f:
        for line in f:
            if line.startswith("`define SELFTEST_N_STIM"):
                return int(line.split()[-1])
    raise RuntimeError(f"SELFTEST_N_STIM not found in {path}")


def _selftest_expected():
    """Return the decimated output the board's ROM self-test should produce."""
    import ddc_reference as G

    cfg = G.DDCConfig()
    ddc = G.DDC(cfg)
    xi, xq = G.two_tone(_selftest_stim_len(), cfg)
    r = ddc.run(xi, xq)
    return r["out_i"], r["out_q"]


def check_selftest(port: int) -> int:
    """Verify a board in self-test mode against the reference model.

    With SW[0] low every sample on the wire is predictable, so this checks
    the whole egress path with no analog signal involved. Start iq_streamd
    with --rate decimated: the ROM's expected outputs are FIR outputs.
    """
    exp_i, exp_q = _selftest_expected()
    n_expected = len(exp_i)
    print(f"expecting {n_expected} self-test outputs on udp/{port}")

    samples, _ = receive(port, seconds=10.0, max_pairs=n_expected)
    n = min(len(samples), n_expected)
    if n == 0:
        print("no samples arrived", file=sys.stderr)
        return 1

    bad = int(np.count_nonzero((samples[:n, 0] != exp_i[:n])
                               | (samples[:n, 1] != exp_q[:n])))
    print(f"compared {n} samples against the reference model: {bad} mismatch(es)")
    if bad:
        print("the self-test LEDs report the datapath; a mismatch only "
              "here points at the link", file=sys.stderr)
        return 1
    print("SELF-TEST STREAM MATCHES THE REFERENCE MODEL")
    return 0


def check_ramp(port: int, pairs: int) -> int:
    """Verify the ramp hps/fake_bus.h serves, for the software-only test."""
    samples, n_dgram = receive(port, seconds=20.0, max_pairs=pairs)
    if len(samples) < pairs:
        print(f"received {len(samples)} of {pairs} pairs", file=sys.stderr)
        return 1

    k = np.arange(pairs) % 1000
    bad = int(np.count_nonzero((samples[:pairs, 0] != k)
                               | (samples[:pairs, 1] != -k)))
    if bad:
        print(f"{bad} of {pairs} pairs did not match the ramp", file=sys.stderr)
        return 1
    print(f"RAMP OK ({pairs} pairs in {n_dgram} datagrams)")
    return 0


def self_check() -> int:
    """Exercise the payload codec and the tuning arithmetic offline."""
    rng = np.random.default_rng(7)
    n = PAIRS_PER_DATAGRAM * 3
    exp_i = rng.integers(-32768, 32767, n, dtype=np.int64)
    exp_q = rng.integers(-32768, 32767, n, dtype=np.int64)

    raw = encode_payload(exp_i, exp_q)
    if len(raw) != 4 * n:
        print(f"encoded {len(raw)} bytes for {n} pairs", file=sys.stderr)
        return 1

    fails = 0
    for d in range(0, len(raw), BYTES_PER_DATAGRAM):
        block = decode_payload(raw[d:d + BYTES_PER_DATAGRAM])
        if len(block) != PAIRS_PER_DATAGRAM:
            print(f"datagram at {d} decoded {len(block)} pairs", file=sys.stderr)
            fails += 1

    got = decode_payload(raw)
    if not np.array_equal(got[:, 0], exp_i) or not np.array_equal(got[:, 1], exp_q):
        print("round trip changed the samples", file=sys.stderr)
        fails += 1

    if BYTES_PER_DATAGRAM > 1472:
        print(f"{BYTES_PER_DATAGRAM}-byte payload fragments a 1500-byte MTU",
              file=sys.stderr)
        fails += 1

    # Quarter, half, and negative rates, plus the tone the ADC vectors use.
    for lo, want in ((0.0, 0),
                     (FS_IN_HZ / 4, 1 << (PHASE_BITS - 2)),
                     (FS_IN_HZ / 2, 1 << (PHASE_BITS - 1)),
                     (-FS_IN_HZ / 4, (1 << PHASE_BITS) - (1 << (PHASE_BITS - 2))),
                     (85_000.0, 3_565_158)):
        got_w = phase_inc(lo)
        if got_w != want:
            print(f"phase_inc({lo}) is {got_w}, expected {want}", file=sys.stderr)
            fails += 1

    if fails:
        print(f"{fails} CHECK(S) FAILED", file=sys.stderr)
        return 1

    print(f"HOST SELF-CHECK PASSED ({n} pairs round-tripped, "
          f"{BYTES_PER_DATAGRAM}-byte datagrams, tuning words verified)")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", type=int, default=DEFAULT_PORT,
                   help=f"UDP port to listen on (default {DEFAULT_PORT})")
    p.add_argument("--seconds", type=float, default=5.0,
                   help="capture duration")
    p.add_argument("--out", default=None, help="output file")
    p.add_argument("--format", choices=("cfloat", "int16"), default="cfloat",
                   help="on-disk sample format")
    p.add_argument("--check-selftest", action="store_true",
                   help="compare a board in self-test mode against the model")
    p.add_argument("--check-ramp", type=int, metavar="PAIRS",
                   help="verify the ramp hps/fake_bus.h serves")
    p.add_argument("--self-check", action="store_true",
                   help="exercise the codec and tuning arithmetic offline")
    p.add_argument("--lo-hz", type=float,
                   help="print the tuning word for this LO and exit")
    args = p.parse_args(argv)

    if args.lo_hz is not None:
        print(f"{phase_inc(args.lo_hz):#08x}")
        return 0
    if args.self_check:
        return self_check()
    if args.check_ramp:
        return check_ramp(args.port, args.check_ramp)
    if args.check_selftest:
        return check_selftest(args.port)
    return capture(args.port, args.seconds, args.out, args.format)


if __name__ == "__main__":
    sys.exit(main())
