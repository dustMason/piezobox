"""PZLC2 codec tests, independent of USB hardware."""
import io
from pathlib import Path
import struct
import tempfile
import unittest

import capture
import streaming


def packed(values):
    bits = 0; count = 0; result = bytearray()
    for value in values:
        bits |= value << count; count += 12
        while count >= 8:
            result.append(bits & 255); bits >>= 8; count -= 8
    if count: result.append(bits & 255)
    return bytes(result)


def data_packet(first, rows):
    values = [x for row in rows for x in row]
    return b"PZD2" + struct.pack("<HBBQ", len(rows), len(rows[0]), 12, first) + packed(values)


def stats_packet(marker, attempted, dropped=0, elapsed=1_000_000, reason=0):
    return marker + struct.pack("<5Q3I", attempted, dropped, 0, 0, elapsed, 20, 32, reason)


class Fragments(io.BytesIO):
    def read(self, count=-1): return super().read(min(count, 3))


class PackedStreamTests(unittest.TestCase):
    def test_known_packing_vector(self):
        self.assertEqual(streaming.unpack12(bytes([0xBC, 0xFA, 0xDE]), 2), [0xABC, 0xDEF])

    def test_all_adc_values_and_odd_tail(self):
        for values in [list(range(4096)), list(range(4095)), [0], [4095]]:
            self.assertEqual(streaming.unpack12(packed(values), len(values)), values)

    def test_fragmentation_and_64_bit_sequences(self):
        first = 2**32 - 1
        h = b"PZLC2 32000 2 0 fast 20 21\n"
        stream = Fragments(h + data_packet(first, [[1,4095],[2000,3]]) + stats_packet(b"PZE2",first+2,reason=1))
        info = streaming.header(stream)
        events = list(streaming.packets(stream,info))
        self.assertEqual(events[0][1]["first"],first)
        self.assertEqual(events[0][1]["values"],[1,4095,2000,3])
        self.assertEqual(events[-1][1]["attempted_frames"],first+2)

    def test_live_stats_are_distinct_from_completion(self):
        h=b"PZLC2 16000 1 0 settled 21\n"
        stream=io.BytesIO(h+stats_packet(b"PZS2",1)+data_packet(0,[[9]])+stats_packet(b"PZE2",1,reason=1))
        info=streaming.header(stream)
        self.assertEqual([k for k,_ in streaming.packets(stream,info)],["stats","data","end"])

    def test_odd_padding_and_dimensions_are_validated(self):
        with self.assertRaises(streaming.StreamError): streaming.unpack12(b"\x00\xf0",1)
        h=streaming.parse_header(b"PZLC2 16000 1 0 fast 21\n")
        with self.assertRaises(streaming.StreamError):
            list(streaming.packets(io.BytesIO(data_packet(0,[[1,2]])),h))

    def test_truncated_packet_fails(self):
        info=streaming.parse_header(b"PZLC2 16000 1 1 fast 21\n")
        with self.assertRaises(streaming.StreamError):
            list(streaming.packets(Fragments(data_packet(0,[[1]])[:-1]),info))

    def test_invalid_headers_are_rejected(self):
        for line in [b'PZLC2 32000 2 0 fast 21 21\n', b'PZLC2 32000 1 0 unknown 21\n',
                     b'PZLC2 32000 2 0 fast 21\n', b'PZLC2 32000 1 -1 fast 21\n',
                     b'PZLC2 100000 1 0 fast 21\n', b'PZLC2 32000 1 18446744073709551616 fast 21\n']:
            with self.subTest(line=line), self.assertRaises(streaming.StreamError):
                streaming.parse_header(line)

    def test_dropped_packed_frames_remain_explicit_in_wav(self):
        data=(b'PZLC2 12000 1 4 settled 21\n' + data_packet(0,[[2048]]) +
              data_packet(3,[[2050]]) + stats_packet(b'PZE2',4,dropped=2,elapsed=334))
        stream=Fragments(data); info=capture.read_header(stream)
        with tempfile.TemporaryDirectory() as folder:
            report=capture.convert_stream(stream,info,Path(folder)/'gaps',cutoff=0)
            self.assertTrue(report['complete'])
            self.assertFalse(report['timing_checks_passed'])
            self.assertEqual(report['inserted_silent_frames'],2)
            self.assertEqual(report['output_frames'],4)

    def test_offline_wav_decode_of_continuous_capture(self):
        data=(b"PZLC2 32000 2 0 fast 20 21\n" + data_packet(0,[[2049,2050],[2051,2052]]) +
              stats_packet(b"PZS2",2,elapsed=63)+stats_packet(b"PZE2",2,elapsed=63,reason=1))
        stream=Fragments(data); info=capture.read_header(stream)
        with tempfile.TemporaryDirectory() as folder:
            prefix=Path(folder)/'take'
            report=capture.convert_stream(stream,info,prefix,cutoff=0)
            self.assertTrue(report['complete'])
            self.assertEqual(report['received_frames'],2)
            self.assertTrue(Path(str(prefix)+'.A6-pin20.wav').exists())


if __name__ == '__main__': unittest.main()
