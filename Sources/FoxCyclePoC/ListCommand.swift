import AppKit
import ApplicationServices

/// `list`: dump what the PoC can see — processes, AX windows, the ring it would build,
/// and the window server's front-to-back order.
enum ListCommand {
    static func run(_ options: Options) {
        let catalog = WindowCatalog()
        catalog.refresh()

        print("Environment: \(EnvironmentInfo.describe(instances: catalog.instances))")
        print("")
        print("Firefox processes (\(catalog.instances.count)):")
        for instance in catalog.instances {
            let launched = instance.launchDate.map { timeFormatter.string(from: $0) } ?? "?"
            print("  \(instance.label)  pid \(instance.pid)  launched \(launched)"
                + "  active \(instance.app.isActive ? "yes" : "no")  hidden \(instance.app.isHidden ? "yes" : "no")")
            for window in Firefox.windows(of: instance.axApp) {
                let ringLabel = catalog.ring.first { $0.instance === instance && CFEqual($0.element, window.element) }?.label
                print("      \((ringLabel ?? "-").padding(toLength: 6, withPad: " ", startingAt: 0))"
                    + " \(window.role ?? "?")/\(window.subrole ?? "?")"
                    + "  min \(window.minimized ? "yes" : "no")  main \(window.isMain ? "yes" : "no")"
                    + "  frame \(window.frame?.compact ?? "?")"
                    + (window.isEligible ? "" : "  (not eligible)"))
            }
        }

        print("")
        print("Ring (\(catalog.ring.count)): \(catalog.ringDescription)")
        if let pid = AX.focusedApplicationPid() {
            let focused = catalog.indexOfFocusedWindow(pid: pid).map { catalog.ring[$0].label } ?? "not a ring window"
            print("Focused (AX): pid \(pid) → \(focused)")
        }

        let limit = options.int("top", default: 12)
        print("")
        print("Screen order (front→back, layer 0, top \(limit)):")
        for (index, window) in ScreenOrder.normalWindows().prefix(limit).enumerated() {
            let label = catalog.label(forScreenWindow: window).map { " = \($0)" } ?? ""
            print("  \(index + 1). \(window.owner) pid \(window.pid) \(window.bounds.compact)\(label)")
        }

        let warnings = ambiguityWarnings(catalog.ring)
        if !warnings.isEmpty {
            print("")
            warnings.forEach { print("WARNING: \($0)") }
        }
    }

    /// Top-window verification matches by (pid, frame); identical frames in one process are indistinguishable.
    static func ambiguityWarnings(_ ring: [RingWindow]) -> [String] {
        var warnings: [String] = []
        for (i, a) in ring.enumerated() {
            for b in ring[(i + 1)...] where a.instance === b.instance && a.frame.approximatelyEquals(b.frame) {
                warnings.append("\(a.label) and \(b.label) share the same frame; move one so screen verification can tell them apart.")
            }
        }
        return warnings
    }
}
