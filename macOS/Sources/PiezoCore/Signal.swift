import Foundation

public struct DCBlocker {
    private let coefficient: Float
    private var previousX: Float?
    private var previousY: Float = 0

    public init(rate: Int, cutoff: Float = 20) {
        coefficient = exp(-2 * .pi * cutoff / Float(rate))
    }
    public mutating func reset() { previousX = nil; previousY = 0 }
    public mutating func process(_ raw: UInt16) -> Float {
        let x = Float(raw) / 4096
        guard let previousX else { self.previousX = x; return 0 }
        let y = x - previousX + coefficient * previousY
        self.previousX = x
        previousY = y
        return y
    }
}

public struct WaveBin: Equatable {
    public let low: Float
    public let high: Float
    public init(low: Float, high: Float) { self.low = low; self.high = high }
}

/// Fixed-capacity history; min/max bins preserve brief transients when zoomed out.
public struct SignalHistory {
    private var samples: [Float]
    private var next = 0
    public private(set) var count = 0

    public init(capacity: Int = 32_000) { samples = Array(repeating: 0, count: max(1, capacity)) }
    public mutating func append(_ value: Float) {
        samples[next] = value
        next = (next + 1) % samples.count
        count = min(count + 1, samples.count)
    }
    public func envelope(last requested: Int, bins: Int = 900) -> [WaveBin] {
        let length = min(count, max(0, requested))
        guard length > 0 && bins > 0 else { return [] }
        let n = min(bins, length)
        let first = (next - length + samples.count) % samples.count
        return (0..<n).map { bin in
            let start = bin * length / n
            let end = (bin + 1) * length / n
            var low: Float = .greatestFiniteMagnitude, high: Float = -.greatestFiniteMagnitude
            for index in start..<end {
                let value = samples[(first + index) % samples.count]
                low = min(low, value); high = max(high, value)
            }
            return WaveBin(low: low, high: high)
        }
    }
}
