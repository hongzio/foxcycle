import CoreGraphics
import Foundation
import FoxCycleCore
import os

extension Modifiers {
    init(_ flags: CGEventFlags) {
        var modifiers: Modifiers = []
        if flags.contains(.maskCommand) { modifiers.insert(.command) }
        if flags.contains(.maskShift) { modifiers.insert(.shift) }
        if flags.contains(.maskAlternate) { modifiers.insert(.option) }
        if flags.contains(.maskControl) { modifiers.insert(.control) }
        self = modifiers
    }
}

/// Session-level keyDown tap on a dedicated thread.
///
/// The callback only reads a lock-protected `InterceptState` and enqueues work: no Accessibility,
/// no I/O, no waiting. If the tap cannot be created (no permission) nothing is intercepted, so the
/// system's own ⌘` keeps working.
final class ShortcutInterceptor: @unchecked Sendable {
    /// Repeated timeouts within this window mean something is wrong; stop rather than fight the system.
    static let timeoutWindowNanos: UInt64 = 10_000_000_000
    static let maxTimeoutsInWindow = 3

    /// Called on the tap thread. Set before `start()`.
    var onSwitch: (@Sendable (Direction, pid_t, UInt64) -> Void)?
    /// The tap gave up after repeated timeouts and removed itself. Called on the tap thread.
    var onTapFailure: (@Sendable () -> Void)?

    private let state = OSAllocatedUnfairLock(initialState: InterceptState())

    // Tap-thread state. `runLoop` is written once before `start()` returns.
    private var runLoop: CFRunLoop?
    private var tap: CFMachPort?
    private var source: CFRunLoopSource?
    private var recentTimeouts: [UInt64] = []
    private var loggedImplausibleTimestamp = false

    func start() {
        guard runLoop == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let current = CFRunLoopGetCurrent()!
            // Keeps CFRunLoopRun alive while no tap is installed.
            let keepAlive = CFRunLoopTimerCreateWithHandler(nil, .greatestFiniteMagnitude, 0, 0, 0) { _ in }
            CFRunLoopAddTimer(current, keepAlive, .defaultMode)
            runLoop = current
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.hongzio.foxcycle.eventtap"
        thread.qualityOfService = .userInteractive
        thread.start()
        ready.wait()
    }

    // MARK: State (any thread)

    func setEnabled(_ enabled: Bool) {
        state.withLock { $0.isEnabled = enabled }
    }

    func setFirefoxFrontmost(_ pid: pid_t?) {
        state.withLock { $0.firefoxFrontmostPid = pid }
    }

    func setEligibleWindowCount(_ count: Int) {
        state.withLock { $0.eligibleWindowCount = count }
    }

    func switchFinished() {
        state.withLock { $0.switchStartedAt = nil }
    }

    var firefoxFrontmostPid: pid_t? {
        state.withLock { $0.firefoxFrontmostPid }
    }

    // MARK: Install / uninstall (any thread; runs on the tap thread)

    /// Returns false when the tap could not be created (typically missing permission).
    func install() -> Bool {
        let installed = OSAllocatedUnfairLock(initialState: false)
        runOnTapThreadAndWait { [self] in
            installed.withLock { $0 = installOnTapThread() }
        }
        return installed.withLock { $0 }
    }

    func uninstall() {
        runOnTapThreadAndWait { [self] in uninstallOnTapThread() }
    }

    private func runOnTapThreadAndWait(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        let done = DispatchSemaphore(value: 0)
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue) {
            block()
            done.signal()
        }
        CFRunLoopWakeUp(runLoop)
        done.wait()
    }

    private func installOnTapThread() -> Bool {
        if tap != nil { return true }
        let mask = CGEventMask(1) << CGEventType.keyDown.rawValue
        guard let tap = CGEvent.tapCreate(
            tap: .cgSessionEventTap, place: .headInsertEventTap, options: .defaultTap,
            eventsOfInterest: mask, callback: shortcutTapCallback, userInfo: Unmanaged.passUnretained(self).toOpaque()
        ) else {
            Log.keyboard.error("event tap creation failed")
            return false
        }
        let source = CFMachPortCreateRunLoopSource(kCFAllocatorDefault, tap, 0)
        CFRunLoopAddSource(runLoop, source, .commonModes)
        CGEvent.tapEnable(tap: tap, enable: true)
        self.tap = tap
        self.source = source
        recentTimeouts = []
        Log.keyboard.info("event tap installed")
        return true
    }

    private func uninstallOnTapThread() {
        guard let tap else { return }
        CGEvent.tapEnable(tap: tap, enable: false)
        if let source { CFRunLoopRemoveSource(runLoop, source, .commonModes) }
        CFMachPortInvalidate(tap)
        self.tap = nil
        self.source = nil
        Log.keyboard.info("event tap removed")
    }

    // MARK: Callback (tap thread)

    fileprivate func handle(type: CGEventType, event: CGEvent) -> Unmanaged<CGEvent>? {
        switch type {
        case .keyDown:
            break
        case .tapDisabledByTimeout:
            handleTimeout()
            return Unmanaged.passUnretained(event)
        case .tapDisabledByUserInput:
            // e.g. Secure Input. Re-arm, but never try to see around it.
            if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
            Metrics.shared.recordTapEvent(.userInputDisable)
            Log.keyboard.notice("event tap disabled by user input; re-enabled")
            return Unmanaged.passUnretained(event)
        default:
            return Unmanaged.passUnretained(event)
        }

        let received = Clock.now()
        let keyCode = event.getIntegerValueField(.keyboardEventKeycode)
        let modifiers = Modifiers(event.flags)
        let isAutorepeat = event.getIntegerValueField(.keyboardEventAutorepeat) != 0
        let decision = state.withLock { state in
            InputGate.decide(keyCode: keyCode, modifiers: modifiers, isAutorepeat: isAutorepeat, now: received, state: &state)
        }
        let result: Unmanaged<CGEvent>?
        switch decision {
        case .passThrough:
            result = Unmanaged.passUnretained(event)
        case .swallow:
            result = nil
        case .switchWindow(let direction, let pid):
            onSwitch?(direction, pid, received)
            result = nil
        }
        Metrics.shared.recordKeyDown(
            decision: decision,
            isShortcut: decision == .passThrough && ShortcutMatcher.direction(keyCode: keyCode, modifiers: modifiers) != nil,
            callbackNanos: Clock.now() &- received,
            deliveryNanos: deliveryNanos(eventTimestamp: event.timestamp, received: received)
        )
        return result
    }

    /// Key press → this callback. `nil` when the timestamp is missing (synthesized events) or implausible.
    ///
    /// Read as nanoseconds on the `Clock.now()` timeline, as documented. Reading them as mach ticks
    /// made every real key press implausible on macOS 27 (Apple silicon).
    private func deliveryNanos(eventTimestamp: CGEventTimestamp, received: UInt64) -> UInt64? {
        guard eventTimestamp != 0 else { return nil }
        guard eventTimestamp <= received, received - eventTimestamp < 10_000_000_000 else {
            if !loggedImplausibleTimestamp {
                loggedImplausibleTimestamp = true
                Log.keyboard.notice("implausible event timestamp \(eventTimestamp) at \(received) (logged once)")
            }
            return nil
        }
        return received - eventTimestamp
    }

    private func handleTimeout() {
        Metrics.shared.recordTapEvent(.timeout)
        let now = Clock.now()
        recentTimeouts = recentTimeouts.filter { now &- $0 < Self.timeoutWindowNanos } + [now]
        if recentTimeouts.count >= Self.maxTimeoutsInWindow {
            Log.keyboard.error("event tap timed out \(self.recentTimeouts.count) times in 10s; disabling")
            uninstallOnTapThread()
            onTapFailure?()
            return
        }
        if let tap { CGEvent.tapEnable(tap: tap, enable: true) }
        Log.keyboard.notice("event tap disabled by timeout; re-enabled")
    }
}

private func shortcutTapCallback(
    proxy: CGEventTapProxy, type: CGEventType, event: CGEvent, refcon: UnsafeMutableRawPointer?
) -> Unmanaged<CGEvent>? {
    guard let refcon else { return Unmanaged.passUnretained(event) }
    return Unmanaged<ShortcutInterceptor>.fromOpaque(refcon).takeUnretainedValue().handle(type: type, event: event)
}
