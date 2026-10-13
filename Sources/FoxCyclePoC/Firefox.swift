import AppKit
import ApplicationServices

let firefoxBundleID = "org.mozilla.firefox"

/// One running Firefox app process (= one profile). Identity is (pid, launchDate) so a reused
/// PID after a profile restart is treated as a new generation.
final class FirefoxInstance {
    let label: String
    let app: NSRunningApplication
    let pid: pid_t
    let launchDate: Date?
    let axApp: AXUIElement
    private var windowCounter = 0

    init(label: String, app: NSRunningApplication) {
        self.label = label
        self.app = app
        self.pid = app.processIdentifier
        self.launchDate = app.launchDate
        self.axApp = AXUIElementCreateApplication(app.processIdentifier)
    }

    func matches(_ other: NSRunningApplication) -> Bool {
        pid == other.processIdentifier && launchDate == other.launchDate
    }

    func nextWindowLabel() -> String {
        defer { windowCounter += 1 }
        return "\(label)W\(windowCounter)"
    }
}

struct WindowInfo {
    let element: AXUIElement
    let role: String?
    let subrole: String?
    let minimized: Bool
    let isMain: Bool
    let frame: CGRect?

    var isEligible: Bool {
        role == kAXWindowRole && subrole == kAXStandardWindowSubrole && !minimized && frame != nil
    }
}

struct RingWindow {
    let label: String
    let instance: FirefoxInstance
    let element: AXUIElement
    var frame: CGRect

    func isSame(_ other: RingWindow) -> Bool {
        instance === other.instance && CFEqual(element, other.element)
    }
}

enum Firefox {
    static func runningApps() -> [NSRunningApplication] {
        NSRunningApplication.runningApplications(withBundleIdentifier: firefoxBundleID)
            .filter { !$0.isTerminated && $0.activationPolicy == .regular }
            .sorted {
                ($0.launchDate ?? .distantPast, $0.processIdentifier) < ($1.launchDate ?? .distantPast, $1.processIdentifier)
            }
    }

    static func windows(of axApp: AXUIElement) -> [WindowInfo] {
        AX.elements(axApp, kAXWindowsAttribute).map { element in
            WindowInfo(
                element: element,
                role: AX.string(element, kAXRoleAttribute),
                subrole: AX.string(element, kAXSubroleAttribute),
                minimized: AX.bool(element, kAXMinimizedAttribute) ?? false,
                isMain: AX.bool(element, kAXMainAttribute) ?? false,
                frame: AX.frame(element)
            )
        }
    }
}

/// PoC version of the window registry + stable ring. Not thread-safe: confine to one queue.
final class WindowCatalog {
    private(set) var instances: [FirefoxInstance] = []
    private(set) var ring: [RingWindow] = []
    private var instanceCounter = 0

    /// Full rescan. Survivors keep their ring position, vanished windows are dropped,
    /// newly discovered windows are appended at the end.
    func refresh() {
        instances = Firefox.runningApps().map { app in
            if let existing = instances.first(where: { $0.matches(app) }) { return existing }
            defer { instanceCounter += 1 }
            return FirefoxInstance(label: "P\(instanceCounter)", app: app)
        }

        var found: [(FirefoxInstance, WindowInfo)] = []
        for instance in instances where !instance.app.isHidden {
            for window in Firefox.windows(of: instance.axApp) where window.isEligible {
                found.append((instance, window))
            }
        }

        var next: [RingWindow] = ring.compactMap { entry in
            guard let match = found.first(where: { $0.0 === entry.instance && CFEqual($0.1.element, entry.element) })
            else { return nil }
            var updated = entry
            updated.frame = match.1.frame!
            return updated
        }
        for (instance, window) in found
        where !next.contains(where: { $0.instance === instance && CFEqual($0.element, window.element) }) {
            next.append(RingWindow(label: instance.nextWindowLabel(), instance: instance, element: window.element, frame: window.frame!))
        }
        ring = next
    }

    func remove(_ window: RingWindow) {
        ring.removeAll { $0.isSame(window) }
    }

    func index(of window: RingWindow) -> Int? {
        ring.firstIndex { $0.isSame(window) }
    }

    func instance(pid: pid_t) -> FirefoxInstance? {
        instances.first { $0.pid == pid }
    }

    /// Ring index of the focused window of the given Firefox process, if it is in the ring.
    func indexOfFocusedWindow(pid: pid_t) -> Int? {
        guard let instance = instance(pid: pid),
              let focused = AX.element(instance.axApp, kAXFocusedWindowAttribute)
        else { return nil }
        return ring.firstIndex { $0.instance === instance && CFEqual($0.element, focused) }
    }

    func label(forScreenWindow window: ScreenWindow) -> String? {
        ring.first { $0.instance.pid == window.pid && $0.frame.approximatelyEquals(window.bounds) }?.label
    }

    var ringDescription: String {
        ring.isEmpty ? "(empty)" : ring.map(\.label).joined(separator: " → ")
    }
}
