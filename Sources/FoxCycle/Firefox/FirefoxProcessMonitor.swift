import AppKit

/// Tracks running Firefox app processes and whether one of them is frontmost, via NSWorkspace.
/// Content processes (`plugin-container`) have their own bundle ID and never show up here.
@MainActor
final class FirefoxProcessMonitor {
    nonisolated static let bundleIdentifier = "org.mozilla.firefox"

    var onProcessesChanged: (([FirefoxProcess]) -> Void)?
    var onFrontmostChanged: ((pid_t?) -> Void)?
    /// A Firefox process was hidden (⌘H) or unhidden; its windows' availability changed.
    var onVisibilityChanged: ((pid_t) -> Void)?

    private(set) var processes: [FirefoxProcess] = []
    private var observers: [NSObjectProtocol] = []

    func start() {
        guard observers.isEmpty else { return }
        let workspace = NSWorkspace.shared
        observe(NSWorkspace.didLaunchApplicationNotification) { [weak self] app in
            if app.isFirefox { self?.refreshProcesses() }
        }
        observe(NSWorkspace.didTerminateApplicationNotification) { [weak self] app in
            if app.isFirefox { self?.refreshProcesses() }
        }
        observe(NSWorkspace.didActivateApplicationNotification) { [weak self] app in
            self?.onFrontmostChanged?(app.isFirefox ? app.pid : nil)
        }
        for name in [NSWorkspace.didHideApplicationNotification, NSWorkspace.didUnhideApplicationNotification] {
            observe(name) { [weak self] app in
                if app.isFirefox { self?.onVisibilityChanged?(app.pid) }
            }
        }

        refreshProcesses()
        let front = workspace.frontmostApplication
        onFrontmostChanged?(front?.bundleIdentifier == Self.bundleIdentifier ? front?.processIdentifier : nil)
    }

    func stop() {
        observers.forEach(NSWorkspace.shared.notificationCenter.removeObserver)
        observers.removeAll()
        processes = []
        onFrontmostChanged?(nil)
    }

    private func refreshProcesses() {
        let current = NSRunningApplication.runningApplications(withBundleIdentifier: Self.bundleIdentifier)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .sorted {
                ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier)
            }
            .map { FirefoxProcess(pid: $0.processIdentifier, launchDate: $0.launchDate) }
        guard current != processes else { return }
        processes = current
        Log.app.info("Firefox processes: \(current.map { String($0.pid) }.joined(separator: ", "), privacy: .public)")
        onProcessesChanged?(current)
    }

    private func observe(_ name: Notification.Name, _ handler: @escaping @MainActor (AppInfo) -> Void) {
        let token = NSWorkspace.shared.notificationCenter.addObserver(forName: name, object: nil, queue: .main) { note in
            guard let app = note.userInfo?[NSWorkspace.applicationUserInfoKey] as? NSRunningApplication else { return }
            let info = AppInfo(pid: app.processIdentifier, bundleIdentifier: app.bundleIdentifier)
            MainActor.assumeIsolated { handler(info) }
        }
        observers.append(token)
    }

    /// Sendable extract of NSRunningApplication for crossing into the main-actor handler.
    struct AppInfo: Sendable {
        let pid: pid_t
        let bundleIdentifier: String?
        var isFirefox: Bool { bundleIdentifier == FirefoxProcessMonitor.bundleIdentifier }
    }
}
