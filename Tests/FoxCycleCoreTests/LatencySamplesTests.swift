import FoxCycleCore
import Testing

struct LatencySamplesTests {
    @Test func emptyHasNoSummary() {
        #expect(LatencySamples(capacity: 4).summary() == nil)
    }

    @Test func singleSample() {
        var samples = LatencySamples(capacity: 4)
        samples.record(7)
        #expect(samples.summary() == .init(count: 1, p50: 7, p95: 7, max: 7))
    }

    @Test func nearestRankPercentilesIgnoreRecordingOrder() {
        var samples = LatencySamples(capacity: 128)
        for value in (1...100).shuffled() { samples.record(UInt64(value)) }
        #expect(samples.summary() == .init(count: 100, p50: 50, p95: 95, max: 100))
    }

    @Test func smallSampleRanksRoundUp() {
        var samples = LatencySamples(capacity: 32)
        for value in 1...20 { samples.record(UInt64(value)) }
        // ceil(0.5 * 20) = 10th, ceil(0.95 * 20) = 19th
        #expect(samples.summary() == .init(count: 20, p50: 10, p95: 19, max: 20))
    }

    @Test func overflowKeepsMostRecentSamplesForPercentiles() {
        var samples = LatencySamples(capacity: 10)
        for value in 1...25 { samples.record(UInt64(value)) }
        // Percentiles over 16...25; count and max over everything.
        #expect(samples.summary() == .init(count: 25, p50: 20, p95: 25, max: 25))
    }

    @Test func maxCoversOverwrittenSamples() {
        var samples = LatencySamples(capacity: 2)
        samples.record(100)
        samples.record(1)
        samples.record(2)
        #expect(samples.summary() == .init(count: 3, p50: 1, p95: 2, max: 100))
    }
}
