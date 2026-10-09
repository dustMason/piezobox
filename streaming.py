#!/usr/bin/env python3
"""Packed, continuous PZLC2 receiver. Saves original samples without WAV work in the hot path."""
from __future__ import annotations
import argparse
import datetime as dt
import json
import math
from pathlib import Path
import signal
import struct
import sys
import time


class StreamError(Exception):
    pass


def exact(reader, count):
    result = bytearray()
    while len(result) < count:
        part = reader.read(count - len(result))
        if not part:
            raise StreamError("USB stream ended or timed out mid-packet")
        result.extend(part)
    return bytes(result)


def parse_header(line):
    try:
        fields = line.decode("ascii").split()
        if len(fields) < 6 or fields[0] != "PZLC2": raise ValueError()
        rate, channels, frames = map(int, fields[1:4])
        profile = fields[4]
        pins = list(map(int, fields[5:]))
        if not (250 <= rate <= 96000 and 1 <= channels <= 13 and 0 <= frames < 2**64): raise ValueError()
        if profile not in ("settled", "fast"): raise ValueError()
        if not (len(pins) == channels == len(set(pins)) and all(14 <= p <= 26 for p in pins)): raise ValueError()
    except (ValueError, UnicodeError):
        raise StreamError(f"Invalid PZLC2 header: {line!r}") from None
    return dict(rate=rate, channels=channels, requested_frames=frames, pins=pins, protocol=2, profile=profile)


def header(reader):
    line = bytearray()
    while len(line) < 200:
        byte = exact(reader, 1); line.extend(byte)
        if byte == b"\n": return parse_header(line)
    raise StreamError("Capture header exceeds 200 bytes")


def unpack12(payload, count):
    if len(payload) != (count * 12 + 7) // 8:
        raise StreamError("Wrong packed sample length")
    values = []
    paired = count // 2
    for index in range(paired):
        a, b, c = payload[index * 3:index * 3 + 3]
        values.extend((a | (b & 15) << 8, b >> 4 | c << 4))
    if count & 1:
        a, b = payload[-2:]
        if b & 0xF0: raise StreamError("Nonzero padding in odd packed sample")
        values.append(a | b << 8)
    return values


def packets(reader, info, decode_samples=True):
    while True:
        marker = exact(reader, 4)
        if marker in (b"PZS2", b"PZE2"):
            a, d, s, l, elapsed, max_time, max_gap, reason = struct.unpack("<5Q3I", exact(reader, 52))
            stats = dict(attempted_frames=a, device_dropped_frames=d, slow_callbacks=s,
                         late_intervals=l, capture_elapsed_us=elapsed, max_callback_us=max_time,
                         max_interval_us=max_gap, stop_reason=reason)
            yield ("end" if marker == b"PZE2" else "stats"), stats
            if marker == b"PZE2": return
            continue
        if marker != b"PZD2": raise StreamError(f"Invalid packet marker {marker!r}")
        count, channels, bits, first = struct.unpack("<HBBQ", exact(reader, 12))
        if not 1 <= count <= 16 or channels != info["channels"] or bits != 12:
            raise StreamError("Invalid packed packet dimensions")
        sample_count = count * channels
        payload = exact(reader, (sample_count * 12 + 7) // 8)
        if sample_count & 1 and payload[-1] & 0xF0: raise StreamError("Nonzero padding nibble")
        values = unpack12(payload, sample_count) if decode_samples else None
        yield "data", dict(first=first, count=count, values=values)


class BufferedReader:
    def __init__(self, port, archive=None, before_read=None):
        self.port, self.archive, self.before_read = port, archive, before_read
        self.buffer = bytearray()
        self.consumed = 0

    def read(self, count):
        if self.before_read: self.before_read()
        while len(self.buffer) < count:
            data = self.port.read(max(4096, min(65536, self.port.in_waiting)))
            if not data: return b""
            self.buffer.extend(data)
        result = bytes(self.buffer[:count]); del self.buffer[:count]
        self.consumed += len(result)
        if self.archive: self.archive.write(result)
        return result


def run(port_name, pins, rate, profile, seconds, prefix=None, finite=False, progress=True):
    import serial
    if not 250 <= rate <= 96000 or not 1 <= len(pins) <= 13 or len(set(pins)) != len(pins) or any(not 14 <= p <= 26 for p in pins):
        raise StreamError("Invalid rate or input pins")
    if profile not in ("settled", "fast") or not math.isfinite(seconds) or seconds < 0 or (finite and seconds <= 0):
        raise StreamError("Invalid profile/duration")
    frames = round(rate * seconds) if finite else 0
    if not 0 <= frames < 2**64 or (finite and not frames):
        raise StreamError("Duration exceeds the frame counter range or rounds to zero frames")
    archive = None
    report = dict(rate=rate, pins=pins, profile=profile, requested_frames=frames,
                  received_frames=0, sequence_gaps=0, complete=False, timing_checks_passed=False)
    if prefix:
        prefix = Path(prefix)
        for suffix in (".pzlc", ".json"):
            if Path(str(prefix) + suffix).exists(): raise StreamError(f"Output exists: {prefix}{suffix}")
        prefix.parent.mkdir(parents=True, exist_ok=True)
        archive = Path(str(prefix) + ".pzlc").open("xb")
    stop_requested = False
    stop_sent = False
    last_progress = 0
    old_handler = signal.getsignal(signal.SIGINT)
    def interrupt(_signum, _frame):
        nonlocal stop_requested
        stop_requested = True
    signal.signal(signal.SIGINT, interrupt)
    try:
        with serial.Serial(port_name, 115200, timeout=.2, write_timeout=2, exclusive=True) as port:
            port.write(b"\nSTOP\n"); time.sleep(.2); port.reset_input_buffer()
            port.write(f"STREAM {rate} {frames} {profile} {' '.join(map(str,pins))}\n".encode())
            started = time.monotonic()
            def checkpoint():
                nonlocal stop_sent
                if not stop_sent and (stop_requested or (not finite and seconds and time.monotonic() - started >= seconds)):
                    port.write(b"STOP\n"); stop_sent = True
            reader = BufferedReader(port, archive, checkpoint)
            try:
                info = header(reader)
                expected_info = dict(rate=rate, channels=len(pins), requested_frames=frames, pins=pins, protocol=2, profile=profile)
                if info != expected_info: raise StreamError("Device acknowledged different stream settings")
                expected = 0
                for kind, packet in packets(reader, info, decode_samples=False):
                    if kind == "data":
                        first, count = packet["first"], packet["count"]
                        if first < expected or (frames and first + count > frames): raise StreamError("Invalid frame sequence")
                        report["sequence_gaps"] += first - expected
                        expected = first + count
                        report["received_frames"] += count
                    elif kind == "stats":
                        report["last_live_stats"] = packet
                        elapsed = packet["capture_elapsed_us"] / 1e6
                        if progress and elapsed - last_progress >= 5:
                            print(f"{elapsed:.1f}s: {packet['attempted_frames']:,} frames; {packet['device_dropped_frames']} drops; {packet['slow_callbacks']} slow; {packet['late_intervals']} late", flush=True)
                            last_progress = elapsed
                    else:
                        total = packet["attempted_frames"]
                        if total < expected or (frames and total > frames): raise StreamError("Invalid end count")
                        report["sequence_gaps"] += total - expected
                        if report["sequence_gaps"] != packet["device_dropped_frames"]: raise StreamError("Frame gaps disagree with device drop count")
                        report.update(packet)
                        report["wire_bytes"] = reader.consumed
                        report["complete"] = (packet["stop_reason"] == 0 and total == frames) if finite else packet["stop_reason"] == 1
                        elapsed = packet["capture_elapsed_us"] / 1e6
                        actual_rate = total / elapsed if elapsed else 0
                        report["effective_frame_rate"] = actual_rate
                        report["timing_checks_passed"] = bool(report["complete"] and
                            not any(packet[k] for k in ("device_dropped_frames", "slow_callbacks", "late_intervals")) and
                            abs(actual_rate / rate - 1) < .02)
                        break
            finally:
                port.write(b"STOP\n")
    except BaseException as error:
        report["error"] = str(error) or type(error).__name__
        raise
    finally:
        signal.signal(signal.SIGINT, old_handler)
        if archive: archive.close()
        if prefix: Path(str(prefix) + ".json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("--port", required=True)
    parser.add_argument("--pins", default="15,16,17,18,19,20,21", help="Provisional seven-input set; verify the jack map")
    parser.add_argument("--rate", type=int, default=12000, help="Sample rate PER INPUT (default: 12000)")
    parser.add_argument("--profile", choices=("settled", "fast"), default="settled")
    parser.add_argument("--seconds", type=float, default=0, help="0 runs until Ctrl-C; otherwise host sends STOP after this interval")
    parser.add_argument("--finite", action="store_true", help="Use a finite device frame count (benchmarking)")
    parser.add_argument("--out", type=Path, default=None)
    args = parser.parse_args()
    try:
        pins = [int(value) for value in args.pins.split(",")]
        prefix = args.out or Path("captures") / dt.datetime.now().strftime("stream-%Y%m%d-%H%M%S")
        print(f"Streaming {len(pins)} inputs at {args.rate:,} samples/s each ({args.profile}). Ctrl-C stops cleanly.", flush=True)
        report = run(args.port, pins, args.rate, args.profile, args.seconds, prefix, args.finite)
        print(json.dumps(report, indent=2))
        return 0 if report["timing_checks_passed"] else 2
    except (StreamError, OSError, ValueError) as error:
        print(f"Error: {error}", file=sys.stderr); return 1


if __name__ == "__main__": sys.exit(main())
