"""Host/protocol tests with synthetic ADC data; these do not test a Teensy."""
import io
import json
from pathlib import Path
import struct
import tempfile
import unittest
import wave

import capture


class Fragmented(io.BytesIO):
    def read(self, size=-1):
        return super().read(min(size, 3) if size >= 0 else 3)


def fixture(pins, rows, *, requested=None, attempted=None, dropped=0,
            reason=0, slow=0, late=0, rate=1000):
    attempted = attempted if attempted is not None else (rows[-1][0] + 1 if rows else 0)
    requested = requested if requested is not None else attempted
    data = f"PZLC1 {rate} {len(pins)} {requested} {' '.join(map(str, pins))}\n".encode()
    for offset in range(0, len(rows), 16):
        batch = rows[offset:offset + 16]
        data += b"PZD1" + struct.pack("<HBB", len(batch), len(pins), 1)
        for row in batch:
            data += struct.pack("<I" + "H" * len(pins), *row)
    data += b"PZE1" + struct.pack("<8I", attempted, dropped, slow, late, 2, 1000000 // rate,
                                   round(attempted / rate * 1000000), reason)
    return data


def pcm(path):
    with wave.open(str(path), "rb") as f:
        channels, rate, frames = f.getnchannels(), f.getframerate(), f.getnframes()
        raw = f.readframes(frames)
    return channels, rate, frames, struct.unpack("<" + "h" * (len(raw) // 2), raw)


class RecorderTests(unittest.TestCase):
    def setUp(self):
        self.temp = tempfile.TemporaryDirectory()
        self.prefix = Path(self.temp.name) / "take"

    def tearDown(self):
        self.temp.cleanup()

    def decode(self, data, **kwargs):
        stream = Fragmented(data)
        header = capture.read_header(stream)
        return capture.convert_stream(stream, header, self.prefix, cutoff=kwargs.pop("cutoff", 0), **kwargs)

    def test_fragmented_packets_preserve_channel_order_and_pcm(self):
        rows = [(i, 2048 + i, 2100 - i) for i in range(40)]
        report = self.decode(fixture([20, 21], rows))
        self.assertTrue(report["timing_checks_passed"])
        stereo = pcm(str(self.prefix) + ".wav")
        self.assertEqual(stereo[:3], (2, 1000, 40))
        self.assertEqual(stereo[3][::2], tuple(i * 8 for i in range(40)))
        self.assertEqual(stereo[3][1::2], tuple((52 - i) * 8 for i in range(40)))
        self.assertEqual(pcm(str(self.prefix) + ".A6-pin20.wav")[3], stereo[3][::2])
        self.assertEqual(pcm(str(self.prefix) + ".A7-pin21.wav")[3], stereo[3][1::2])

    def test_dropped_frames_become_silence_including_tail(self):
        report = self.decode(fixture([21], [(0, 2049), (2, 2050)], requested=4, attempted=4, dropped=2))
        self.assertEqual(pcm(str(self.prefix) + ".wav")[3], (8, 0, 16, 0))
        self.assertEqual(report["inserted_silent_frames"], 2)
        self.assertFalse(report["timing_checks_passed"])

    def test_zero_dc_input_does_not_make_startup_click(self):
        self.decode(fixture([21], [(i, 0) for i in range(50)]), cutoff=20)
        self.assertEqual(pcm(str(self.prefix) + ".wav")[3], (0,) * 50)

    def test_dc_block_channels_have_independent_state(self):
        self.decode(fixture([20, 21], [(i, 1000 + (100 if i == 10 else 0), 3000) for i in range(30)]), cutoff=20)
        data = pcm(str(self.prefix) + ".wav")[3]
        self.assertGreater(data[20], 0)
        self.assertEqual(data[1::2], (0,) * 30)

    def test_overload_stop_is_reported_as_incomplete(self):
        report = self.decode(fixture([21], [(i, 2048) for i in range(8)], requested=100, reason=3, slow=8))
        self.assertFalse(report["complete"])
        self.assertFalse(report["timing_checks_passed"])
        self.assertEqual(report["stop_reason"], 3)

    def test_truncated_stream_keeps_valid_partial_wav_and_error_report(self):
        data = fixture([21], [(0, 2049), (1, 2050)])[:-10]
        with self.assertRaises(capture.CaptureError):
            self.decode(data)
        self.assertEqual(pcm(str(self.prefix) + ".wav")[3], (8, 16))
        report = json.loads(Path(str(self.prefix) + ".json").read_text())
        self.assertFalse(report["complete"])
        self.assertIsNotNone(report["error"])

    def test_repeated_sequence_is_rejected(self):
        with self.assertRaisesRegex(capture.CaptureError, "Repeated"):
            self.decode(fixture([21], [(0, 2048), (0, 2048)], requested=2, attempted=2))

    def test_out_of_range_adc_is_rejected(self):
        with self.assertRaisesRegex(capture.CaptureError, "12-bit"):
            self.decode(fixture([21], [(0, 4096)]))

    def test_missing_frames_must_match_device_counter(self):
        with self.assertRaisesRegex(capture.CaptureError, "disagree"):
            self.decode(fixture([21], [(0, 2048), (2, 2048)], dropped=0))

    def test_duplicate_header_pins_are_rejected(self):
        with self.assertRaises(capture.CaptureError):
            capture.read_header(io.BytesIO(b"PZLC1 1000 2 100 21 21\n"))

    def test_existing_file_is_not_overwritten(self):
        existing = Path(str(self.prefix) + ".wav")
        existing.write_bytes(b"preserve me")
        with self.assertRaisesRegex(capture.CaptureError, "overwrite"):
            self.decode(fixture([21], [(0, 2048)]))
        self.assertEqual(existing.read_bytes(), b"preserve me")

    def test_map_mode_has_levels_report_and_no_wav(self):
        report = self.decode(fixture([14, 21], [(0, 20, 40), (1, 80, 200)]), write_audio=False)
        self.assertFalse(Path(str(self.prefix) + ".wav").exists())
        self.assertEqual([(x["minimum"], x["maximum"]) for x in report["inputs"]], [(20, 80), (40, 200)])


if __name__ == "__main__":
    unittest.main()
