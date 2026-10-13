import Darwin
import Foundation
import FoxCycleCore
import os

/// In-memory counters and latency samples for the measurement report and the long-run test.
///
/// Nothing is logged per keystroke: the event tap only adds to these aggregates, and `takeInterval()`
/// turns everything since the previous call into a few summary lines.
final class Metrics: Sendable {
    static let shared = Metrics()

    enum Series: Int, CaseIterable {
        /// Event-tap callback run time, for every keyDown.
        case callback
        /// Event timestamp → tap callback, for every keyDown.
        case delivery
        /// Tap callback → switch queue start.
        case queue
        case activationSameProcess
        case activationCrossProcess
        /// Tap callback → Accessibility reports the target window focused.
        case confirmSameProcess
        case confirmCrossProcess

        var capacity: Int { self == .callback || self == .delivery ? 8192 : 2048 }
    }

    /// Cumulative since launch; intervals report differences.
    struct Counters: Sendable, Equatable {
        var keyDowns = 0
        var invalidTimestamps = 0
        var shortcutsPassedThrough = 0
        var swallowedAutorepeat = 0
        var swallowedInFlight = 0
        var switchRequests = 0
        var tapTimeouts = 0
        var tapUserInputDisables = 0
        var activated = 0
        var abandoned = 0
        var noTarget = 0
        var windowsGone = 0
        var confirmed = 0
        var notConfirmed = 0
        var superseded = 0

        static func - (lhs: Counters, rhs: Counters) -> Counters {
            var result = Counters()
            for path in Self.paths { result[keyPath: path] = lhs[keyPath: path] - rhs[keyPath: path] }
            return result
        }

        private static var paths: [WritableKeyPath<Counters, Int>] { [
            \.keyDowns, \.invalidTimestamps, \.shortcutsPassedThrough, \.swallowedAutorepeat, \.swallowedInFlight,
            \.switchRequests, \.tapTimeouts, \.tapUserInputDisables, \.activated, \.abandoned, \.noTarget,
            \.windowsGone, \.confirmed, \.notConfirmed, \.superseded,
        ] }
    }

    enum SwitchResult {
        case activated(activationNanos: UInt64, sameProcess: Bool)
        case abandoned
        case noTarget
    }

    enum Confirmation {
        case confirmed(elapsedNanos: UInt64, sameProcess: Bool)
        case notConfirmed
        /// A newer switch started before this one could be confirmed.
        case superseded
    }

    enum TapEvent {
        case timeout
        case userInputDisable
    }

    struct Interval: Sendable {
        let seconds: Double
        let counters: Counters
        let summaries: [Series: LatencySamples.Summary]
        let cpuSeconds: Double
        let totalCPUSeconds: Double
        let footprintBytes: UInt64?
    }

    private struct State: Sendable {
        var counters = Counters()
        var samples = Metrics.emptySamples()
    }

    private struct Baseline: Sendable {
        var counters = Counters()
        var time = Clock.now()
        var cpuSeconds = Metrics.cpuSeconds()
    }

    private let state = OSAllocatedUnfairLock(initialState: State())
    private let baseline = OSAllocatedUnfairLock(initialState: Baseline())

    private static func emptySamples() -> [LatencySamples] {
        Series.allCases.map { LatencySamples(capacity: $0.capacity) }
    }

    // MARK: Recording (any thread, including the event tap)

    func recordKeyDown(decision: KeyDecision, isShortcut: Bool, callbackNanos: UInt64, deliveryNanos: UInt64?) {
        state.withLock { state in
            state.counters.keyDowns += 1
            state.samples[Series.callback.rawValue].record(callbackNanos)
            if let deliveryNanos {
                state.samples[Series.delivery.rawValue].record(deliveryNanos)
            } else {
                state.counters.invalidTimestamps += 1
            }
            switch decision {
            case .passThrough where isShortcut: state.counters.shortcutsPassedThrough += 1
            case .passThrough: break
            case .swallow(.autorepeat): state.counters.swallowedAutorepeat += 1
            case .swallow(.inFlight): state.counters.swallowedInFlight += 1
            case .switchWindow: state.counters.switchRequests += 1
            }
        }
    }

    func recordTapEvent(_ event: TapEvent) {
        state.withLock { state in
            switch event {
            case .timeout: state.counters.tapTimeouts += 1
            case .userInputDisable: state.counters.tapUserInputDisables += 1
            }
        }
    }

    func recordSwitch(queueNanos: UInt64, result: SwitchResult, windowsGone: Int) {
        state.withLock { state in
            state.samples[Series.queue.rawValue].record(queueNanos)
            state.counters.windowsGone += windowsGone
            switch result {
            case .activated(let nanos, let sameProcess):
                state.counters.activated += 1
                let series: Series = sameProcess ? .activationSameProcess : .activationCrossProcess
                state.samples[series.rawValue].record(nanos)
            case .abandoned:
                state.counters.abandoned += 1
            case .noTarget:
                state.counters.noTarget += 1
            }
        }
    }

    func recordConfirmation(_ confirmation: Confirmation) {
        state.withLock { state in
            switch confirmation {
            case .confirmed(let nanos, let sameProcess):
                state.counters.confirmed += 1
                let series: Series = sameProcess ? .confirmSameProcess : .confirmCrossProcess
                state.samples[series.rawValue].record(nanos)
            case .notConfirmed:
                state.counters.notConfirmed += 1
            case .superseded:
                state.counters.superseded += 1
            }
        }
    }

    // MARK: Reporting (off the event-tap thread)

    /// Everything since the previous call. Sample buffers are swapped for fresh ones under the lock,
    /// so the tap never waits on sorting and never copies a buffer.
    func takeInterval() -> Interval {
        var samples = Self.emptySamples()
        // A true swap leaves the fresh buffers referenced only by `state`; with `withLock` the closure
        // would hold a second reference and the tap's next record() would copy the buffer.
        let counters = state.withLockUnchecked { state -> Counters in
            swap(&state.samples, &samples)
            return state.counters
        }
        let now = Clock.now()
        let cpu = Self.cpuSeconds()
        let previous = baseline.withLock { baseline -> Baseline in
            let previous = baseline
            baseline = Baseline(counters: counters, time: now, cpuSeconds: cpu)
            return previous
        }
        var summaries: [Series: LatencySamples.Summary] = [:]
        for series in Series.allCases {
            summaries[series] = samples[series.rawValue].summary()
        }
        return Interval(
            seconds: Double(now &- previous.time) / 1e9,
            counters: counters - previous.counters,
            summaries: summaries,
            cpuSeconds: cpu - previous.cpuSeconds,
            totalCPUSeconds: cpu,
            footprintBytes: Self.footprintBytes()
        )
    }

    static func cpuSeconds() -> Double {
        var usage = rusage()
        guard getrusage(RUSAGE_SELF, &usage) == 0 else { return 0 }
        func seconds(_ time: timeval) -> Double { Double(time.tv_sec) + Double(time.tv_usec) / 1e6 }
        return seconds(usage.ru_utime) + seconds(usage.ru_stime)
    }

    /// The number Activity Monitor shows as "Memory".
    static func footprintBytes() -> UInt64? {
        var info = rusage_info_v4()
        let result = withUnsafeMutablePointer(to: &info) { pointer in
            pointer.withMemoryRebound(to: rusage_info_t?.self, capacity: 1) {
                proc_pid_rusage(getpid(), RUSAGE_INFO_V4, $0)
            }
        }
        return result == 0 ? info.ri_phys_footprint : nil
    }
}

extension Metrics {
    /// Persisted (notice level) so the long-run test can read it back with `log show`.
    @discardableResult
    func logInterval(_ label: String) -> Interval {
        let interval = takeInterval()
        for line in interval.lines {
            Log.metrics.notice("\(label, privacy: .public) \(line, privacy: .public)")
        }
        return interval
    }
}

extension Metrics.Interval {
    /// Numbers only: no window titles, keys or key codes.
    var lines: [String] {
        let c = counters
        // A percentage over a sub-second interval (e.g. quitting right after a report) means nothing.
        let cpuPercent = seconds >= 1 ? String(format: "%.4f%%", cpuSeconds / seconds * 100) : "-"
        let footprint = footprintBytes.map { String(format: "%.1fMB", Double($0) / 1_048_576) } ?? "?"
        return [
            "keys \(c.keyDowns) | callback \(describe(.callback)) | delivery \(describe(.delivery)), "
                + "invalid timestamps \(c.invalidTimestamps)",
            "shortcut: switch \(c.switchRequests), held \(c.swallowedAutorepeat), in-flight \(c.swallowedInFlight), "
                + "passed through \(c.shortcutsPassedThrough)",
            "switch: activated \(c.activated), abandoned \(c.abandoned), no target \(c.noTarget), "
                + "windows gone \(c.windowsGone) | confirmed \(c.confirmed), not confirmed \(c.notConfirmed), "
                + "superseded \(c.superseded)",
            "latency: queue \(describe(.queue)) | activation same \(describe(.activationSameProcess)) "
                + "cross \(describe(.activationCrossProcess))",
            "latency: confirm same \(describe(.confirmSameProcess)) cross \(describe(.confirmCrossProcess))",
            String(format: "process: %.0fs, cpu %.3fs (%@), total cpu %.2fs, footprint %@, ",
                   seconds, cpuSeconds, cpuPercent, totalCPUSeconds, footprint)
                + "tap timeouts \(c.tapTimeouts), user-input disables \(c.tapUserInputDisables)",
        ]
    }

    func describe(_ series: Metrics.Series) -> String {
        guard let s = summaries[series] else { return "-" }
        return "p50 \(Self.format(s.p50)) p95 \(Self.format(s.p95)) max \(Self.format(s.max)) (n \(s.count))"
    }

    static func format(_ nanos: UInt64) -> String {
        nanos < 1_000_000 ? "\(nanos / 1000)µs" : String(format: "%.1fms", Double(nanos) / 1e6)
    }
}
