import AppKit
import FoxCycleCore

/// Wires the components together and keeps them in line with (Enabled, permission, tap health).
@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private static let enabledKey = "enabled"
    private static let metricsInterval: TimeInterval = 30 * 60

    private let defaults = UserDefaults.standard
    private let permission = PermissionController()
    private let loginItem = LoginItemController()
    private let processMonitor = FirefoxProcessMonitor()
    private let registry = WindowRegistry(screenLock: ScreenLockMonitor())
    private let interceptor = ShortcutInterceptor()
    private let statusBar = StatusBarController()
    private var coordinator: SwitchCoordinator?
    private var metricsTimer: Timer?
    #if FOXCYCLE_BENCH
    private var benchmark: Benchmark?
    #endif

    private var isRunning = false
    private var tapFailed = false
    private var isEnabled: Bool {
        get { defaults.bool(forKey: Self.enabledKey) }
        set { defaults.set(newValue, forKey: Self.enabledKey) }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        defaults.register(defaults: [Self.enabledKey: true])
        // Bounds how long any AX call can stall the switch or registry thread (Phase 0: 0.25s).
        AX.setGlobalTimeout(seconds: 0.25)

        let interceptor = interceptor
        let registry = registry
        let coordinator = SwitchCoordinator(registry: registry) { interceptor.switchFinished() }
        self.coordinator = coordinator

        registry.onSnapshotChange = { snapshot in interceptor.setEligibleWindowCount(snapshot.eligibleCount) }
        interceptor.onSwitch = { direction, pid, receivedAt in
            coordinator.requestSwitch(direction, firefoxPid: pid, receivedAt: receivedAt)
        }
        interceptor.onTapFailure = { [weak self] in
            Task { @MainActor in
                self?.tapFailed = true
                self?.apply()
            }
        }
        processMonitor.onProcessesChanged = { registry.setProcesses($0) }
        processMonitor.onFrontmostChanged = { interceptor.setFirefoxFrontmost($0) }
        processMonitor.onVisibilityChanged = { registry.requestRescan(pid: $0) }

        statusBar.status = { [unowned self] in
            StatusBarController.Status(
                isEnabled: isEnabled, isTrusted: permission.isTrusted, tapFailed: tapFailed,
                isRunning: isRunning, windowCount: registry.snapshot.eligibleCount, loginItem: loginItem.state
            )
        }
        statusBar.onToggleEnabled = { [unowned self] in
            isEnabled.toggle()
            apply()
        }
        statusBar.onToggleLoginItem = { [unowned self] in toggleLoginItem() }
        statusBar.onOpenSettings = { [unowned self] in permission.openSettings() }
        statusBar.onRetry = { [unowned self] in
            tapFailed = false
            apply()
        }
        permission.onChange = { [unowned self] _ in apply() }

        registry.start()
        interceptor.start()
        statusBar.install()
        permission.start()
        apply()
        Log.app.info("launched (login item: \(self.loginItem.state.rawValue, privacy: .public))")

        #if FOXCYCLE_BENCH
        if let plan = defaults.string(forKey: Benchmark.planKey) {
            // The bench reads the metrics itself; periodic reports would split its intervals.
            benchmark = Benchmark(registry: registry, interceptor: interceptor)
            benchmark?.start(plan: plan)
            return
        }
        #endif
        metricsTimer = Timer.scheduledTimer(withTimeInterval: Self.metricsInterval, repeats: true) { _ in
            Metrics.shared.logInterval("periodic")
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        interceptor.uninstall()
        Metrics.shared.logInterval("quit")
    }

    private func toggleLoginItem() {
        let state = loginItem.state
        if state == .needsApproval {
            loginItem.openSettings()
            return
        }
        do {
            try loginItem.setEnabled(state == .off)
        } catch {
            Log.app.error("login item change failed: \(error.localizedDescription, privacy: .public)")
            let alert = NSAlert()
            alert.messageText = "Couldn't change Start at Login"
            alert.informativeText = error.localizedDescription
            // An agent app has no window to come forward with; without this the alert opens behind.
            NSApp.activate()
            alert.runModal()
        }
    }

    /// Starts or stops monitoring + interception so that it runs only when enabled, permitted and healthy.
    /// When stopped, no event tap exists at all, so the system ⌘` is untouched.
    private func apply() {
        let shouldRun = isEnabled && permission.isTrusted && !tapFailed
        if shouldRun != isRunning {
            if shouldRun {
                processMonitor.start()
                interceptor.setEnabled(true)
                if interceptor.install() {
                    isRunning = true
                } else {
                    interceptor.setEnabled(false)
                    processMonitor.stop()
                    registry.setProcesses([])
                    tapFailed = true
                }
            } else {
                interceptor.uninstall()
                interceptor.setEnabled(false)
                processMonitor.stop()
                registry.setProcesses([])
                isRunning = false
            }
            Log.app.info("""
                running \(self.isRunning) (enabled \(self.isEnabled), trusted \(self.permission.isTrusted), \
                tap failed \(self.tapFailed))
                """)
        }
        statusBar.refresh()
    }
}
