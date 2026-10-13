import ApplicationServices
import Foundation
import FoxCycleCore
import os

/// Owns the window list of every Firefox process and the stable ring built from it.
///
/// All mutable state lives on one dedicated thread, whose run loop also hosts the AXObserver
/// sources. AX notifications are only triggers: the affected process is rescanned (debounced) and
/// the scan is the source of truth. Other threads read the latest published `Snapshot` or post work.
final class WindowRegistry: @unchecked Sendable {
    struct Snapshot: Sendable {
        var ring = WindowRing<WindowToken>()
        var handles: [WindowToken: WindowHandle] = [:]

        var eligibleCount: Int { ring.availableCount }

        func token(of window: AXUIElement, pid: pid_t) -> WindowToken? {
            handles.values.first { $0.pid == pid && CFEqual($0.window, window) }?.token
        }

        var summary: String {
            ring.entries.map { entry in
                let pid = handles[entry.id].map { String($0.pid) } ?? "?"
                return "\(entry.id)@\(pid)" + (entry.isAvailable ? "" : "(hidden)")
            }.joined(separator: " → ")
        }
    }

    static let rescanDebounce: CFTimeInterval = 0.05
    /// A freshly created window may not report its final role/subrole yet; look again after this.
    static let newWindowFollowUp: CFTimeInterval = 0.5
    static let safetyRescanInterval: CFTimeInterval = 10
    /// The safety rescan is skipped if a switch happened this recently ("non-shortcut moments only").
    static let quietPeriodNanos: UInt64 = 1_000_000_000
    /// Dedicated retries for registrations that timed out (typically a process still launching).
    /// After these, retries only ride along with rescans, the safety rescan at the latest.
    static let registrationRetryDelays: [CFTimeInterval] = [1, 2, 4]

    static let appNotifications = [
        kAXWindowCreatedNotification, kAXApplicationHiddenNotification, kAXApplicationShownNotification,
    ]
    static let windowNotifications = [
        kAXUIElementDestroyedNotification, kAXWindowMiniaturizedNotification, kAXWindowDeminiaturizedNotification,
    ]

    /// Called on the registry thread whenever the ring changes. Set before `start()`.
    var onSnapshotChange: (@Sendable (Snapshot) -> Void)?

    private let screenLock: ScreenLockMonitor
    private let published = OSAllocatedUnfairLock(initialState: Snapshot())
    private let lastSwitchActivity = OSAllocatedUnfairLock<UInt64>(initialState: 0)

    // Registry-thread state. `runLoop` is written once before `start()` returns.
    private var runLoop: CFRunLoop?
    private var processes: [FirefoxProcess] = []
    private var entries: [pid_t: ProcessEntry] = [:]
    private var ring = WindowRing<WindowToken>()
    private var nextToken: UInt64 = 1
    private var pendingRescan: Set<pid_t> = []
    private var rescanTimer: CFRunLoopTimer?

    var snapshot: Snapshot { published.withLock { $0 } }

    init(screenLock: ScreenLockMonitor) {
        self.screenLock = screenLock
    }

    func start() {
        guard runLoop == nil else { return }
        let ready = DispatchSemaphore(value: 0)
        let thread = Thread { [self] in
            let current = CFRunLoopGetCurrent()!
            runLoop = current
            let safety = CFRunLoopTimerCreateWithHandler(
                nil, CFAbsoluteTimeGetCurrent() + Self.safetyRescanInterval, Self.safetyRescanInterval, 0, 0
            ) { [self] _ in
                guard Clock.now() &- lastSwitchActivity.withLock({ $0 }) > Self.quietPeriodNanos else { return }
                scheduleRescan(Set(entries.keys))
            }
            CFRunLoopAddTimer(current, safety, .defaultMode)
            ready.signal()
            CFRunLoopRun()
        }
        thread.name = "com.hongzio.foxcycle.registry"
        thread.qualityOfService = .userInitiated
        thread.start()
        ready.wait()
    }

    // MARK: Any thread

    func setProcesses(_ processes: [FirefoxProcess]) {
        perform { [self] in reconcile(processes) }
    }

    func requestRescan(pid: pid_t) {
        perform { [self] in scheduleRescan([pid]) }
    }

    /// Drop a window right away (activation found it gone) instead of waiting for the next scan.
    func removeWindow(_ token: WindowToken) {
        perform { [self] in
            for entry in entries.values {
                entry.windows.removeAll { $0.token == token }
            }
            publish()
        }
    }

    func noteSwitchActivity() {
        lastSwitchActivity.withLock { $0 = Clock.now() }
    }

    private func perform(_ block: @escaping @Sendable () -> Void) {
        guard let runLoop else { return }
        CFRunLoopPerformBlock(runLoop, CFRunLoopMode.defaultMode.rawValue, block)
        CFRunLoopWakeUp(runLoop)
    }

    // MARK: Registry thread

    fileprivate func observerFired(pid: pid_t, notification: String) {
        Log.registry.debug("AX \(notification, privacy: .public) from pid \(pid)")
        scheduleRescan([pid])
        if notification == kAXWindowCreatedNotification, let runLoop {
            let followUp = CFRunLoopTimerCreateWithHandler(
                nil, CFAbsoluteTimeGetCurrent() + Self.newWindowFollowUp, 0, 0, 0
            ) { [self] _ in scheduleRescan([pid]) }
            CFRunLoopAddTimer(runLoop, followUp, .defaultMode)
        }
    }

    private func reconcile(_ next: [FirefoxProcess]) {
        processes = next
        for (pid, entry) in entries where !next.contains(entry.process) {
            detach(entry)
            entries[pid] = nil
        }
        for process in next where entries[process.pid]?.process != process {
            let entry = ProcessEntry(process: process, registry: self)
            entries[process.pid] = entry
            attach(entry)
            scan(entry)
        }
        publish()
    }

    private func scheduleRescan(_ pids: Set<pid_t>) {
        pendingRescan.formUnion(pids)
        guard rescanTimer == nil, let runLoop else { return }
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + Self.rescanDebounce, 0, 0, 0) { [self] _ in
            rescanTimer = nil
            let due = pendingRescan
            pendingRescan = []
            let start = Clock.now()
            for pid in due {
                if let entry = entries[pid] { scan(entry) }
            }
            Log.registry.debug("rescanned \(due.count) process(es) in \(Clock.ms(since: start), format: .fixed(precision: 1))ms")
            publish()
        }
        rescanTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func attach(_ entry: ProcessEntry) {
        var observer: AXObserver?
        let error = AXObserverCreate(entry.process.pid, registryObserverCallback, &observer)
        guard error == .success, let observer, let runLoop else {
            Log.registry.error("AXObserverCreate failed for pid \(entry.process.pid): \(error.name, privacy: .public)")
            return
        }
        entry.observer = observer
        subscribe(Self.appNotifications.map { Subscription(name: $0, window: nil) }, of: entry)
        CFRunLoopAddSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
    }

    private func detach(_ entry: ProcessEntry) {
        if let observer = entry.observer, let runLoop {
            CFRunLoopRemoveSource(runLoop, AXObserverGetRunLoopSource(observer), .defaultMode)
        }
        if let timer = entry.retryTimer { CFRunLoopTimerInvalidate(timer) }
        entry.retryTimer = nil
        entry.observer = nil
    }

    private enum Registration { case registered, timedOut, failed }

    private func addNotification(_ name: String, to element: AXUIElement, of entry: ProcessEntry) -> Registration {
        guard let observer = entry.observer else { return .failed }
        let refcon = Unmanaged.passUnretained(entry.context).toOpaque()
        let error = AXObserverAddNotification(observer, element, name as CFString, refcon)
        switch error {
        case .success, .notificationAlreadyRegistered:
            return .registered
        case .cannotComplete:
            Log.registry.debug("pid \(entry.process.pid) cannot observe \(name, privacy: .public) yet: cannotComplete")
            return .timedOut
        default:
            Log.registry.debug("pid \(entry.process.pid) cannot observe \(name, privacy: .public): \(error.name, privacy: .public)")
            return .failed
        }
    }

    /// Registers `subscriptions` in order and returns whether any of them registered.
    /// The first timeout ends the pass, because a busy process would time out the rest too, each costing
    /// a full AX timeout on this thread. That subscription and the ones after it are kept for a retry.
    @discardableResult
    private func subscribe(_ subscriptions: [Subscription], of entry: ProcessEntry) -> Bool {
        var registered = false
        for (index, subscription) in subscriptions.enumerated() {
            let element: AXUIElement
            if let token = subscription.window {
                // Closed in the meantime: nothing left to observe.
                guard let handle = entry.windows.first(where: { $0.token == token }) else { continue }
                element = handle.window
            } else {
                element = entry.app
            }
            switch addNotification(subscription.name, to: element, of: entry) {
            case .registered:
                registered = true
            case .failed:
                break
            case .timedOut:
                entry.pending += subscriptions[index...]
                return registered
            }
        }
        return registered
    }

    /// Backed-off retries for timed-out registrations. Each one is just a rescan, and `scan` retries
    /// only when the process answered its window-list call, so a hung process costs one AX timeout per
    /// attempt. When the attempts are used up, retries wait for the next rescan.
    private func scheduleRegistrationRetry(_ entry: ProcessEntry) {
        guard !entry.pending.isEmpty else {
            entry.retryCount = 0
            return
        }
        guard entry.retryTimer == nil, entry.retryCount < Self.registrationRetryDelays.count, let runLoop else { return }
        let delay = Self.registrationRetryDelays[entry.retryCount]
        entry.retryCount += 1
        Log.registry.debug(
            "pid \(entry.process.pid) \(entry.pending.count) registration(s) pending; retry \(entry.retryCount) in \(delay, format: .fixed(precision: 0))s"
        )
        let timer = CFRunLoopTimerCreateWithHandler(nil, CFAbsoluteTimeGetCurrent() + delay, 0, 0, 0) { [self, weak entry] _ in
            guard let entry else { return }
            entry.retryTimer = nil
            guard entries[entry.process.pid] === entry, !entry.pending.isEmpty else { return }
            scheduleRescan([entry.process.pid])
        }
        entry.retryTimer = timer
        CFRunLoopAddTimer(runLoop, timer, .defaultMode)
    }

    private func scan(_ entry: ProcessEntry) {
        defer { scheduleRegistrationRetry(entry) }
        // While the screen is locked, Firefox lists a stand-in AXApplication element instead of its
        // windows, and the window elements report invalidUIElement. The same elements are back after
        // unlocking, so nothing read now may count as "windows closed".
        let lockState = screenLock.state
        if lockState == .locked {
            Log.registry.debug("pid \(entry.process.pid) not scanned while the screen is locked")
            return
        }
        // Neither may a failed call (timeout, busy app).
        guard let elements = AX.windows(of: entry.app) else {
            Log.registry.notice("pid \(entry.process.pid) window list unavailable; keeping previous state")
            return
        }
        if case .recentlyUnlocked(let nanosAgo) = lockState,
           entry.windows.contains(where: { known in !elements.contains { CFEqual($0, known.window) } }) {
            Log.registry.notice(
                "pid \(entry.process.pid) misses known windows \(Double(nanosAgo) / 1e6, format: .fixed(precision: 0))ms after unlock; keeping previous state"
            )
            return
        }
        let appHidden = AX.bool(entry.app, kAXHiddenAttribute) ?? false
        var windows: [WindowHandle] = []
        var available: [WindowToken: Bool] = [:]
        var discovered: [WindowToken] = []
        for element in elements {
            let handle: WindowHandle
            if let known = entry.windows.first(where: { CFEqual($0.window, element) }) {
                handle = known
            } else {
                guard AX.string(element, kAXRoleAttribute) == kAXWindowRole,
                      AX.string(element, kAXSubroleAttribute) == kAXStandardWindowSubrole
                else { continue }
                handle = WindowHandle(
                    token: WindowToken(rawValue: nextToken), pid: entry.process.pid, app: entry.app, window: element
                )
                nextToken += 1
                discovered.append(handle.token)
            }
            let wasAvailable = entry.available[handle.token] ?? true
            let minimized = AX.bool(element, kAXMinimizedAttribute) ?? !wasAvailable
            windows.append(handle)
            available[handle.token] = !minimized && !appHidden
        }
        entry.windows = windows
        entry.available = available

        // The process is answering: retry earlier timeouts first, then subscribe to the new windows.
        let retrying = entry.pending
        entry.pending = []
        let recovered = subscribe(retrying, of: entry)
        let fresh = discovered.flatMap { token in Self.windowNotifications.map { Subscription(name: $0, window: token) } }
        if entry.pending.isEmpty {
            subscribe(fresh, of: entry)
        } else {
            entry.pending += fresh
        }
        if recovered {
            // Catch up on whatever changed while we were not listening.
            Log.registry.info("pid \(entry.process.pid) notification registration recovered; rescanning")
            scheduleRescan([entry.process.pid])
        }
    }

    private func publish() {
        var present: [WindowRing<WindowToken>.Entry] = []
        var handles: [WindowToken: WindowHandle] = [:]
        for process in processes {
            guard let entry = entries[process.pid] else { continue }
            for handle in entry.windows {
                present.append(.init(id: handle.token, isAvailable: entry.available[handle.token] ?? true))
                handles[handle.token] = handle
            }
        }
        ring.sync(present: present)
        let snapshot = Snapshot(ring: ring, handles: handles)
        let changed = published.withLock { current -> Bool in
            let changed = current.ring != snapshot.ring
            current = snapshot
            return changed
        }
        guard changed else { return }
        Log.registry.info("ring \(snapshot.ring.availableCount)/\(snapshot.ring.entries.count): \(snapshot.summary, privacy: .public)")
        onSnapshotChange?(snapshot)
    }
}

private final class ProcessEntry {
    let process: FirefoxProcess
    let app: AXUIElement
    let context: ObserverContext
    var observer: AXObserver?
    /// Standard windows in discovery order.
    var windows: [WindowHandle] = []
    /// false = minimized, or the whole app is hidden.
    var available: [WindowToken: Bool] = [:]
    /// Registrations that timed out, retried by the next successful scan.
    var pending: [Subscription] = []
    var retryTimer: CFRunLoopTimer?
    /// Dedicated retries spent since `pending` was last empty.
    var retryCount = 0

    init(process: FirefoxProcess, registry: WindowRegistry) {
        self.process = process
        self.app = AXUIElementCreateApplication(process.pid)
        self.context = ObserverContext(pid: process.pid, registry: registry)
    }
}

/// An AX notification to register on the app element (`window == nil`) or on one of its windows.
private struct Subscription {
    let name: String
    let window: WindowToken?
}

/// AX observer refcon. Owned by its ProcessEntry, which outlives the observer's run-loop source.
private final class ObserverContext {
    let pid: pid_t
    weak var registry: WindowRegistry?

    init(pid: pid_t, registry: WindowRegistry) {
        self.pid = pid
        self.registry = registry
    }
}

private func registryObserverCallback(
    _ observer: AXObserver, _ element: AXUIElement, _ notification: CFString, _ refcon: UnsafeMutableRawPointer?
) {
    guard let refcon else { return }
    let context = Unmanaged<ObserverContext>.fromOpaque(refcon).takeUnretainedValue()
    context.registry?.observerFired(pid: context.pid, notification: notification as String)
}
