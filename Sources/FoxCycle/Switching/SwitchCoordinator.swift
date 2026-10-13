import ApplicationServices
import Foundation
import FoxCycleCore
import os

/// Runs switches one at a time on a serial queue and verifies the result off that queue.
final class SwitchCoordinator: @unchecked Sendable {
    static let verificationTimeoutMs: Double = 1000
    static let verificationPollMicros: useconds_t = 10_000

    private let registry: WindowRegistry
    /// Called once a switch's activation calls have returned (success or not).
    private let onSwitchFinished: @Sendable () -> Void
    private let queue = DispatchQueue(label: "com.hongzio.foxcycle.switch", qos: .userInteractive)
    private let verifyQueue = DispatchQueue(label: "com.hongzio.foxcycle.verify", qos: .utility)
    private let generation = OSAllocatedUnfairLock(initialState: 0)

    /// Confined to `queue`.
    private var engine = SwitchEngine<WindowToken>()

    init(registry: WindowRegistry, onSwitchFinished: @escaping @Sendable () -> Void) {
        self.registry = registry
        self.onSwitchFinished = onSwitchFinished
    }

    /// Safe to call from the event-tap thread: only enqueues.
    func requestSwitch(_ direction: Direction, firefoxPid: pid_t, receivedAt: UInt64) {
        queue.async { [self] in perform(direction, firefoxPid: firefoxPid, receivedAt: receivedAt) }
    }

    private func perform(_ direction: Direction, firefoxPid: pid_t, receivedAt: UInt64) {
        let started = Clock.now()
        let signpost = Log.signposter.beginInterval("switch")
        defer {
            Log.signposter.endInterval("switch", signpost)
            onSwitchFinished()
        }
        registry.noteSwitchActivity()

        let snapshot = registry.snapshot
        var focusedOutsideRing = false
        let report = engine.performSwitch(
            direction: direction,
            ring: snapshot.ring,
            now: Clock.now,
            focusedWindow: {
                guard let focused = AX.element(AXUIElementCreateApplication(firefoxPid), kAXFocusedWindowAttribute)
                else { return nil }
                let token = snapshot.token(of: focused, pid: firefoxPid)
                focusedOutsideRing = token == nil
                return token
            },
            activate: { token in snapshot.handles[token].map(WindowActivator.activate) ?? .windowGone }
        )

        for token in report.windowsGone {
            registry.removeWindow(token)
            if let pid = snapshot.handles[token]?.pid { registry.requestRescan(pid: pid) }
        }
        if focusedOutsideRing { registry.requestRescan(pid: firefoxPid) }

        let finished = Clock.now()
        let queueMs = Clock.ms(since: receivedAt, until: started)
        let activationMs = Clock.ms(since: started, until: finished)
        let from = report.current.map(String.init(describing:)) ?? "?"
        let fromPid = report.current.flatMap { snapshot.handles[$0]?.pid }
        let result: Metrics.SwitchResult
        switch report.outcome {
        case .activated(let token):
            let sameProcess = fromPid != nil && fromPid == snapshot.handles[token]?.pid
            result = .activated(activationNanos: finished &- started, sameProcess: sameProcess)
            Log.switching.info("""
                \(direction == .forward ? "fwd" : "bwd", privacy: .public) \(from, privacy: .public)→\(token, privacy: .public) \
                [\(String(describing: report.currentSource), privacy: .public)] queue \(queueMs, format: .fixed(precision: 2))ms \
                activation \(activationMs, format: .fixed(precision: 1))ms
                """)
            if let handle = snapshot.handles[token] { verify(handle, receivedAt: receivedAt, sameProcess: sameProcess) }
        case .abandoned(let token):
            result = .abandoned
            Log.switching.error("abandoned switch to \(token, privacy: .public): owner unresponsive")
            if let pid = snapshot.handles[token]?.pid { registry.requestRescan(pid: pid) }
        case .noTarget:
            result = .noTarget
            Log.switching.notice("no switch target (ring \(snapshot.ring.availableCount) available)")
        }
        Metrics.shared.recordSwitch(queueNanos: started &- receivedAt, result: result, windowsGone: report.windowsGone.count)
    }

    /// Confirms through Accessibility that focus really moved. Logging and cache repair only:
    /// the input path never waits on this.
    private func verify(_ handle: WindowHandle, receivedAt: UInt64, sameProcess: Bool) {
        let expected = generation.withLock { value -> Int in
            value += 1
            return value
        }
        verifyQueue.async { [self] in
            while generation.withLock({ $0 }) == expected {
                let focusedPid = AX.focusedApplicationPid()
                let now = Clock.now()
                let elapsed = Clock.ms(since: receivedAt, until: now)
                if focusedPid == handle.pid,
                   let focused = AX.element(handle.app, kAXFocusedWindowAttribute), CFEqual(focused, handle.window) {
                    Log.signposter.emitEvent("confirmed")
                    Metrics.shared.recordConfirmation(.confirmed(elapsedNanos: now &- receivedAt, sameProcess: sameProcess))
                    Log.switching.info("confirmed \(handle.token, privacy: .public) \(elapsed, format: .fixed(precision: 1))ms after key")
                    return
                }
                if elapsed > Self.verificationTimeoutMs {
                    Metrics.shared.recordConfirmation(.notConfirmed)
                    Log.switching.error("""
                        \(handle.token, privacy: .public) not confirmed after \(elapsed, format: .fixed(precision: 0))ms \
                        (focused pid \(focusedPid.map(String.init) ?? "nil", privacy: .public))
                        """)
                    registry.requestRescan(pid: handle.pid)
                    return
                }
                usleep(Self.verificationPollMicros)
            }
            Metrics.shared.recordConfirmation(.superseded)
        }
    }
}
