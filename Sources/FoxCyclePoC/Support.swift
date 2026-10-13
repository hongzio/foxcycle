import AppKit
import CoreGraphics
import Foundation

enum Clock {
    static func now() -> UInt64 { clock_gettime_nsec_np(CLOCK_UPTIME_RAW) }

    static func ms(since start: UInt64, until end: UInt64 = now()) -> Double {
        Double(end &- start) / 1_000_000
    }

    static func sleep(ms: Int) {
        if ms > 0 { usleep(useconds_t(ms) * 1000) }
    }
}

/// Nearest-rank percentile; `p` in 0...100.
func percentile(_ values: [Double], _ p: Double) -> Double? {
    guard !values.isEmpty else { return nil }
    let sorted = values.sorted()
    let rank = Int((p / 100 * Double(sorted.count)).rounded(.up))
    return sorted[min(max(rank - 1, 0), sorted.count - 1)]
}

func fmt(_ value: Double?, digits: Int = 1) -> String {
    guard let value else { return "-" }
    return String(format: "%.\(digits)f", value)
}

func distribution(_ values: [Double], unit: String = "ms", digits: Int = 1) -> String {
    guard !values.isEmpty else { return "n=0" }
    return "n=\(values.count) p50 \(fmt(percentile(values, 50), digits: digits))\(unit)"
        + " p95 \(fmt(percentile(values, 95), digits: digits))\(unit)"
        + " max \(fmt(values.max(), digits: digits))\(unit)"
}

struct Options {
    private var values: [String: String] = [:]
    private var flags: Set<String> = []

    init<S: Sequence>(_ arguments: S) where S.Element == String {
        var pending: String?
        for argument in arguments {
            if argument.hasPrefix("--") {
                if let key = pending { flags.insert(key) }
                let body = String(argument.dropFirst(2))
                if let eq = body.firstIndex(of: "=") {
                    values[String(body[..<eq])] = String(body[body.index(after: eq)...])
                    pending = nil
                } else {
                    pending = body
                }
            } else if let key = pending {
                values[key] = argument
                pending = nil
            }
        }
        if let key = pending { flags.insert(key) }
    }

    func string(_ key: String, default fallback: String) -> String { values[key] ?? fallback }
    func int(_ key: String, default fallback: Int) -> Int { values[key].flatMap(Int.init) ?? fallback }
    func flag(_ key: String) -> Bool { flags.contains(key) }
}

enum EnvironmentInfo {
    static func describe(instances: [FirefoxInstance]) -> String {
        let os = ProcessInfo.processInfo.operatingSystemVersionString
        var displayCount: UInt32 = 0
        CGGetActiveDisplayList(0, nil, &displayCount)
        let versions = Set(instances.compactMap { instance -> String? in
            guard let url = instance.app.bundleURL else { return nil }
            return Bundle(url: url)?.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String
        })
        return "macOS \(os) · \(sysctl("hw.model") ?? "?") · displays \(displayCount)"
            + " · Firefox \(versions.isEmpty ? "?" : versions.sorted().joined(separator: "/"))"
            + " · profiles \(instances.count)"
    }

    private static func sysctl(_ name: String) -> String? {
        var size = 0
        guard sysctlbyname(name, nil, &size, nil, 0) == 0, size > 0 else { return nil }
        var buffer = [CChar](repeating: 0, count: size)
        guard sysctlbyname(name, &buffer, &size, nil, 0) == 0 else { return nil }
        return String(cString: buffer)
    }
}

let timeFormatter: DateFormatter = {
    let formatter = DateFormatter()
    formatter.dateFormat = "HH:mm:ss"
    return formatter
}()
