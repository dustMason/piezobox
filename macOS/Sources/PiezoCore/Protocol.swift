import Foundation

public struct CaptureHeader: Equatable {
    public let rate: Int
    public let requestedFrames: UInt32
    public let pins: [Int]
    public var channels: Int { pins.count }
}

public struct SampleFrame: Equatable {
    public let sequence: UInt32
    public let values: [UInt16]
}

public struct CaptureStats: Equatable {
    public let attempted: UInt32
    public let dropped: UInt32
    public let slow: UInt32
    public let late: UInt32
    public let maxCallbackUS: UInt32
    public let maxIntervalUS: UInt32
    public let elapsedUS: UInt32
    public let reason: UInt32
}

public enum CaptureEvent {
    case header(CaptureHeader)
    case frames([SampleFrame])
    case end(CaptureStats)
}

public enum ProtocolError: Error, LocalizedError {
    case invalid(String)
    public var errorDescription: String? {
        switch self { case .invalid(let message): return message }
    }
}

/// Incremental, bounded PZLC1 parser. It never interprets malformed packets as audio.
public struct CaptureDecoder {
    private var bytes: [UInt8] = []
    private var offset = 0
    public private(set) var header: CaptureHeader?
    public private(set) var nextSequence: UInt32 = 0
    public private(set) var received: UInt32 = 0
    public private(set) var ended = false

    public init() {}

    public mutating func append(_ data: Data) throws -> [CaptureEvent] {
        if ended && !data.isEmpty { throw ProtocolError.invalid("Unexpected bytes after capture completion.") }
        if offset > 0 {
            bytes.removeFirst(offset)
            offset = 0
        }
        bytes.append(contentsOf: data)
        if bytes.count > 262_144 { throw ProtocolError.invalid("Capture buffer exceeded its limit.") }
        var events: [CaptureEvent] = []
        if header == nil {
            guard let newline = bytes.firstIndex(of: 10) else {
                if bytes.count > 200 { throw ProtocolError.invalid("The Teensy did not send a valid capture header.") }
                return []
            }
            guard newline < 200, let line = String(bytes: bytes[..<newline], encoding: .ascii) else {
                throw ProtocolError.invalid("Invalid capture header.")
            }
            let fields = line.split(whereSeparator: { $0.isWhitespace })
            guard fields.count >= 5, fields[0] == "PZLC1",
                  let rate = Int(fields[1]), (250...16_000).contains(rate),
                  let count = Int(fields[2]), (1...13).contains(count),
                  let frames = UInt32(fields[3]), frames > 0, frames <= UInt32(rate * 600),
                  fields.count == 4 + count else {
                throw ProtocolError.invalid("Unexpected firmware response: \(line)")
            }
            let pins = fields.dropFirst(4).compactMap { Int($0) }
            guard pins.count == count, Set(pins).count == count,
                  pins.allSatisfy({ (14...26).contains($0) }) else {
                throw ProtocolError.invalid("Invalid input pins in capture header.")
            }
            let parsed = CaptureHeader(rate: rate, requestedFrames: frames, pins: pins)
            header = parsed
            offset = newline + 1
            events.append(.header(parsed))
        }
        guard let header else { return events }
        while bytes.count - offset >= 4 {
            let magic = String(bytes: bytes[offset..<(offset + 4)], encoding: .ascii)
            if magic == "PZE1" {
                guard bytes.count - offset >= 36 else { break }
                let fields = (0..<8).map { u32(offset + 4 + $0 * 4) }
                let stats = CaptureStats(attempted: fields[0], dropped: fields[1], slow: fields[2],
                                         late: fields[3], maxCallbackUS: fields[4], maxIntervalUS: fields[5],
                                         elapsedUS: fields[6], reason: fields[7])
                guard stats.attempted >= nextSequence, stats.attempted <= header.requestedFrames,
                      stats.reason <= 3, stats.dropped == stats.attempted - received,
                      stats.reason != 0 || stats.attempted == header.requestedFrames else {
                    throw ProtocolError.invalid("Capture completion counters do not match its samples.")
                }
                offset += 36
                guard bytes.count == offset else { throw ProtocolError.invalid("Unexpected data after the end packet.") }
                ended = true
                events.append(.end(stats))
                break
            }
            guard magic == "PZD1" else { throw ProtocolError.invalid("The USB sample stream lost packet alignment.") }
            guard bytes.count - offset >= 8 else { break }
            let count = Int(u16(offset + 4))
            guard (1...16).contains(count), Int(bytes[offset + 6]) == header.channels, bytes[offset + 7] == 1 else {
                throw ProtocolError.invalid("Invalid sample packet dimensions.")
            }
            let stride = 4 + 2 * header.channels
            let length = 8 + count * stride
            guard bytes.count - offset >= length else { break }
            var frames: [SampleFrame] = []
            frames.reserveCapacity(count)
            for index in 0..<count {
                let start = offset + 8 + index * stride
                let sequence = u32(start)
                guard sequence >= nextSequence, sequence < header.requestedFrames else {
                    throw ProtocolError.invalid("Repeated or out-of-order sample frame.")
                }
                let values = (0..<header.channels).map { u16(start + 4 + 2 * $0) }
                guard values.allSatisfy({ $0 <= 4095 }) else { throw ProtocolError.invalid("A sample exceeds the 12-bit ADC range.") }
                nextSequence = sequence + 1
                received += 1
                frames.append(SampleFrame(sequence: sequence, values: values))
            }
            offset += length
            events.append(.frames(frames))
        }
        return events
    }

    private func u16(_ index: Int) -> UInt16 {
        UInt16(bytes[index]) | UInt16(bytes[index + 1]) << 8
    }
    private func u32(_ index: Int) -> UInt32 {
        UInt32(bytes[index]) | UInt32(bytes[index + 1]) << 8 |
        UInt32(bytes[index + 2]) << 16 | UInt32(bytes[index + 3]) << 24
    }
}
