import XCTest
@testable import PiezoCore

private func u16(_ value: UInt16) -> [UInt8] { [UInt8(truncatingIfNeeded: value), UInt8(truncatingIfNeeded: value >> 8)] }
private func u32(_ value: UInt32) -> [UInt8] { (0..<4).map { UInt8(truncatingIfNeeded: value >> ($0 * 8)) } }
private func packet(_ rows: [(UInt32, [UInt16])], channels: Int) -> Data {
    var bytes = Array("PZD1".utf8) + u16(UInt16(rows.count)) + [UInt8(channels), 1]
    for (sequence, values) in rows { bytes += u32(sequence); for value in values { bytes += u16(value) } }
    return Data(bytes)
}
private func end(attempted: UInt32, dropped: UInt32 = 0, reason: UInt32 = 0) -> Data {
    var bytes = Array("PZE1".utf8)
    let values: [UInt32] = [attempted, dropped, 0, 0, 16, 69, 1_000_000, reason]
    for value in values { bytes += u32(value) }
    return Data(bytes)
}

final class PiezoCoreTests: XCTestCase {
    func testByteByByteStreamingPreservesSamplesAndChannelOrder() throws {
        var data = Data("PZLC1 16000 2 2 20 21\n".utf8)
        data.append(packet([(0, [12, 3900]), (1, [2048, 19])], channels: 2))
        data.append(end(attempted: 2))
        var decoder = CaptureDecoder()
        var received: [SampleFrame] = []
        for byte in data {
            for event in try decoder.append(Data([byte])) {
                if case .frames(let frames) = event { received += frames }
            }
        }
        XCTAssertEqual(received.map(\.values), [[12, 3900], [2048, 19]])
        XCTAssertEqual(decoder.header?.pins, [20, 21])
        XCTAssertTrue(decoder.ended)
    }

    func testFrameGapsMustAgreeWithDeviceCounters() throws {
        var decoder = CaptureDecoder()
        _ = try decoder.append(Data("PZLC1 1000 1 4 21\n".utf8))
        _ = try decoder.append(packet([(0, [1]), (2, [2])], channels: 1))
        XCTAssertNoThrow(try decoder.append(end(attempted: 4, dropped: 2)))
        XCTAssertEqual(decoder.received, 2)
    }

    func testCounterMismatchIsRejected() throws {
        var decoder = CaptureDecoder()
        _ = try decoder.append(Data("PZLC1 1000 1 3 21\n".utf8))
        _ = try decoder.append(packet([(2, [1])], channels: 1))
        XCTAssertThrowsError(try decoder.append(end(attempted: 3)))
    }

    func testWrongOrderAndInvalidADCAreRejected() throws {
        let cases: [[(UInt32, [UInt16])]] = [[(1, [1]), (0, [1])], [(0, [4096])]]
        for rows in cases {
            var decoder = CaptureDecoder()
            _ = try decoder.append(Data("PZLC1 1000 1 3 21\n".utf8))
            XCTAssertThrowsError(try decoder.append(packet(rows, channels: 1)))
        }
    }

    func testInvalidHeaderAndPacketDimensionsAreRejected() throws {
        var decoder = CaptureDecoder()
        XCTAssertThrowsError(try decoder.append(Data("PZLC1 1000 2 4 21 21\n".utf8)))
        decoder = CaptureDecoder()
        _ = try decoder.append(Data("PZLC1 1000 1 4 21\n".utf8))
        XCTAssertThrowsError(try decoder.append(packet([(0, [1, 2])], channels: 2)))
    }

    func testTruncatedPacketsDoNotProduceInventedFrames() throws {
        var decoder = CaptureDecoder()
        _ = try decoder.append(Data("PZLC1 1000 1 1 21\n".utf8))
        let bytes = packet([(0, [100])], channels: 1)
        XCTAssertTrue(try decoder.append(bytes.dropLast()).isEmpty)
        XCTAssertEqual(decoder.received, 0)
        XCTAssertEqual(try decoder.append(Data([bytes.last!])).count, 1)
    }

    func testDCBlockerStartsWithoutClickAndRejectsConstantInput() {
        var dc = DCBlocker(rate: 16000)
        for _ in 0..<1000 { XCTAssertEqual(dc.process(2300), 0) }
        XCTAssertGreaterThan(dc.process(3300), 0.2)
        dc.reset()
        XCTAssertEqual(dc.process(0), 0)
    }

    func testWaveformEnvelopePreservesSpikeAndRingOrder() {
        var history = SignalHistory(capacity: 8)
        let values: [Float] = [99, 99, 0, 0, 0, 1, -1, 0, 0, 0]
        for value in values { history.append(value) }
        XCTAssertEqual(history.count, 8)
        let bins = history.envelope(last: 8, bins: 2)
        XCTAssertEqual(bins, [WaveBin(low: 0, high: 1), WaveBin(low: -1, high: 0)])
    }

    func testEmptyAndShortHistoriesAreBounded() {
        var history = SignalHistory(capacity: 100)
        XCTAssertTrue(history.envelope(last: 100).isEmpty)
        history.append(0.5)
        XCTAssertEqual(history.envelope(last: 1000, bins: 900), [WaveBin(low: 0.5, high: 0.5)])
    }
}
