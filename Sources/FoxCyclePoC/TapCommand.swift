import AppKit
import ApplicationServices
import os

enum ShortcutMatcher {
    /// kVK_ANSI_Grave: the physical key left of "1" on ANSI keyboards. Matching the keycode (not the
    /// produced character) keeps it stable across input sources such as Korean 2-set.
    static let graveKeyCode: Int64 = 50
    private static let relevantFlags: CGEventFlags = [.maskCommand, .maskShift, .maskAlternate, .maskControl]

    static func match(keyCode: Int64, flags: CGEventFlags) -> Direction? {
        guard keyCode == graveKeyCode else { return nil }
        switch flags.intersection(relevantFlags) {
        case .maskCommand: return .forward
        case [.maskCommand, .maskShift]: return .backward
        default: return nil
        }
    }
}

/// Read by the tap callback; written by main (workspace notifications) and the switch worker.
private struct TapState {
    var firefoxFrontPid: pid_t?
    var eligibleCount = 0
    var pending = 0
}

private struct TapMetrics {
    var callbackMicros: [Double] = []
    var queueDelayMs: [Double] = []
    var applyMs: [Double] = []
    var keyToConfirmedMs: [Double] = []
    var refreshMs: [Double] = []
    var consumed = 0
    var passedNotFirefox = 0
    var passedTooFewWindows = 0
    var dropped = 0
    var tapReenabled = 0
    var confirmed = 0
    var unconfirmed = 0
    var superseded = 0
    var skippedInvalid = 0
}

private func tapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<TapController>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}

/// `tap`: real ⌘` / ⌘⇧` interception with the production threading split —
/// tap thread (lock-protected snapshot only) → serial switch worker (AX) → verifier (logging only).
final class TapController {
    private let strategy: ActivationStrategy
    private let maxPending: Int
    private let trustLastTargetMs: Double
    private let debugKeys: Bool

    private let state = OSAllocatedUnfairLock(initialState: TapState())
    private let metrics = OSAllocatedUnfairLock(initialState: TapMetrics())
    private let generation = OSAllocatedUnfairLock(initialState: 0)
    private let worker = DispatchQueue(label: "foxcycle.switch", qos: .userInteractive)
    private let verifier = DispatchQueue(label: "foxcycle.verify", qos: .utility)
    private let logger = DispatchQueue(label: "foxcycle.log", qos: .utility)
    private var tap: CFMachPort?

    // Worker-confined.
    private let catalog = WindowCatalog()
    private var lastSwitch: (target: RingWindow, at: UInt64)?
    private var lastRingDescription = ""

    init(strategy: ActivationStrategy, maxPending: Int, trustLastTargetMs: Double, debugKeys: Bool) {
        self.strategy = strategy
        self.maxPending = maxPending
        self.trustLastTargetMs = trustLastTargetMs
        self.debugKeys = debugKeys
    }

    func start() {
        let workspace = NSWorkspace.shared
        updateFrontmost(workspace.frontmostApplication)
        let center = workspace.notificationCenter
        center.addObserver(forName: NSWorkspace.didActivateApplicationNotification, object: nil, queue: .main) { [weak self] note in
            self?.updateFrontmost(note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication)
        }
        for name in [NSWorkspace.didLaunchApplicationNotification, NSWorkspace.didTerminateApplicationNotification] {
            center.addObserver(forName: name, object: nil, queue: .main) { [weak self] note in
                guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication,
                      app.bundleIdentifier == firefoxBundleID
                else { return }
                self?.scheduleRefresh(reason: name == NSWorkspace.didLaunchApplicationNotification ? "launch" : "terminate")
            }
        }
        // PoC stand-in for AXObserver-driven updates.
        Timer.scheduledTimer(withTimeInterval: 2, repeats: true) { [weak self] _ in self?.scheduleRefresh(reason: nil) }
        scheduleRefresh(reason: "startup")

        let thread = Thread { [self] in
            installTap()
            CFRunLoopRun()
        }
        thread.name = "foxcycle.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
    }

    // MARK: Event tap thread

    private func installTap() {
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: tapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            print("Failed to create event tap (check Accessibility / Input Monitoring).")
            exit(1)
        }
        self.tap = tap
        CFRunLoopAddSource(CFRunLoopGetCurrent(), CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0), .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        log("event tap installed · strategy \(strategy.summary) · press ⌘` / ⌘⇧` in Firefox, Ctrl-C to stop")
    }

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        let received = Clock.now()
        if type == .tapDisabledByTimeout || type == .tapDisabledByUserInput {
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            metrics.withLock { $0.tapReenabled += 1 }
            log("event tap disabled by \(type == .tapDisabledByTimeout ? "timeout" : "user input"); re-enabled")
            return Unmanaged.passUnretained(event)
        }
        guard type == .keyDown else { return Unmanaged.passUnretained(event) }
        defer {
            let micros = Double(Clock.now() &- received) / 1000
            metrics.withLock { $0.callbackMicros.append(micros) }
        }

        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let matched = ShortcutMatcher.match(keyCode: keyCode, flags: event.flags)
        // Diagnostics only for the grave key (ANSI 50 / ISO section 10); no other key is ever logged.
        if debugKeys, keyCode == ShortcutMatcher.graveKeyCode || keyCode == 10 {
            let front = state.withLock { $0.firefoxFrontPid }
            log("key \(keyCode) flags 0x\(String(event.flags.rawValue, radix: 16))"
                + " repeat \(event.getIntegerValueField(.keyboardEventAutorepeat))"
                + " → \(matched?.rawValue ?? "no match") · firefox front \(front.map(String.init) ?? "no")")
        }
        guard let direction = matched else { return Unmanaged.passUnretained(event) }

        let maxPending = maxPending
        let frontPid: pid_t? = state.withLock { state in
            guard let pid = state.firefoxFrontPid, state.eligibleCount >= 2, state.pending < maxPending else { return nil }
            state.pending += 1
            return pid
        }
        guard let frontPid else {
            let snapshot = state.withLock { $0 }
            metrics.withLock { metrics in
                if snapshot.firefoxFrontPid == nil {
                    metrics.passedNotFirefox += 1
                } else if snapshot.eligibleCount < 2 {
                    metrics.passedTooFewWindows += 1
                } else {
                    metrics.dropped += 1
                }
            }
            // A full queue still means Firefox is front with ≥2 windows: swallow rather than leak to Firefox.
            let dropped = snapshot.firefoxFrontPid != nil && snapshot.eligibleCount >= 2
            return dropped ? nil : Unmanaged.passUnretained(event)
        }

        metrics.withLock { $0.consumed += 1 }
        worker.async { [self] in performSwitch(direction, eventFrontPid: frontPid, receivedAt: received) }
        return nil
    }

    // MARK: Main thread

    private func updateFrontmost(_ app: NSRunningApplication?) {
        let pid = app?.bundleIdentifier == firefoxBundleID ? app?.processIdentifier : nil
        state.withLock { $0.firefoxFrontPid = pid }
    }

    private func scheduleRefresh(reason: String?) {
        worker.async { [self] in refresh(reason: reason) }
    }

    // MARK: Switch worker

    private func refresh(reason: String?) {
        let start = Clock.now()
        catalog.refresh()
        let elapsed = Clock.ms(since: start)
        let count = catalog.ring.count
        state.withLock { $0.eligibleCount = count }
        metrics.withLock { $0.refreshMs.append(elapsed) }
        let description = catalog.ringDescription
        if description != lastRingDescription || reason != nil {
            lastRingDescription = description
            log("ring (\(count))\(reason.map { " [\($0)]" } ?? ""): \(description) · scan \(fmt(elapsed))ms")
        }
    }

    private func performSwitch(_ direction: Direction, eventFrontPid: pid_t, receivedAt: UInt64) {
        let started = Clock.now()
        let frontPid = state.withLock { state in
            state.pending -= 1
            return state.firefoxFrontPid
        } ?? eventFrontPid

        // AX focus lags behind a switch that is still landing. Trusting our own last target for a short
        // window prevents rapid presses from bouncing between the same two windows.
        var currentIndex: Int?
        var source = "none"
        if let last = lastSwitch, Clock.ms(since: last.at) < trustLastTargetMs, let index = catalog.index(of: last.target) {
            currentIndex = index
            source = "last"
        } else if let index = catalog.indexOfFocusedWindow(pid: frontPid) {
            currentIndex = index
            source = "ax"
        } else {
            refresh(reason: "focused window not in ring")
            currentIndex = catalog.indexOfFocusedWindow(pid: frontPid)
            if currentIndex != nil { source = "ax+rescan" }
        }

        let ring = catalog.ring
        guard ring.count >= 2 else {
            log("\(direction.rawValue) skipped: ring has \(ring.count) window(s)")
            return
        }
        // Unknown origin: forward lands on ring[0], backward on the last entry.
        let origin = currentIndex ?? (direction == .forward ? ring.count - 1 : 0)
        let offsets = currentIndex == nil ? Array(1...ring.count) : Array(1..<ring.count)

        var invalid: [RingWindow] = []
        var chosen: (target: RingWindow, outcomes: [OpOutcome])?
        for offset in offsets {
            let candidate = ring[((origin + direction.step * offset) % ring.count + ring.count) % ring.count]
            let outcomes = Activator.apply(strategy, to: candidate)
            if outcomes.contains(where: \.invalidatesTarget) {
                invalid.append(candidate)
                continue
            }
            chosen = (candidate, outcomes)
            break
        }
        if !invalid.isEmpty {
            invalid.forEach(catalog.remove)
            let count = catalog.ring.count
            let skipped = invalid.count
            state.withLock { $0.eligibleCount = count }
            metrics.withLock { $0.skippedInvalid += skipped }
        }

        let applied = Clock.now()
        guard let chosen else {
            log("\(direction.rawValue) no valid target (invalid: \(invalid.map(\.label)))")
            return
        }
        lastSwitch = (chosen.target, applied)
        let current = generation.withLock { value -> Int in
            value += 1
            return value
        }
        let queueDelay = Clock.ms(since: receivedAt, until: started)
        let apply = Clock.ms(since: started, until: applied)
        metrics.withLock {
            $0.queueDelayMs.append(queueDelay)
            $0.applyMs.append(apply)
        }
        let from = currentIndex.map { ring[$0].label } ?? "?"
        let summary = "\(direction.rawValue) \(from)→\(chosen.target.label) [\(source)]"
            + " queue \(fmt(queueDelay, digits: 2))ms apply \(fmt(apply))ms"
            + " [\(chosen.outcomes.map(\.compact).joined(separator: " "))]"
            + (invalid.isEmpty ? "" : " skipped-invalid \(invalid.map(\.label))")
        let target = chosen.target
        let ringSnapshot = catalog.ring
        verifier.async { [self] in
            verify(target, ring: ringSnapshot, generation: current, receivedAt: receivedAt, summary: summary)
        }
    }

    // MARK: Verifier

    private func verify(
        _ target: RingWindow, ring: [RingWindow], generation expected: Int, receivedAt: UInt64, summary: String
    ) {
        while true {
            if generation.withLock({ $0 }) != expected {
                metrics.withLock { $0.superseded += 1 }
                log("\(summary) · superseded")
                return
            }
            let observation = FocusProbe.observe(target, ring: ring)
            let elapsed = Clock.ms(since: receivedAt)
            if observation.confirmed(target) {
                metrics.withLock {
                    $0.confirmed += 1
                    $0.keyToConfirmedMs.append(elapsed)
                }
                log("\(summary) · confirmed \(fmt(elapsed))ms after key")
                return
            }
            if elapsed > 1000 {
                metrics.withLock { $0.unconfirmed += 1 }
                let top = observation.topWindow.map { "\($0.owner) pid \($0.pid) \($0.bounds.compact)" } ?? "none"
                log("\(summary) · NOT confirmed after 1s: axApp pid \(observation.axAppPid.map(String.init) ?? "nil")"
                    + " axWin \(observation.axWindowMatches ? "✓" : "✗") top \(top)")
                return
            }
            Clock.sleep(ms: 2)
        }
    }

    // MARK: Output

    private func log(_ message: String) {
        let now = Date()
        logger.async { print("[\(timeFormatter.string(from: now))] \(message)") }
    }

    func printSummary() {
        let m = metrics.withLock { $0 }
        logger.sync {
            print("")
            print("== tap summary · strategy \(strategy.summary)")
            print("callback (all keyDown):   \(distribution(m.callbackMicros, unit: "µs"))")
            print("key → worker start:       \(distribution(m.queueDelayMs, digits: 2))")
            print("activation calls:         \(distribution(m.applyMs))")
            print("key → focus confirmed:    \(distribution(m.keyToConfirmedMs))")
            print("ring rescans:             \(distribution(m.refreshMs))")
            print("consumed \(m.consumed) · passed (not Firefox) \(m.passedNotFirefox)"
                + " · passed (<2 windows) \(m.passedTooFewWindows) · dropped (queue full) \(m.dropped)")
            print("confirmed \(m.confirmed) · unconfirmed \(m.unconfirmed) · superseded \(m.superseded)"
                + " · skipped invalid \(m.skippedInvalid) · tap re-enabled \(m.tapReenabled)")
        }
    }
}
