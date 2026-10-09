import XCTest
@testable import PiezoCore

private func le(_ n: UInt64, _ count: Int) -> [UInt8] { (0..<count).map { UInt8(truncatingIfNeeded: n >> ($0 * 8)) } }
private func packed(_ values: [UInt16]) -> [UInt8] {
    var result: [UInt8] = []; var bits: UInt32 = 0; var n = 0
    for v in values { bits |= UInt32(v) << n; n += 12; while n >= 8 { result.append(UInt8(truncatingIfNeeded: bits)); bits >>= 8; n -= 8 } }
    if n > 0 { result.append(UInt8(bits)) }; return result
}
private func v2data(_ first: UInt64, _ rows: [[UInt16]]) -> Data {
    Data(Array("PZD2".utf8) + le(UInt64(rows.count),2) + [UInt8(rows[0].count),12] + le(first,8) + packed(rows.flatMap { $0 }))
}
private func stats(_ marker: String, attempted: UInt64, dropped: UInt64 = 0, reason: UInt64 = 0) -> Data {
    var result = Array(marker.utf8)
    for n in [attempted,dropped,0,0,1_000_000] { result += le(n,8) }
    for n in [10,33,reason] { result += le(n,4) }
    return Data(result)
}
final class StreamingAndDrumsTests: XCTestCase {
    func testSevenChannelPackedStreamByteByByteWithLiveStats() throws {
        var input = Data("PZLC2 32000 7 0 fast 15 16 17 18 19 20 21\n".utf8)
        let row: [UInt16] = [0,1,4095,2048,0xabc,0xdef,777]
        input.append(v2data(0,[row])); input.append(stats("PZS2",attempted:1))
        input.append(v2data(1,[row.reversed()])); input.append(stats("PZE2",attempted:2,reason:1))
        var decoder = CaptureDecoder(); var frames: [SampleFrame] = []; var live = 0
        for byte in input {
            for e in try decoder.append(Data([byte])) {
                if case .frames(let v) = e { frames += v }; if case .statistics = e { live += 1 }
            }
        }
        XCTAssertTrue(decoder.ended); XCTAssertEqual(live,1)
        XCTAssertEqual(frames.map(\.values),[row,Array(row.reversed())]); XCTAssertEqual(decoder.received,2)
    }
    func testSequenceAndStatsRemain64Bit() throws {
        var decoder = CaptureDecoder(); let first: UInt64 = 1 << 32
        _ = try decoder.append(Data("PZLC2 32000 1 0 fast 21\n".utf8))
        _ = try decoder.append(v2data(first,[[4095]]))
        XCTAssertEqual(decoder.nextSequence,first+1)
        XCTAssertNoThrow(try decoder.append(stats("PZE2",attempted:first+1,dropped:first,reason:1)))
    }
    func testBadPaddingAndCounterMismatchFail() throws {
        var d = CaptureDecoder(); _ = try d.append(Data("PZLC2 32000 1 0 fast 21\n".utf8))
        var bad = v2data(0,[[1]]); bad[bad.count-1] = 0xf0
        XCTAssertThrowsError(try d.append(bad))
        d = CaptureDecoder(); _ = try d.append(Data("PZLC2 32000 1 0 fast 21\n".utf8))
        _ = try d.append(v2data(1,[[1]]))
        XCTAssertThrowsError(try d.append(stats("PZE2",attempted:2,reason:1)))
    }
    func testTruncatedPackedDataDoesNotEmitSamples() throws {
        var d = CaptureDecoder(); _ = try d.append(Data("PZLC2 32000 7 0 fast 15 16 17 18 19 20 21\n".utf8))
        XCTAssertTrue(try d.append(v2data(0,[[1,2,3,4,5,6,7]]).dropLast()).isEmpty)
        XCTAssertEqual(d.received,0)
    }
    func testVelocityPeakAndRetriggerHoldoff() {
        var trigger = DrumTrigger(rate: 1000); var config = DrumConfiguration(id: 2,name:"Pad",note:42)
        config.threshold = 100; config.velocityCeiling = 500; config.retriggerMS = 50
        var hits: [DrumHit] = []
        for index in 0..<140 {
            let counts: Float = (10...13).contains(index) ? 300 : ((40...43).contains(index) || (80...83).contains(index) ? 500 : 0)
            if let hit = trigger.process(counts/4096,sequence:UInt64(index),config:config) { hits.append(hit) }
        }
        XCTAssertEqual(hits.map(\.sequence),[10,80]); XCTAssertEqual(hits.map(\.velocity),[64,127]); XCTAssertEqual(hits.map(\.note),[42,42])
    }
    func testSustainedSignalDoesNotMachineGunAndFixedVelocityWorks() {
        var trigger = DrumTrigger(rate:1000); let config = DrumConfiguration(id:0,name:"Kick",note:36)
        var hits: [DrumHit] = []
        for index in 0..<300 {
            let sample: Float = (0..<120).contains(index) || index >= 160 ? 0.5 : 0
            if let hit = trigger.process(sample,sequence:UInt64(index),config:config,dynamicVelocity:false,fixedVelocity:88) { hits.append(hit) }
        }
        XCTAssertEqual(hits.count,2); XCTAssertEqual(hits.map(\.velocity),[88,88])
    }
    func testDisabledPadAndResetNeverFinishAnOldHit() {
        var trigger = DrumTrigger(rate:1000); var config = DrumConfiguration(id:0,name:"Kick",note:36)
        XCTAssertNil(trigger.process(0.5,sequence:0,config:config)); trigger.reset()
        config.enabled = false
        for index in 1..<100 { XCTAssertNil(trigger.process(0.5,sequence:UInt64(index),config:config)) }
    }
}
