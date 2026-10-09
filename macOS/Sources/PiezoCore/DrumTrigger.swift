import Foundation

public struct DrumConfiguration: Codable, Equatable, Identifiable {
    public var id: Int
    public var name: String
    public var note: Int
    public var threshold: Double = 120 // ADC counts, after DC removal
    public var velocityCeiling: Double = 1024
    public var retriggerMS: Double = 50
    public var enabled = true
    public init(id: Int, name: String, note: Int) { self.id = id; self.name = name; self.note = note }
    public static let defaults: [Self] = zip(["Kick", "Snare", "Closed hat", "Open hat", "Low tom", "High tom", "Crash"], [36,38,42,46,45,48,49])
        .enumerated().map { Self(id: $0.offset, name: $0.element.0, note: $0.element.1) }
    public mutating func sanitize() {
        note = min(127, max(0, note))
        threshold = threshold.isFinite ? min(4095, max(1, threshold)) : 120
        velocityCeiling = velocityCeiling.isFinite ? min(4096, max(threshold + 1, velocityCeiling)) : 1024
        retriggerMS = retriggerMS.isFinite ? min(500, max(5, retriggerMS)) : 50
    }
}
public struct DrumHit: Equatable {
    public let input: Int
    public let note: Int
    public let velocity: Int
    public let peakCounts: Float
    public let sequence: UInt64
    public init(input: Int, note: Int, velocity: Int, peakCounts: Float, sequence: UInt64) {
        self.input = input; self.note = note; self.velocity = velocity; self.peakCounts = peakCounts; self.sequence = sequence
    }
}

/// Threshold + short peak search + hysteresis and holdoff suppress piezo ringing.
/// Runs on sample indices, independent of USB packet boundaries and UI refresh.
public struct DrumTrigger {
    private var started: UInt64?
    private var peak: Float = 0
    private var armed = true
    private var blockedUntil: UInt64 = 0
    private var quietFrames = 0
    private let rate: Int
    public init(rate: Int = 32_000) { self.rate = rate }
    public mutating func reset() { started = nil; peak = 0; armed = true; blockedUntil = 0; quietFrames = 0 }
    public mutating func process(_ value: Float, sequence: UInt64, config: DrumConfiguration,
                                 dynamicVelocity: Bool = true, fixedVelocity: Int = 100) -> DrumHit? {
        guard config.enabled else { reset(); return nil }
        let magnitude = abs(value) * 4096
        let threshold = Float(max(1, config.threshold))
        if let began = started {
            peak = max(peak, magnitude)
            guard sequence - began >= UInt64(max(1, rate * 3 / 1000)) else { return nil }
            started = nil; armed = false; quietFrames = 0
            blockedUntil = began + UInt64(max(1, Double(rate) * config.retriggerMS / 1000))
            let fraction = max(0, min(1, (peak - threshold) / max(1, Float(config.velocityCeiling) - threshold)))
            let velocity = dynamicVelocity ? max(1, min(127, Int((1 + fraction * 126).rounded()))) : max(1, min(127, fixedVelocity))
            return DrumHit(input: config.id, note: config.note, velocity: velocity, peakCounts: peak, sequence: began)
        }
        if !armed {
            quietFrames = magnitude < threshold * 0.5 ? quietFrames + 1 : 0
            if quietFrames >= max(1, rate * 2 / 1000), sequence >= blockedUntil { armed = true }
        }
        if armed && magnitude >= threshold { started = sequence; peak = magnitude }
        return nil
    }
}
