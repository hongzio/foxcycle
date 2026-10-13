/// Latency samples for percentile reports, cheap enough to record on the event-tap thread.
///
/// Storage is allocated once and recording never allocates. Past `capacity`, percentiles cover the
/// most recent `capacity` samples, while `count` and `max` still cover every sample.
public struct LatencySamples: Sendable {
    public struct Summary: Sendable, Equatable {
        public let count: Int
        public let p50: UInt64
        public let p95: UInt64
        public let max: UInt64

        public init(count: Int, p50: UInt64, p95: UInt64, max: UInt64) {
            self.count = count
            self.p50 = p50
            self.p95 = p95
            self.max = max
        }
    }

    private var storage: [UInt64]
    private var next = 0
    private var maximum: UInt64 = 0
    public private(set) var count = 0

    public init(capacity: Int) {
        precondition(capacity > 0, "capacity must be positive")
        storage = Array(repeating: 0, count: capacity)
    }

    public var capacity: Int { storage.count }

    public mutating func record(_ nanos: UInt64) {
        storage[next] = nanos
        next = next + 1 == storage.count ? 0 : next + 1
        count += 1
        maximum = Swift.max(maximum, nanos)
    }

    /// Nearest-rank percentiles. Sorts a copy of the samples: call it off latency-sensitive threads.
    public func summary() -> Summary? {
        guard count > 0 else { return nil }
        let sorted = storage.prefix(Swift.min(count, storage.count)).sorted()
        func percentile(_ percent: Int) -> UInt64 {
            let rank = (percent * sorted.count + 99) / 100
            return sorted[Swift.max(rank, 1) - 1]
        }
        return Summary(count: count, p50: percentile(50), p95: percentile(95), max: maximum)
    }
}
