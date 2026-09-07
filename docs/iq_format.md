# IQ wire format

What `de1soc/iq_framer.sv` emits and `host/capture_iq.py` decodes.

## Link

| | |
|---|---|
| Pin | GPIO_0[0], `PIN_AC18` |
| Level | 3.3 V LVTTL — not RS-232 |
| Baud | 2 500 000, 8N1, no flow control |
| Direction | FPGA → host only |

Wire GPIO_0[0] to the adapter's RX and tie the grounds together. 2.5 Mbaud is
inside the FT232R's ceiling; CH340-class adapters often top out below it and
drop bytes.

## Frame

262 bytes: a 6-byte header then 64 IQ pairs. All multi-byte fields big-endian.

```
offset  size  field
------  ----  ---------------------------------------------
     0     4  magic: 0x53 0x44 0x52 0x01  ("SDR", version 1)
     4     2  frame counter, wraps at 65536
     6   256  64 pairs of I high, I low, Q high, Q low (int16)
```

Samples are 16-bit signed at 50 kS/s.

## Reading

Scan for the magic to synchronise; a mid-stream attach finds the next boundary
within 262 bytes. The magic can occur inside payload data, so `capture_iq.py`
requires the frame counter to advance across consecutive frames before
trusting the alignment. Counter gaps mean lost bytes — usually an adapter that
cannot hold the baud rate.

## Rate

| | |
|---|---|
| Payload | 50 000 IQ/s × 4 B = 200 000 B/s |
| With framing | 204 688 B/s |
| Capacity | 250 000 B/s |
| Utilisation | 81.9% |

A 32-byte FIFO in `DE1_SoC.sv` absorbs the header burst.

## Overflow

`LEDR[4]` latches if an IQ pair is dropped before the UART, `LEDR[5]` if the
converter outruns the datapath. Drops are not marked in the stream — the frame
stays 64 samples — so the LEDs are the only indication.

## Self-test mode

With `SW[0]` low the board replays its stimulus ROM instead of the ADC, so the
output is known in advance:

```
python host/capture_iq.py --port COM4 --check-selftest
```

That checks framing, baud rate, byte order, and the adapter before any analog
signal is involved.
