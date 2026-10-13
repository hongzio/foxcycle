import AppKit
import ApplicationServices
import os

enum Direction: String {
    case forward = "fwd"
    case backward = "bwd"

    var step: Int { self == .forward ? 1 : -1 }
}

struct StepRecord {
    let index: Int
    let from: String
    let to: String
    let targetPid: pid_t
    var outcomes: [OpOutcome] = []
    var applyMs = 0.0
    // First time each signal pointed at the target, measured from the start of the activation calls.
    // topMs comes from a dedicated window-server sampler (1ms); the AX ones from the probe loop.
    var axAppMs: Double?
    var axWindowMs: Double?
    var topMs: Double?
    var workspaceMs: Double?
    /// All three of axApp, axWindow and top agreed at the same instant.
    var confirmedMs: Double?
    /// Still confirmed after the settle delay (catches another profile window popping back on top).
    var stable: Bool?
    var last: FocusObservation?
}

struct RunSummary {
    let strategy: ActivationStrategy
    let direction: Direction
    let records: [StepRecord]

    var confirmed: Int { records.filter { $0.confirmedMs != nil }.count }
    var stable: Int { records.filter { $0.stable == true }.count }
    var latencies: [Double] { records.compactMap(\.confirmedMs) }
    var passed: Bool { confirmed == records.count && stable == records.count }

    var failureBreakdown: String {
        let failed = records.filter { $0.confirmedMs == nil || $0.stable == false }
        guard !failed.isEmpty else { return "-" }
        let axApp = failed.filter { $0.last?.axAppPid != $0.targetPid }.count
        let axWindow = failed.filter { $0.last?.axWindowMatches != true }.count
        let top = failed.filter { $0.last?.topMatches != true }.count
        return "axApp✗\(axApp) axWin✗\(axWindow) top✗\(top)"
    }

    var opErrors: String {
        var counts: [String: Int] = [:]
        for outcome in records.flatMap(\.outcomes) where !outcome.ok {
            counts[outcome.compact, default: 0] += 1
        }
        return counts.isEmpty ? "-" : counts.sorted { $0.key < $1.key }.map { "\($0.key)×\($0.value)" }.joined(separator: " ")
    }
}

/// `bench`: drive the ring automatically and measure whether each activation strategy really lands.
enum BenchCommand {
    static func run(_ options: Options) {
        guard let strategies = ActivationStrategy.parse(options.string("strategy", default: "all")) else {
            print("Invalid --strategy. Use all, s1..s5, or an op chain like raise+frontmost.")
            exit(2)
        }
        let directions: [Direction] = switch options.string("dir", default: "both") {
        case "fwd": [.forward]
        case "bwd": [.backward]
        default: [.forward, .backward]
        }
        let count = options.int("count", default: 50)
        let timeoutMs = options.int("timeout-ms", default: 1000)
        let settleMs = options.int("settle-ms", default: 200)
        let intervalMs = options.int("interval-ms", default: 150)
        let verbose = options.flag("verbose")

        let catalog = WindowCatalog()
        catalog.refresh()
        print("Environment: \(EnvironmentInfo.describe(instances: catalog.instances))")
        print("Ring (\(catalog.ring.count)): \(catalog.ringDescription)")
        print("count \(count) · timeout \(timeoutMs)ms · settle \(settleMs)ms · interval \(intervalMs)ms")
        guard catalog.ring.count >= 2 else {
            print("Need at least 2 eligible Firefox windows.")
            exit(1)
        }
        ListCommand.ambiguityWarnings(catalog.ring).forEach { print("WARNING: \($0)") }

        let delay = options.int("delay-s", default: 3)
        print("Starting in \(delay)s — hands off keyboard and mouse until it finishes.")
        Clock.sleep(ms: delay * 1000)

        var summaries: [RunSummary] = []
        for strategy in strategies {
            for direction in directions {
                print("")
                print("== \(strategy.summary) \(direction.rawValue) ×\(count)")
                var records: [StepRecord] = []
                var lastTarget: Int?
                for index in 1...count {
                    let ring = catalog.ring
                    let current = AX.focusedApplicationPid().flatMap(catalog.indexOfFocusedWindow(pid:)) ?? lastTarget
                    let targetIndex = current.map { (($0 + direction.step) % ring.count + ring.count) % ring.count } ?? 0
                    let target = ring[targetIndex]
                    var record = StepRecord(
                        index: index, from: current.map { ring[$0].label } ?? "?", to: target.label, targetPid: target.instance.pid
                    )
                    step(&record, strategy: strategy, target: target, ring: ring, timeoutMs: timeoutMs, settleMs: settleMs)
                    if verbose || record.confirmedMs == nil || record.stable == false {
                        print(describe(record, catalog: catalog))
                    }
                    records.append(record)
                    lastTarget = targetIndex
                    Clock.sleep(ms: intervalMs)
                }
                let summary = RunSummary(strategy: strategy, direction: direction, records: records)
                summaries.append(summary)
                print("-> confirmed \(summary.confirmed)/\(count) stable \(summary.stable)/\(count)"
                    + " · \(distribution(summary.latencies)) · \(summary.failureBreakdown) · op errors \(summary.opErrors)")
            }
        }

        print("")
        print("| strategy | ops | dir | confirmed | stable | p50 ms | p95 ms | max ms | failed signals | op errors | pass |")
        print("|---|---|---|---:|---:|---:|---:|---:|---|---|---|")
        for summary in summaries {
            let latencies = summary.latencies
            print("| \(summary.strategy.name) | \(summary.strategy.ops.map(\.rawValue).joined(separator: "→"))"
                + " | \(summary.direction.rawValue) | \(summary.confirmed)/\(count) | \(summary.stable)/\(count)"
                + " | \(fmt(percentile(latencies, 50))) | \(fmt(percentile(latencies, 95))) | \(fmt(latencies.max()))"
                + " | \(summary.failureBreakdown) | \(summary.opErrors) | \(summary.passed ? "✅" : "❌") |")
        }
    }

    private static func step(
        _ record: inout StepRecord, strategy: ActivationStrategy, target: RingWindow, ring: [RingWindow],
        timeoutMs: Int, settleMs: Int
    ) {
        let start = Clock.now()
        // AX probes block while Firefox is busy handling the activation, so sample the window server
        // on its own thread to see when the target is visually on top.
        let visualTopMs = OSAllocatedUnfairLock<Double?>(initialState: nil)
        let samplerDone = DispatchSemaphore(value: 0)
        Thread {
            defer { samplerDone.signal() }
            while Clock.ms(since: start) < Double(timeoutMs) {
                if let top = FocusProbe.topWindow(ring: ring),
                   top.pid == target.instance.pid, top.bounds.approximatelyEquals(target.frame) {
                    let elapsed = Clock.ms(since: start)
                    visualTopMs.withLock { $0 = elapsed }
                    return
                }
                Clock.sleep(ms: 1)
            }
        }.start()
        defer { record.topMs = visualTopMs.withLock { $0 } }

        record.outcomes = Activator.apply(strategy, to: target)
        record.applyMs = Clock.ms(since: start)

        while true {
            let observation = FocusProbe.observe(target, ring: ring)
            let elapsed = Clock.ms(since: start)
            if record.axAppMs == nil, observation.axAppMatches(target) { record.axAppMs = elapsed }
            if record.axWindowMs == nil, observation.axWindowMatches { record.axWindowMs = elapsed }
            if record.workspaceMs == nil, observation.workspaceMatches(target) { record.workspaceMs = elapsed }
            record.last = observation
            if observation.confirmed(target) {
                record.confirmedMs = elapsed
                break
            }
            if elapsed >= Double(timeoutMs) { break }
            Clock.sleep(ms: 2)
        }

        guard record.confirmedMs != nil else { return }
        // The sampler has seen the target on top by now (confirmed includes it); wait so topMs is final.
        samplerDone.wait()
        Clock.sleep(ms: settleMs)
        let observation = FocusProbe.observe(target, ring: ring)
        record.stable = observation.confirmed(target)
        record.last = observation
    }

    private static func describe(_ record: StepRecord, catalog: WindowCatalog) -> String {
        let status = record.confirmedMs == nil ? "FAIL" : (record.stable == true ? "OK  " : "UNSTABLE")
        var line = "#\(record.index) \(record.from)→\(record.to) \(status) \(fmt(record.confirmedMs))ms"
            + " (axApp \(fmt(record.axAppMs)) axWin \(fmt(record.axWindowMs)) top \(fmt(record.topMs)) ws \(fmt(record.workspaceMs)))"
            + " apply \(fmt(record.applyMs))ms [\(record.outcomes.map(\.compact).joined(separator: " "))]"
        if record.confirmedMs == nil || record.stable == false, let last = record.last {
            let top = last.topWindow.map { window in
                "\(window.owner) pid \(window.pid)" + (catalog.label(forScreenWindow: window).map { " = \($0)" } ?? "")
            } ?? "none"
            line += " | now: axApp pid \(last.axAppPid.map(String.init) ?? "nil") axWin \(last.axWindowMatches ? "✓" : "✗") top \(top)"
        }
        return line
    }
}
