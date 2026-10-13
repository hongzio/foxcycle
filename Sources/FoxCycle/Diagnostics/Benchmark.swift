#if FOXCYCLE_BENCH
import AppKit
import CoreGraphics
import Foundation
import FoxCycleCore
import os

/// Drives FoxCycle with synthesized ⌘` presses to measure latency and to check that every press is
/// accounted for. Compiled only into bench builds (`BENCH=1 scripts/build-app.sh`), started with
/// `open build/FoxCycleBench.app --args -benchPlan all`, and quits when done. Hands off the keyboard
/// and mouse while it runs: stray input shows up as an accounting mismatch.
final class Benchmark: @unchecked Sendable {
    static let planKey = "benchPlan"

    struct Scenario {
        let name: String
        let presses: Int
        let intervalMs: UInt64
        var direction: Direction = .forward
        /// One held key: presses after the first carry the autorepeat flag.
        var held = false
        /// After the run, one more press must still switch (nothing stuck in flight).
        var probe = false
    }

    static let scenarios: [Scenario] = [
        // Consecutive cycling: "current" comes from the trusted last target.
        Scenario(name: "cycle-forward-400ms", presses: 100, intervalMs: 400),
        Scenario(name: "cycle-backward-400ms", presses: 50, intervalMs: 400, direction: .backward),
        // Spaced presses: "current" comes from the Accessibility focused window.
        Scenario(name: "settled-forward-1200ms", presses: 40, intervalMs: 1200),
        Scenario(name: "stress-100ms", presses: 100, intervalMs: 100, probe: true),
        Scenario(name: "stress-30ms", presses: 100, intervalMs: 30, probe: true),
        Scenario(name: "stress-10ms", presses: 100, intervalMs: 10, probe: true),
        Scenario(name: "held-30ms", presses: 31, intervalMs: 30, held: true, probe: true),
    ]

    /// Long enough for the last confirmation to land or time out (1s).
    static let settleMs: UInt64 = 1500

    private let registry: WindowRegistry
    private let interceptor: ShortcutInterceptor
    private let source = CGEventSource(stateID: .privateState)
    private let log = Logger(subsystem: Log.subsystem, category: "bench")

    init(registry: WindowRegistry, interceptor: ShortcutInterceptor) {
        self.registry = registry
        self.interceptor = interceptor
    }

    func start(plan: String) {
        let prefixes = plan == "all" ? [""] : plan.split(separator: ",").map(String.init)
        let selected = Self.scenarios.filter { scenario in prefixes.contains { scenario.name.hasPrefix($0) } }
        let thread = Thread { [self] in
            let failures = run(selected)
            log.notice("bench done: \(selected.count) scenario(s), \(failures) failed")
            Task { @MainActor in NSApplication.shared.terminate(nil) }
        }
        thread.name = "com.hongzio.foxcycle.bench"
        thread.qualityOfService = .userInitiated
        thread.start()
    }

    /// Returns the number of failed scenarios.
    private func run(_ scenarios: [Scenario]) -> Int {
        guard waitFor(seconds: 10, { registry.snapshot.eligibleCount >= 2 }) else {
            log.error("bench aborted: fewer than 2 Firefox windows")
            return scenarios.count
        }
        guard bringFirefoxForward() else {
            log.error("bench aborted: could not bring Firefox to the front")
            return scenarios.count
        }
        log.notice("bench ring: \(self.registry.snapshot.summary, privacy: .public)")
        sleep(ms: Self.settleMs)
        _ = Metrics.shared.takeInterval()

        var failures = 0
        for scenario in scenarios {
            guard interceptor.firefoxFrontmostPid != nil else {
                log.error("bench aborted before \(scenario.name, privacy: .public): Firefox is not frontmost")
                return failures + 1
            }
            if !runScenario(scenario) { failures += 1 }
        }
        return failures
    }

    private func runScenario(_ scenario: Scenario) -> Bool {
        let start = Clock.now()
        var posted = 0
        for index in 0..<scenario.presses {
            sleep(until: start + UInt64(index) * scenario.intervalMs * 1_000_000)
            guard interceptor.firefoxFrontmostPid != nil else { break }
            let repeating = scenario.held && index > 0
            postKey(scenario.direction, down: true, autorepeat: repeating)
            if !scenario.held { postKey(scenario.direction, down: false, autorepeat: false) }
            posted += 1
        }
        if scenario.held { postKey(scenario.direction, down: false, autorepeat: false) }
        sleep(ms: Self.settleMs)

        let interval = Metrics.shared.logInterval("bench \(scenario.name)")
        let c = interval.counters
        let expectedSwitches = scenario.held ? 1 : nil
        var problems: [String] = []
        if posted != scenario.presses { problems.append("stopped after \(posted) presses (Firefox lost focus)") }
        if c.keyDowns != posted { problems.append("tap saw \(c.keyDowns) keyDowns for \(posted) posted") }
        let handled = c.switchRequests + c.swallowedInFlight + c.swallowedAutorepeat + c.shortcutsPassedThrough
        if handled != c.keyDowns { problems.append("\(c.keyDowns - handled) keyDowns unaccounted for") }
        if c.shortcutsPassedThrough != 0 { problems.append("\(c.shortcutsPassedThrough) passed through") }
        if let expectedSwitches, c.switchRequests != expectedSwitches {
            problems.append("\(c.switchRequests) switches, expected \(expectedSwitches)")
        }
        if scenario.held, c.swallowedAutorepeat != posted - 1 {
            problems.append("\(c.swallowedAutorepeat) repeats swallowed, expected \(posted - 1)")
        }
        if c.activated + c.abandoned + c.noTarget != c.switchRequests {
            problems.append("\(c.switchRequests - c.activated - c.abandoned - c.noTarget) switches never finished")
        }
        if c.abandoned + c.noTarget + c.notConfirmed != 0 {
            problems.append("abandoned \(c.abandoned), no target \(c.noTarget), not confirmed \(c.notConfirmed)")
        }
        if c.tapTimeouts != 0 { problems.append("\(c.tapTimeouts) tap timeouts") }
        if scenario.probe, let problem = probe(scenario.direction) { problems.append(problem) }

        if problems.isEmpty {
            log.notice("bench \(scenario.name, privacy: .public): PASS (posted \(posted))")
        } else {
            log.error("bench \(scenario.name, privacy: .public): FAIL — \(problems.joined(separator: "; "), privacy: .public)")
        }
        return problems.isEmpty
    }

    /// One more press after a run: it must start a switch, so nothing is stuck in flight.
    private func probe(_ direction: Direction) -> String? {
        postKey(direction, down: true, autorepeat: false)
        postKey(direction, down: false, autorepeat: false)
        sleep(ms: Self.settleMs)
        let c = Metrics.shared.takeInterval().counters
        return c.switchRequests == 1 && c.activated == 1 ? nil : "probe press: \(c.switchRequests) switch, \(c.activated) activated"
    }

    private func postKey(_ direction: Direction, down: Bool, autorepeat: Bool) {
        guard let event = CGEvent(
            keyboardEventSource: source, virtualKey: CGKeyCode(ShortcutMatcher.graveKeyCode), keyDown: down
        ) else { return }
        event.flags = direction == .forward ? .maskCommand : [.maskCommand, .maskShift]
        if autorepeat { event.setIntegerValueField(.keyboardEventAutorepeat, value: 1) }
        event.post(tap: .cghidEventTap)
    }

    private func bringFirefoxForward() -> Bool {
        let snapshot = registry.snapshot
        guard let entry = snapshot.ring.entries.first(where: \.isAvailable), let handle = snapshot.handles[entry.id],
              WindowActivator.activate(handle) == .activated
        else { return false }
        return waitFor(seconds: 3) { interceptor.firefoxFrontmostPid != nil }
    }

    private func waitFor(seconds: Double, _ condition: () -> Bool) -> Bool {
        let deadline = Clock.now() + UInt64(seconds * 1e9)
        while Clock.now() < deadline {
            if condition() { return true }
            sleep(ms: 50)
        }
        return condition()
    }

    private func sleep(ms: UInt64) {
        sleep(until: Clock.now() + ms * 1_000_000)
    }

    private func sleep(until deadline: UInt64) {
        let now = Clock.now()
        if deadline > now { Thread.sleep(forTimeInterval: Double(deadline - now) / 1e9) }
    }
}
#endif
