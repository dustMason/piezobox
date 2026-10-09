# Continuous ADC transport (PZLC2)

Target: Teensy LC, 48 MHz, USB Serial, Teensy boards package 1.62.0.
This is a raw ADC transport, not USB Audio. All rates are **frames/second**;
each frame contains one sample from every requested input, in command order.
The LC has one ADC, so inputs are acquired sequentially, not simultaneously.

## Commands

Commands are newline-terminated ASCII. Only `STOP` is accepted during a session.

```text
INFO
STREAM 32000 0 fast 15 16 17 18 19 20 21
STOP
```

`INFO` retains the `PZLC1 Teensy-LC` prefix for existing clients and includes
`FW=2`. `STREAM <rate> <frames> <profile> <pins...>` selects one to thirteen
distinct ADC pins 14–26. A frame count of zero runs until `STOP`; positive
counts stop after that many attempted frames. Rate limits of 250–96,000 are
parser limits, **not a promise of achievable performance**. Use measured rates.

The seven-input set 15–21 is provisional. Pin 21/A7 is the confirmed cable-tip
connection; not every piezo has been mapped. No digital outputs are driven.

Profiles:

| Profile | ADC configuration | Channel switching |
|---|---|---|
| `settled` | 12 bits, 16 MHz ADC clock, high-speed mode, longest sample window | Discard one conversion after every switch when using multiple inputs |
| `fast` | 12 bits, 16 MHz ADC clock, high-speed mode, short sample window | Keep every conversion; DMA scans when all pins share one ADC mux bank |

The typical seven-input scan uses DMA in `fast` mode. DMA reads each ADC result
directly into the ring, then a linked DMA channel selects the next input. Its
last write disables the ADC. The next timer tick publishes the completed scan
and launches another. A scan still busy at that tick stops capture with an
acquisition error. Mixed mux-bank selections (pin 25 plus other pins) use the
polled path and need independent throughput qualification.

`settled` offers more acquisition time; it does not guarantee accurate settling
through this box's high-impedance piezo/pot circuitry. Neither mode fixes bias,
clipping, hum, crosstalk, or absent anti-alias filtering. Twelve stored bits do
not establish twelve effective bits of analog accuracy.

`CAP <rate> <frames> <pins...>` remains PZLC1-compatible, with the original ADC
timing, 250–16,000 Hz range and finite captures up to 600 seconds. Piezo Scope
continues to use this command for one selected input. Each new command restores
its own ADC configuration, including after switching profiles.

## Stream header and packets

The response begins with a single ASCII line:

```text
PZLC2 <rate> <channels> <frames> <profile> <pins...>\n
```

Subsequent packets are binary. All integers are unsigned little-endian.

### `PZD2`: ADC data

| Offset | Size | Field |
|---|---|---|
| 0 | 4 | ASCII `PZD2` |
| 4 | 2 | Number of frames, 1–16 |
| 6 | 1 | Channel count |
| 7 | 1 | ADC width, 12 |
| 8 | 8 | Sequence of first frame |
| 16 | variable | Packed samples in frame-major, channel-major order |

Samples are losslessly packed in pairs. For values `a` and `b`, bytes are
`a & 255`, `(a >> 8) | ((b & 15) << 4)`, and `b >> 4`. Pairs may cross frame
boundaries. An odd trailing sample uses two bytes; the high four bits of its
last byte must be zero. Payload size is `ceil(frames × channels × 12 / 8)`.

All frames within a packet have consecutive sequences. The sender breaks a
packet at a sequence gap. The receiver must account for gaps across packets
and compare them with the final dropped-frame count. USB supplies link-level
error detection; this format does not add a CRC or support resynchronization
after arbitrary corruption. Invalid or truncated packets fail the capture.

### `PZS2`: live statistics; `PZE2`: final statistics

These packets are 56 bytes. After the four-byte marker, the structure is
`<5Q3I` in Python `struct` notation:

| Field | Size |
|---|---|
| Attempted frames | 8 |
| Device-dropped frames | 8 |
| Slow timer callbacks / acquisition overruns | 8 |
| Late timer intervals | 8 |
| Elapsed capture microseconds | 8 |
| Maximum timer callback duration, microseconds | 4 |
| Maximum timer interval, microseconds | 4 |
| Stop reason | 4 |

Live statistics are sent approximately once per second and can include frames
still buffered on the device. Only the final packet closes the session.
Sequence/counter widths support runs beyond the old 32-bit counter limit.
Elapsed time accumulates unsigned differences across `micros()` wrap; wrap
handling is implemented but has not been qualified by a >71-minute hardware run.

Stop reasons: 0 = requested frame count reached; 1 = `STOP`; 2 = timer setup
failed; 3 = eight consecutive over-budget timer callbacks; 4 = ADC/DMA failure
or unfinished scan at the next frame deadline; 5 = short USB write.

A slow timer callback takes at least the rounded-up frame period. A late
interval exceeds 1.5 frame periods. In DMA mode the reported callback duration
measures CPU setup/publication work; the ADC runs asynchronously between ticks.
These checks detect overload, not every sub-period timing variation. The PIT
period is quantized to bus-clock ticks, so arbitrary requested rates can differ
slightly from actual rates. Finite DMA runs include a final publication tick in
elapsed time. Host `STOP` timing includes USB/host latency.

## Buffering and USB

The seven-input ring has 128 slots (127 usable). At 32 kHz that buffers about
4 ms of data. Full buffers produce explicit sequence gaps and drop counts;
they do not stretch the sampling clock. Sampling runs independently of USB
packet writes. The sender batches up to 16 frames, waiting at most about 2 ms
for a partial packet at lower rates, and drains before the final statistics.

With seven inputs and full packets, payload is 10.5 bytes/frame and packet
headers add 1 byte/frame. At 32 kHz that is 336,000 sample bytes/s, approximately
368,000 serial-protocol bytes/s, plus live statistics. USB bus transactions
have additional overhead. The serial baud setting does not limit Teensy USB.

Use `streaming.py` to archive `.pzlc` bytes without per-sample WAV conversion
in the receive path. Convert afterward with `capture.py decode`. The decoder
keeps separate channel files and inserts silence for reported missing frames;
it never classifies such a capture as passing timing checks. Standard WAV has
a roughly 4 GB limit; split very long recordings before converting them.

## Hardware references

- [PJRC USB Serial](https://www.pjrc.com/teensy/td_serial.html): native USB transport and baud behavior.
- [KL26 reference manual](https://www.pjrc.com/teensy/KL26P121M48SF4RM.pdf): ADC sampling and DMA channel linking (chapters 28 and 23).
- [KL26 data sheet](https://www.pjrc.com/teensy/KL26P64M48SF5.pdf): ADC clock and analog source requirements.

The 16 MHz clock is within the data-sheet maximum for 12-bit conversions with
high-speed mode enabled. The ADC's standalone conversion ceiling is not the
same as the complete seven-input USB streaming rate.
