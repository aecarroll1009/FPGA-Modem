# IQ path off the board

The FPGA fills a FIFO, the HPS drains it over the lightweight bridge and
sends UDP. `de1soc/iq_avalon_fifo.sv`, `hps/iq_streamd.c`, `host/iq_udp.py`.

## Register map

Avalon-MM slave at `0xFF200000`, the base of the lightweight HPS-to-FPGA
bridge. Word offsets; also in `hps/iq_regs.h`.

| off | reg | | |
|---|---|---|---|
| 0x00 | ID | RO | `0x53445202` — "SDR", version 2 |
| 0x04 | CTRL | RW | `[0]` full-rate tap, `[1]` enable, `[2]` flush |
| 0x08 | PHASE_INC | RW | `[23:0]` LO tuning word |
| 0x0C | LEVEL | RO | words ready |
| 0x10 | STATUS | RO | `[15:0]` pairs dropped, `[16]` overflow |
| 0x14 | DATA | RO | pops `{i[15:0], q[15:0]}`, zero when empty |

Reads have a fixed latency of one clock and never stall. `enable` is low
out of reset, so nothing is dropped while Linux boots. `flush` clears the
FIFO and the drop counters and clears itself.

`PHASE_INC` is a fraction of the converter's 400 kS/s, since the NCO
advances once per ADC sample whichever tap is selected:

```
phase_inc = round(f_lo / 400000 * 2**24) mod 2**24
```

`CTRL[0]` picks where the samples come from: the mixer at 400 kS/s, or the
decimating FIR at 50 kS/s. Full rate is the default and gives 200 kHz of
spectrum against the FIR's 25 kHz.

## Wire format

Raw interleaved little-endian `int16`, I then Q, 360 pairs per datagram.
No header: UDP already delimits, and a header would need a custom GNU
Radio block to strip. 1440 bytes fits a 1500-byte MTU without fragmenting.

Drops are counted in `STATUS`, not marked in the stream; `iq_streamd`
prints them as they happen.

## Rates

| | full rate | decimated |
|---|---|---|
| Samples | 400 kS/s | 50 kS/s |
| Payload | 1.60 MB/s | 200 kB/s |
| Datagrams | 4444/s | 556/s |
| Share of the gigabit link | 1.3% | 0.2% |

A 4096-word FIFO holds about 10 ms at the full rate, which covers the gaps
a userspace reader takes. Each `/dev/mem` read is an uncached bus access of
roughly half a microsecond, so draining 400 kS/s costs a fifth of a core.

## Reading it

Live, in GNU Radio (`host/rx_qpsk.grc`): a stock `udp_source` of shorts
into `interleaved_short_to_complex`.

To a file:

```
python host/iq_udp.py --out build/capture.cf32 --seconds 5
```

## Self-test mode

With `SW[0]` low the board replays its stimulus ROM instead of the ADC, so
the samples are known in advance. Run `iq_streamd --rate decimated` — the
ROM's expected outputs are FIR outputs — then:

```
python host/iq_udp.py --check-selftest
```

That checks the datapath, the bridge, the daemon, and the network before
any analog signal is involved.
