import Foundation
import os

/// Local-only diagnostics. Never log window titles, URLs or key input — only window tokens,
/// PIDs, directions and timings.
enum Log {
    static let subsystem = "com.hongzio.foxcycle"
    static let app = Logger(subsystem: subsystem, category: "app")
    static let keyboard = Logger(subsystem: subsystem, category: "keyboard")
    static let registry = Logger(subsystem: subsystem, category: "registry")
    static let switching = Logger(subsystem: subsystem, category: "switch")
    /// Periodic summaries at notice level, so they persist without a live `log stream`.
    static let metrics = Logger(subsystem: subsystem, category: "metrics")
    /// Intervals/events for Instruments (Points of Interest): key → activation, focus confirmed.
    static let signposter = OSSignposter(subsystem: subsystem, category: .pointsOfInterest)
}

enum Clock {
    /// Monotonic nanoseconds; unaffected by wall-clock changes.
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func ms(since start: UInt64, until end: UInt64 = now()) -> Double {
        Double(end &- start) / 1_000_000
    }
}
