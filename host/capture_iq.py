"""Captures the DE1-SoC's baseband IQ stream and writes it to a file.

Reads the framed byte stream in docs/iq_format.md from a serial port,
resynchronises on the frame magic, reports dropped frames from counter gaps,
and writes a format GNU Radio can open (host/rx_qpsk.grc).

--self-check decodes a synthetic stream, so CI covers the host side too.

Run:
    python host/capture_iq.py --port COM4 --out build/capture.cf32
    python host/capture_iq.py --port /dev/ttyUSB0 --seconds 5
    python host/capture_iq.py --port COM4 --check-selftest
    python host/capture_iq.py --self-check
"""

from __future__ import annotations

import argparse
import os
import struct
import sys
import time

import numpy as np

_HERE = os.path.dirname(os.path.abspath(__file__))
_REF_DIR = os.path.join(os.path.dirname(_HERE), "cordic", "reference")
if _REF_DIR not in sys.path:
    sys.path.insert(0, _REF_DIR)

MAGIC = b"\x53\x44\x52\x01"
SAMPLES_PER_FRAME = 64
HEADER_BYTES = 6
FRAME_BYTES = HEADER_BYTES + 4 * SAMPLES_PER_FRAME
BAUD = 2_500_000


def encode_frames(iq_i, iq_q, first_seq: int = 0) -> bytes:
    """Build the byte stream iq_framer.sv would emit for these samples.

    The inverse of decode_stream().

    Args:
        iq_i, iq_q: Equal-length integer sample arrays.
        first_seq: Frame counter value for the first frame.

    Returns:
        The encoded byte stream.
    """
    out = bytearray()
    seq = first_seq
    for n, (i, q) in enumerate(zip(iq_i, iq_q)):
        if n % SAMPLES_PER_FRAME == 0:
            out += MAGIC
            out += struct.pack(">H", seq & 0xFFFF)
            seq += 1
        out += struct.pack(">hh", int(i), int(q))
    return bytes(out)


def _frame_at(data: bytes, pos: int) -> bool:
    """Report whether a well-formed frame header sits at `pos`."""
    return data[pos:pos + 4] == MAGIC


def find_sync(data: bytes, start: int = 0) -> int:
    """Find a trustworthy frame boundary.

    The magic can appear inside payload data, so a candidate is accepted only
    if the next frame also starts with the magic and carries the next
    sequence number.

    Args:
        data: Buffered stream.
        start: Index to begin searching from.

    Returns:
        Index of a frame boundary, or -1 if none is confirmed yet.
    """
    pos = start
    while True:
        pos = data.find(MAGIC, pos)
        if pos < 0 or pos + 2 * FRAME_BYTES > len(data):
            return -1
        nxt = pos + FRAME_BYTES
        if _frame_at(data, nxt):
            s0 = struct.unpack_from(">H", data, pos + 4)[0]
            s1 = struct.unpack_from(">H", data, nxt + 4)[0]
            if s1 == ((s0 + 1) & 0xFFFF):
                return pos
        pos += 1


def decode_stream(data: bytes, start: int = 0):
    """Decode as many whole frames as the buffer holds.

    Args:
        data: Buffered stream, starting at a frame boundary.
        start: Index of that boundary.

    Returns:
        A (samples, seqs, consumed) tuple: an (N, 2) int16 array of I/Q, the
        frame counter of each decoded frame, and how many bytes were used.
    """
    samples = []
    seqs = []
    pos = start
    while pos + FRAME_BYTES <= len(data):
        if not _frame_at(data, pos):
            break
        seqs.append(struct.unpack_from(">H", data, pos + 4)[0])
        body = data[pos + HEADER_BYTES:pos + FRAME_BYTES]
        vals = np.frombuffer(body, dtype=">i2").astype(np.int16)
        samples.append(vals.reshape(-1, 2))
        pos += FRAME_BYTES
    if samples:
        return np.concatenate(samples), seqs, pos - start
    return np.zeros((0, 2), dtype=np.int16), [], 0


def count_dropped(seqs) -> int:
    """Count frames missing from a decoded sequence-number list."""
    dropped = 0
    for a, b in zip(seqs, seqs[1:]):
        gap = (b - a) & 0xFFFF
        if gap != 1:
            dropped += gap - 1
    return dropped


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


def capture(port: str, seconds: float, out: str, fmt: str) -> int:
    """Read the stream from a serial port until the time limit is reached.

    Args:
        port: Serial device name.
        seconds: How long to capture; 0 means until interrupted.
        out: Output file path, or None to discard.
        fmt: On-disk format, see write_samples().

    Returns:
        Process exit code.
    """
    try:
        import serial
    except ImportError:
        print("pyserial is not installed: pip install pyserial", file=sys.stderr)
        return 2

    ser = serial.Serial(port, BAUD, timeout=0.1)
    buf = bytearray()
    collected = []
    all_seqs = []
    synced = False
    start_t = time.time()

    print(f"reading {port} at {BAUD} baud; Ctrl-C to stop")
    try:
        while seconds == 0 or (time.time() - start_t) < seconds:
            chunk = ser.read(65536)
            if chunk:
                buf += chunk
            if not synced:
                pos = find_sync(bytes(buf))
                if pos < 0:
                    continue
                del buf[:pos]
                synced = True
                print(f"synchronised after {pos} bytes")
            s, seqs, used = decode_stream(bytes(buf))
            if used:
                del buf[:used]
                collected.append(s)
                all_seqs += seqs
    except KeyboardInterrupt:
        print("\ninterrupted")
    finally:
        ser.close()

    if not collected:
        print("no frames decoded -- check the wiring, the baud rate, and that "
              "the adapter can hold 2.5 Mbaud", file=sys.stderr)
        return 1

    samples = np.concatenate(collected)
    dropped = count_dropped(all_seqs)
    elapsed = time.time() - start_t
    print(f"{len(all_seqs)} frames, {len(samples)} IQ samples in {elapsed:.1f} s "
          f"({len(samples)/elapsed:.0f} S/s), {dropped} frame(s) dropped")
    if dropped:
        print("dropped frames mean the host lost bytes; LEDR[4] reports "
              "drops on the FPGA side")

    if out:
        write_samples(out, samples, fmt)
        print(f"wrote {out} ({fmt})")
    return 0


def _selftest_stim_len() -> int:
    """Read the self-test ROM's length from the generated include.

    Taken from the header rather than repeated, so a regenerated ROM cannot
    disagree with the host.

    Returns:
        The number of stimulus samples in the ROM.
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


def check_selftest(port: str) -> int:
    """Verify a board in self-test mode against the reference model.

    With SW[0] low every sample on the wire is predictable, so this checks
    the whole egress path with no analog signal involved.

    Args:
        port: Serial device name.

    Returns:
        Process exit code.
    """
    try:
        import serial
    except ImportError:
        print("pyserial is not installed: pip install pyserial", file=sys.stderr)
        return 2

    exp_i, exp_q = _selftest_expected()
    n_expected = len(exp_i)

    ser = serial.Serial(port, BAUD, timeout=0.5)
    buf = bytearray()
    deadline = time.time() + 10.0
    print(f"reading {port}; expecting {n_expected} self-test outputs")
    while time.time() < deadline and len(buf) < 4 * FRAME_BYTES:
        chunk = ser.read(65536)
        if chunk:
            buf += chunk
    ser.close()

    pos = find_sync(bytes(buf))
    if pos < 0:
        print("never synchronised to a frame boundary", file=sys.stderr)
        return 1
    samples, _, _ = decode_stream(bytes(buf), pos)

    n = min(len(samples), n_expected)
    if n == 0:
        print("no samples decoded", file=sys.stderr)
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


def self_check() -> int:
    """Round-trip the decoder against an independently built stream.

    Covers a clean decode, a mid-stream attach, a payload containing the
    magic by chance, and dropped-frame counting.

    Returns:
        Process exit code.
    """
    exp_i, exp_q = _selftest_expected()
    n = (len(exp_i) // SAMPLES_PER_FRAME) * SAMPLES_PER_FRAME
    if n == 0:
        # The ROM is shorter than one frame; pad to get whole frames.
        reps = SAMPLES_PER_FRAME * 3 // max(len(exp_i), 1) + 1
        exp_i = np.tile(exp_i, reps)
        exp_q = np.tile(exp_q, reps)
        n = (len(exp_i) // SAMPLES_PER_FRAME) * SAMPLES_PER_FRAME
    exp_i, exp_q = exp_i[:n], exp_q[:n]

    stream = encode_frames(exp_i, exp_q)
    fails = 0

    # Clean decode.
    pos = find_sync(stream)
    if pos != 0:
        fails += 1
        print(f"FAIL: clean stream synchronised at {pos}, expected 0")
    samples, seqs, _ = decode_stream(stream, max(pos, 0))
    if len(samples) != n:
        fails += 1
        print(f"FAIL: decoded {len(samples)} samples, expected {n}")
    elif not (np.array_equal(samples[:, 0], exp_i)
              and np.array_equal(samples[:, 1], exp_q)):
        fails += 1
        print("FAIL: decoded samples differ from what was encoded")
    if seqs != list(range(len(seqs))):
        fails += 1
        print(f"FAIL: frame counters are {seqs[:8]}...")

    # Mid-stream attach: a partial frame ahead of the first boundary.
    offset = HEADER_BYTES + 4 * 7
    pos = find_sync(stream[offset:])
    if pos < 0:
        fails += 1
        print("FAIL: never synchronised on a mid-stream attach")
    else:
        s2, _, _ = decode_stream(stream[offset:], pos)
        want = exp_i[SAMPLES_PER_FRAME:SAMPLES_PER_FRAME + len(s2)]
        if not np.array_equal(s2[:, 0], want):
            fails += 1
            print("FAIL: mid-stream attach decoded the wrong samples")

    # A magic inside the payload must not fool the sync.
    decoy_i = exp_i.copy()
    decoy_q = exp_q.copy()
    decoy_i[10] = struct.unpack(">h", MAGIC[0:2])[0]
    decoy_q[10] = struct.unpack(">h", MAGIC[2:4])[0]
    decoy = encode_frames(decoy_i, decoy_q)
    pos = find_sync(decoy)
    if pos != 0:
        fails += 1
        print(f"FAIL: a magic inside the payload moved sync to {pos}")

    # Dropped-frame accounting.
    if count_dropped([0, 1, 2, 5, 6]) != 2:
        fails += 1
        print("FAIL: dropped-frame count is wrong")
    if count_dropped([65534, 65535, 0, 1]) != 0:
        fails += 1
        print("FAIL: frame counter wraparound counted as a drop")

    if fails:
        print(f"{fails} CHECK(S) FAILED")
        return 1
    print(f"HOST DECODER PASSED ({n} samples, {n // SAMPLES_PER_FRAME} frames, "
          f"sync/mid-attach/decoy/drop-count)")
    return 0


def main(argv=None) -> int:
    p = argparse.ArgumentParser(
        description=__doc__, formatter_class=argparse.RawDescriptionHelpFormatter)
    p.add_argument("--port", help="serial device, e.g. COM4 or /dev/ttyUSB0")
    p.add_argument("--seconds", type=float, default=5.0,
                   help="capture duration; 0 runs until interrupted")
    p.add_argument("--out", default=None, help="output file")
    p.add_argument("--format", choices=("cfloat", "int16"), default="cfloat",
                   help="cfloat is GNU Radio's native complex64")
    p.add_argument("--check-selftest", action="store_true",
                   help="board is in ROM self-test mode: verify the stream "
                        "against the reference model")
    p.add_argument("--self-check", action="store_true",
                   help="test the decoder against a synthetic stream; needs "
                        "no hardware")
    a = p.parse_args(argv)

    if a.self_check:
        return self_check()
    if not a.port:
        p.error("--port is required unless --self-check is given")
    if a.check_selftest:
        return check_selftest(a.port)
    return capture(a.port, a.seconds, a.out, a.format)


if __name__ == "__main__":
    raise SystemExit(main())
