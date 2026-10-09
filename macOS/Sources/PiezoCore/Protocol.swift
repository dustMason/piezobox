import Foundation

public struct CaptureHeader: Equatable {
    public let rate: Int
    public let requestedFrames: UInt64
    public let pins: [Int]
    public let version: Int
    public let profile: String?
    public var channels: Int { pins.count }
}
public struct SampleFrame: Equatable {
    public let sequence: UInt64
    public let values: [UInt16]
}
public struct CaptureStats: Equatable {
    public let attempted: UInt64
    public let dropped: UInt64
    public let slow: UInt64
    public let late: UInt64
    public let maxCallbackUS: UInt32
    public let maxIntervalUS: UInt32
    public let elapsedUS: UInt64
    public let reason: UInt32
}
public enum CaptureEvent {
    case header(CaptureHeader)
    case frames([SampleFrame])
    case statistics(CaptureStats)
    case end(CaptureStats)
}
public enum ProtocolError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? { switch self { case .invalid(let message): return message } }
}

/// Bounded incremental parser for legacy PZLC1 and packed, continuous PZLC2.
public struct CaptureDecoder {
    private var bytes: [UInt8] = []
    private var offset = 0
    public private(set) var header: CaptureHeader?
    public private(set) var nextSequence: UInt64 = 0
    public private(set) var received: UInt64 = 0
    public private(set) var ended = false
    public init() {}

    public mutating func append(_ data: Data) throws -> [CaptureEvent] {
        if ended && !data.isEmpty { throw ProtocolError.invalid("Unexpected bytes after capture completion.") }
        if offset > 0 { bytes.removeFirst(offset); offset = 0 }
        bytes.append(contentsOf: data)
        guard bytes.count <= 262_144 else { throw ProtocolError.invalid("Capture buffer exceeded its limit.") }
        var events: [CaptureEvent] = []
        if header == nil {
            guard let newline = bytes.firstIndex(of: 10) else {
                if bytes.count > 200 { throw ProtocolError.invalid("Missing capture header.") }
                return []
            }
            guard newline < 200, let line = String(bytes: bytes[..<newline], encoding: .ascii) else {
                throw ProtocolError.invalid("Invalid capture header.")
            }
            let f = line.split(whereSeparator: { $0.isWhitespace })
            guard f.count >= 5, f[0] == "PZLC1" || f[0] == "PZLC2",
                  let rate = Int(f[1]), let count = Int(f[2]), (1...13).contains(count),
                  let requested = UInt64(f[3]) else { throw ProtocolError.invalid("Unexpected firmware response: \(line)") }
            let v2 = f[0] == "PZLC2"
            let pinStart = v2 ? 5 : 4
            guard (250...(v2 ? 96_000 : 16_000)).contains(rate), f.count == pinStart + count,
                  v2 || (requested > 0 && requested <= UInt64(rate * 600)),
                  !v2 || f[4] == "fast" || f[4] == "settled" else {
                throw ProtocolError.invalid("Invalid capture settings.")
            }
            let pins = f.dropFirst(pinStart).compactMap { Int($0) }
            guard pins.count == count, Set(pins).count == count, pins.allSatisfy({ (14...26).contains($0) }) else {
                throw ProtocolError.invalid("Invalid input pins in capture header.")
            }
            let parsed = CaptureHeader(rate: rate, requestedFrames: requested, pins: pins,
                                       version: v2 ? 2 : 1, profile: v2 ? String(f[4]) : nil)
            header = parsed; offset = newline + 1; events.append(.header(parsed))
        }
        guard let header else { return events }
        let v2 = header.version == 2
        while bytes.count - offset >= 4 {
            let magic = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            let final = magic == (v2 ? "PZE2" : "PZE1")
            if final || (v2 && magic == "PZS2") {
                let length = v2 ? 56 : 36
                guard bytes.count - offset >= length else { break }
                let s: CaptureStats
                if v2 {
                    s = CaptureStats(attempted: u64(offset+4), dropped: u64(offset+12), slow: u64(offset+20), late: u64(offset+28),
                                     maxCallbackUS: u32(offset+44), maxIntervalUS: u32(offset+48), elapsedUS: u64(offset+36), reason: u32(offset+52))
                } else {
                    let f = (0..<8).map { u32(offset + 4 + $0 * 4) }
                    s = CaptureStats(attempted: UInt64(f[0]), dropped: UInt64(f[1]), slow: UInt64(f[2]), late: UInt64(f[3]),
                                     maxCallbackUS: f[4], maxIntervalUS: f[5], elapsedUS: UInt64(f[6]), reason: f[7])
                }
                guard s.reason <= 5, s.attempted >= received, s.dropped <= s.attempted else {
                    throw ProtocolError.invalid("Invalid device counters.")
                }
                offset += length
                if final {
                    guard s.attempted >= nextSequence,
                          header.requestedFrames == 0 || s.attempted <= header.requestedFrames,
                          s.dropped == s.attempted - received,
                          s.reason != 0 || (header.requestedFrames > 0 && s.attempted == header.requestedFrames) else {
                        throw ProtocolError.invalid("Capture completion counters do not match its samples.")
                    }
                    guard bytes.count == offset else { throw ProtocolError.invalid("Unexpected data after the end packet.") }
                    ended = true; events.append(.end(s)); break
                }
                events.append(.statistics(s)); continue
            }
            guard magic == (v2 ? "PZD2" : "PZD1") else { throw ProtocolError.invalid("USB sample stream lost packet alignment.") }
            let prefix = v2 ? 16 : 8
            guard bytes.count - offset >= prefix else { break }
            let count = Int(u16(offset + 4)), channels = header.channels
            guard (1...16).contains(count), Int(bytes[offset + 6]) == channels, bytes[offset + 7] == (v2 ? 12 : 1) else {
                throw ProtocolError.invalid("Invalid sample packet dimensions.")
            }
            let sampleCount = count * channels
            let length = prefix + (v2 ? (sampleCount * 12 + 7) / 8 : count * (4 + channels * 2))
            guard bytes.count - offset >= length else { break }
            if v2 && sampleCount % 2 == 1 && bytes[offset + length - 1] & 0xf0 != 0 {
                throw ProtocolError.invalid("Invalid packed sample padding.")
            }
            let first = v2 ? u64(offset+8) : 0
            guard !v2 || first <= UInt64.max - UInt64(count) else { throw ProtocolError.invalid("Frame sequence overflow.") }
            var frames: [SampleFrame] = []; frames.reserveCapacity(count)
            for index in 0..<count {
                let start = offset + 8 + index * (4 + 2 * channels)
                let sequence = v2 ? first + UInt64(index) : UInt64(u32(start))
                guard sequence >= nextSequence, sequence < UInt64.max,
                      header.requestedFrames == 0 || sequence < header.requestedFrames else {
                    throw ProtocolError.invalid("Repeated or out-of-order sample frame.")
                }
                var values = [UInt16](); values.reserveCapacity(channels)
                for channel in 0..<channels {
                    if v2 {
                        let sample = index * channels + channel
                        let pair = offset + 16 + (sample / 2) * 3
                        let value = sample % 2 == 0
                            ? UInt16(bytes[pair]) | UInt16(bytes[pair+1] & 15) << 8
                            : UInt16(bytes[pair+1] >> 4) | UInt16(bytes[pair+2]) << 4
                        values.append(value)
                    } else { values.append(u16(start + 4 + 2 * channel)) }
                }
                guard values.allSatisfy({ $0 <= 4095 }) else { throw ProtocolError.invalid("Sample exceeds the ADC range.") }
                nextSequence = sequence + 1; received += 1
                frames.append(SampleFrame(sequence: sequence, values: values))
            }
            offset += length; events.append(.frames(frames))
        }
        return events
    }
    private func u16(_ i: Int) -> UInt16 { UInt16(bytes[i]) | UInt16(bytes[i+1]) << 8 }
    private func u32(_ i: Int) -> UInt32 { UInt32(bytes[i]) | UInt32(bytes[i+1]) << 8 | UInt32(bytes[i+2]) << 16 | UInt32(bytes[i+3]) << 24 }
    private func u64(_ i: Int) -> UInt64 { UInt64(u32(i)) | UInt64(u32(i+4)) << 32 }
}
