#!/usr/bin/env python3
"""Record Teensy LC ADC waveforms over USB serial, or decode a PZLC1/PZLC2 file.

Only the serial commands require pyserial. Optional live monitoring requires
sounddevice. Decoding and the protocol checks use the Python standard library.
"""
from __future__ import annotations

import argparse
import contextlib
import datetime as dt
import json
import math
from pathlib import Path
import struct
import sys
import time
import wave
from streaming import StreamError


class CaptureError(Exception):
    pass


def read_exact(stream, count):
    result = bytearray()
    while len(result) < count:
        part = stream.read(count - len(result))
        if not part:
            raise CaptureError(f"Truncated stream or serial timeout: needed {count}, got {len(result)} bytes")
        result.extend(part)
    return bytes(result)


def read_header(stream):
    line = bytearray()
    while len(line) < 200:
        c = read_exact(stream, 1)
        line.extend(c)
        if c == b"\n":
            break
    else:
        raise CaptureError("Header exceeds 200 bytes")
    try:
        fields = line.decode("ascii").split()
        if fields and fields[0] == "PZLC2":
            from streaming import parse_header
            return parse_header(line)
        if len(fields) < 5 or fields[0] != "PZLC1":
            raise ValueError()
        rate, channels, frames = map(int, fields[1:4])
        pins = list(map(int, fields[4:]))
        if (not 250 <= rate <= 16000 or not 1 <= channels <= 13 or
                not 1 <= frames <= rate * 600 or len(pins) != channels or
                len(set(pins)) != channels or any(not 14 <= p <= 26 for p in pins)):
            raise ValueError()
    except (UnicodeError, ValueError, StreamError):
        raise CaptureError(f"Unexpected firmware header: {bytes(line)!r}") from None
    return {"rate": rate, "channels": channels, "requested_frames": frames, "pins": pins}


def packets(stream, header):
    channels = header["channels"]
    if header.get("protocol") == 2:
        from streaming import packets as packed_packets
        for kind, packet in packed_packets(stream, header):
            if kind != "data":
                yield kind, packet
            else:
                values = packet["values"]
                yield "data", [(packet["first"] + i, *values[i*channels:(i+1)*channels]) for i in range(packet["count"])]
        return
    frame_struct = struct.Struct("<I" + "H" * channels)
    while True:
        magic = read_exact(stream, 4)
        if magic == b"PZE1":
            values = struct.unpack("<8I", read_exact(stream, 32))
            names = ("attempted_frames", "device_dropped_frames", "slow_callbacks",
                     "late_intervals", "max_callback_us", "max_interval_us",
                     "capture_elapsed_us", "stop_reason")
            yield "end", dict(zip(names, values))
            return
        if magic != b"PZD1":
            raise CaptureError(f"Invalid packet marker {magic!r}; refusing to treat corrupt bytes as audio")
        count, wire_channels, version = struct.unpack("<HBB", read_exact(stream, 4))
        if not 1 <= count <= 16 or wire_channels != channels or version != 1:
            raise CaptureError("Invalid packet dimensions/version")
        payload = read_exact(stream, count * frame_struct.size)
        frames = list(frame_struct.iter_unpack(payload))
        if any(value > 4095 for frame in frames for value in frame[1:]):
            raise CaptureError("ADC sample exceeds the declared 12-bit range")
        yield "data", frames


class TeeReader:
    def __init__(self, source, archive):
        self.source, self.archive = source, archive

    def read(self, size):
        data = self.source.read(size)
        self.archive.write(data)
        return data


class DCBlock:
    def __init__(self, channels, rate, cutoff, gain):
        self.previous_x = [None] * channels
        self.previous_y = [0.0] * channels
        self.coefficient = math.exp(-2 * math.pi * cutoff / rate) if cutoff else None
        self.gain = gain
        self.clipped = 0

    def reset(self):
        self.previous_x[:] = [None] * len(self.previous_x)
        self.previous_y[:] = [0.0] * len(self.previous_y)

    def convert(self, values):
        result = []
        for ch, raw in enumerate(values):
            x = (raw - 2048) * self.gain
            if self.coefficient is None:
                y = x
            elif self.previous_x[ch] is None:
                y = 0.0  # suppress a start-of-file DC step
            else:
                y = x - self.previous_x[ch] + self.coefficient * self.previous_y[ch]
            self.previous_x[ch], self.previous_y[ch] = x, y
            value = round(y)
            if value < -32768 or value > 32767:
                self.clipped += 1
            result.append(max(-32768, min(32767, value)))
        return result


def label(pin):
    return f"A{pin - 14}-pin{pin}"


def destination_paths(prefix, header, write_audio):
    paths = [Path(str(prefix) + ".json")]
    if write_audio:
        paths.append(Path(str(prefix) + ".wav"))
        if header["channels"] > 1:
            paths.extend(Path(str(prefix) + f".{label(p)}.wav") for p in header["pins"])
    return paths


def convert_stream(stream, header, prefix, *, gain=8.0, cutoff=20.0,
                   write_audio=True, show_levels=False, monitor=False):
    prefix = Path(prefix)
    prefix.parent.mkdir(parents=True, exist_ok=True)
    for path in destination_paths(prefix, header, write_audio):
        if path.exists():
            raise CaptureError(f"Refusing to overwrite {path}; choose a new --out prefix")
    rate, channels = header["rate"], header["channels"]
    if not math.isfinite(gain) or gain <= 0 or not math.isfinite(cutoff) or not 0 <= cutoff < rate / 2:
        raise CaptureError("Gain must be positive; DC-block cutoff must be 0 <= cutoff < sample rate / 2")
    processor = DCBlock(channels, rate, cutoff, gain)
    report = dict(header, complete=False, error=None, received_frames=0, inserted_silent_frames=0,
                  dc_block_hz=cutoff, pcm_gain=gain, host_pcm_clipped_samples=0,
                  monitor_underflows=0, timing_checks_passed=False)
    lo, hi = [4095] * channels, [0] * channels
    window_lo, window_hi = lo.copy(), hi.copy()
    rail_zero, rail_high = [0] * channels, [0] * channels
    expected = 0
    end_stats = None
    level_boundary = rate

    try:
        with contextlib.ExitStack() as stack:
            def open_wav(path, n):
                file = stack.enter_context(open(path, "xb"))
                output = wave.open(file, "wb")
                stack.callback(output.close)
                output.setparams((n, 2, rate, 0, "NONE", "not compressed"))
                return output

            combined = open_wav(str(prefix) + ".wav", channels) if write_audio else None
            individual = []
            if write_audio and channels > 1:
                individual = [open_wav(str(prefix) + f".{label(p)}.wav", 1) for p in header["pins"]]
            speaker = None
            if monitor:
                try:
                    import sounddevice
                except ImportError:
                    raise CaptureError("Live monitoring needs: python -m pip install sounddevice") from None
                try:
                    speaker = stack.enter_context(sounddevice.RawOutputStream(
                        samplerate=rate, channels=1, dtype="int16", blocksize=0))
                except Exception as exc:
                    raise CaptureError(f"Cannot start live monitor: {exc}. Omit --monitor and play the saved WAV instead.") from exc

            def emit(pcm_frames):
                if not pcm_frames:
                    return
                if combined:
                    flat = [v for row in pcm_frames for v in row]
                    combined.writeframesraw(struct.pack("<" + "h" * len(flat), *flat))
                    for ch, output in enumerate(individual):
                        values = [row[ch] for row in pcm_frames]
                        output.writeframesraw(struct.pack("<" + "h" * len(values), *values))
                if speaker:
                    values = [round(sum(row) / channels) for row in pcm_frames]
                    underrun = speaker.write(struct.pack("<" + "h" * len(values), *values))
                    report["monitor_underflows"] += bool(underrun)

            def fill_gap(count):
                if count <= 0:
                    return
                report["inserted_silent_frames"] += count
                processor.reset()
                while count:
                    n = min(count, 1024)
                    emit([[0] * channels for _ in range(n)])
                    count -= n

            for kind, payload in packets(stream, header):
                if kind == "stats":
                    report["last_live_stats"] = payload
                    continue
                if kind == "end":
                    end_stats = payload
                    total = payload["attempted_frames"]
                    if total < expected or (header["requested_frames"] and total > header["requested_frames"]):
                        raise CaptureError("End packet frame count is inconsistent with received samples")
                    if payload["stop_reason"] not in (0, 1, 2, 3, 4, 5):
                        raise CaptureError("Unknown stop reason")
                    if payload["stop_reason"] == 0 and total != header["requested_frames"]:
                        raise CaptureError("Normal completion has the wrong frame count")
                    fill_gap(total - expected)
                    expected = total
                    if report["inserted_silent_frames"] != payload["device_dropped_frames"]:
                        raise CaptureError("Sequence gaps disagree with the device's dropped-frame counter")
                    break
                pcm = []
                for frame in payload:
                    sequence, values = frame[0], frame[1:]
                    if sequence < expected or (header["requested_frames"] and sequence >= header["requested_frames"]):
                        raise CaptureError("Repeated, reversed, or out-of-range frame sequence")
                    if sequence > expected:
                        emit(pcm); pcm = []
                        fill_gap(sequence - expected)
                    expected = sequence + 1
                    report["received_frames"] += 1
                    for ch, value in enumerate(values):
                        lo[ch], hi[ch] = min(lo[ch], value), max(hi[ch], value)
                        window_lo[ch] = min(window_lo[ch], value)
                        window_hi[ch] = max(window_hi[ch], value)
                        rail_zero[ch] += value == 0
                        rail_high[ch] += value == 4095
                    pcm.append(processor.convert(values))
                    if show_levels and expected >= level_boundary:
                        spans = [f"{label(p)}:{window_hi[i] - window_lo[i]:4d}" for i, p in enumerate(header["pins"])]
                        print("  ".join(spans), flush=True)
                        window_lo, window_hi = [4095] * channels, [0] * channels
                        level_boundary = (expected // rate + 1) * rate
                emit(pcm)
            if end_stats is None:
                raise CaptureError("Missing end packet")
            report.update(end_stats)
            elapsed = end_stats["capture_elapsed_us"] / 1e6
            effective_rate = expected / elapsed if elapsed else 0
            report["effective_frame_rate"] = effective_rate
            rate_error = abs(effective_rate / rate - 1) if effective_rate else 1
            normal_end = end_stats["stop_reason"] == 0 or (header["requested_frames"] == 0 and end_stats["stop_reason"] == 1)
            report["timing_checks_passed"] = bool(
                normal_end and not end_stats["device_dropped_frames"] and
                not end_stats["slow_callbacks"] and not end_stats["late_intervals"] and
                rate_error < 0.02)
            report["complete"] = normal_end
    except BaseException as exc:
        report["error"] = str(exc) or type(exc).__name__
        raise
    finally:
        report["host_pcm_clipped_samples"] = processor.clipped
        report["output_frames"] = expected
        report["inputs"] = [dict(pin=p, analog=f"A{p-14}", minimum=lo[i] if report["received_frames"] else None,
                                 maximum=hi[i] if report["received_frames"] else None,
                                 zero_samples=rail_zero[i], full_scale_samples=rail_high[i])
                            for i, p in enumerate(header["pins"])]
        Path(str(prefix) + ".json").write_text(json.dumps(report, indent=2) + "\n")
    return report


def print_report(report, prefix, write_audio):
    print(f"Saved {'WAV audio and ' if write_audio else ''}report: {prefix}")
    print(f"Received {report['received_frames']} frames; inserted {report['inserted_silent_frames']} missing frames as silence.")
    print(f"Callback max {report.get('max_callback_us', 0)} us; slow {report.get('slow_callbacks', 0)}; late {report.get('late_intervals', 0)}.")
    print(f"Effective rate: {report.get('effective_frame_rate', 0):.2f} frames/s.")
    if report["timing_checks_passed"]:
        print("Timing checks passed. This does not validate analog fidelity or input protection.")
    else:
        print("TIMING/COMPLETION CHECK FAILED: treat this recording as diagnostic. Reduce --rate and/or channel count.")
    if report.get("stop_reason") == 3:
        print("The LC stopped early because eight consecutive sampling callbacks exceeded their time budget.")
    if report["host_pcm_clipped_samples"]:
        print("Host PCM clipping occurred: reduce --gain. The raw .pzlc archive retains the ADC values.")


def pin_list(value):
    try:
        pins = [int(v) for v in value.split(",")]
    except ValueError:
        raise argparse.ArgumentTypeError("Use comma-separated Teensy pin numbers, e.g. 21 or 20,21") from None
    if not 1 <= len(pins) <= 13 or len(set(pins)) != len(pins) or any(not 14 <= p <= 26 for p in pins):
        raise argparse.ArgumentTypeError("Use distinct LC analog pin numbers 14..26")
    return pins


def serial_module():
    try:
        import serial
    except ImportError:
        raise CaptureError("USB recording needs: python -m pip install pyserial") from None
    return serial


def main(argv=None):
    parser = argparse.ArgumentParser(description=__doc__)
    sub = parser.add_subparsers(dest="action", required=True)
    sub.add_parser("ports", help="List serial devices without opening them")
    record = sub.add_parser("record", help="Capture waveform samples; default is only the known A7 input")
    record.add_argument("--port", required=True, help="Explicit serial device, e.g. /dev/cu.usbmodem1234561")
    record.add_argument("--pins", type=pin_list, default=[21])
    record.add_argument("--rate", type=int, default=16000, help="Frames per second PER CHANNEL; lower this when using more pins")
    record.add_argument("--seconds", type=float, default=5)
    record.add_argument("--map", action="store_true", help="Print per-second ADC spans; save raw data/report but no WAVs")
    decode = sub.add_parser("decode", help="Convert an existing raw .pzlc capture, without touching hardware")
    decode.add_argument("input", type=Path)
    for p in (record, decode):
        p.add_argument("--out", type=Path, default=None, help="New output filename prefix; existing files are never overwritten")
        p.add_argument("--gain", type=float, default=8, help="PCM units per ADC count (default 8)")
        p.add_argument("--dc-block", type=float, default=20, help="DC-block cutoff in Hz; 0 disables it")
        p.add_argument("--monitor", action="store_true", help="Also listen live to a mono mix (requires sounddevice)")
    args = parser.parse_args(argv)
    try:
        if args.action == "ports":
            serial_module()
            from serial.tools import list_ports
            for port in list_ports.comports():
                print(f"{port.device}\t{port.description}\t{port.hwid}")
            return 0
        prefix = args.out or Path("captures") / dt.datetime.now().strftime("piezo-%Y%m%d-%H%M%S")
        if args.action == "decode":
            with args.input.open("rb") as source:
                header = read_header(source)
                report = convert_stream(source, header, prefix, gain=args.gain, cutoff=args.dc_block, monitor=args.monitor)
            print_report(report, prefix, True)
            return 0 if report["timing_checks_passed"] else 2

        if (not 250 <= args.rate <= 16000 or not math.isfinite(args.seconds) or
                not 0.25 <= args.seconds <= 600):
            raise CaptureError("Use rate 250..16000 and duration 0.25..600 seconds")
        if not math.isfinite(args.gain) or args.gain <= 0 or not math.isfinite(args.dc_block) or not 0 <= args.dc_block < args.rate / 2:
            raise CaptureError("Invalid gain or DC-block cutoff")
        frames = round(args.rate * args.seconds)
        expected_header = dict(rate=args.rate, channels=len(args.pins), requested_frames=frames, pins=args.pins)
        archive_path = Path(str(prefix) + ".pzlc")
        for path in [archive_path, *destination_paths(prefix, expected_header, not args.map)]:
            if path.exists():
                raise CaptureError(f"Refusing to overwrite {path}; choose another --out")
        prefix.parent.mkdir(parents=True, exist_ok=True)
        serial = serial_module()
        print(f"Opening {args.port}; pins {args.pins}; {args.rate} frames/s per channel. No firmware is uploaded.")
        with serial.Serial(args.port, 115200, timeout=2, write_timeout=2, exclusive=True) as port:
            # End a prior capture before starting a new one. No board reset.
            port.write(b"\nSTOP\n")
            drain_until = time.monotonic() + 0.5
            while time.monotonic() < drain_until:
                if port.in_waiting:
                    port.read(port.in_waiting)
                time.sleep(0.01)
            port.reset_input_buffer()
            command = f"CAP {args.rate} {frames} " + " ".join(map(str, args.pins)) + "\n"
            port.write(command.encode("ascii"))
            try:
                with archive_path.open("xb") as archive:
                    source = TeeReader(port, archive)
                    header = read_header(source)
                    if header != expected_header:
                        raise CaptureError("Firmware acknowledged settings different from the requested capture")
                    report = convert_stream(source, header, prefix, gain=args.gain, cutoff=args.dc_block,
                                            write_audio=not args.map, show_levels=args.map, monitor=args.monitor)
            finally:
                port.write(b"STOP\n")
        print_report(report, prefix, not args.map)
        print(f"Raw ADC archive: {archive_path}")
        return 0 if report["timing_checks_passed"] else 2
    except KeyboardInterrupt:
        print("\nStopped. Existing partial files are retained; use a new --out for another take.", file=sys.stderr)
        return 130
    except (CaptureError, StreamError, OSError) as exc:
        print(f"Error: {exc}", file=sys.stderr)
        return 1


if __name__ == "__main__":
    sys.exit(main())
