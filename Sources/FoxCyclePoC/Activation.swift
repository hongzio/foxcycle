import AppKit
import ApplicationServices

enum ActivationOp: String, CaseIterable {
    /// `NSRunningApplication.activate(options: [])` on the target profile's process.
    case activate
    /// `AXUIElementPerformAction(window, kAXRaiseAction)`.
    case raise
    /// `kAXMainAttribute = true` on the target window.
    case main
    /// `kAXFrontmostAttribute = true` on the target process's AX application element.
    case frontmost
}

struct ActivationStrategy {
    let name: String
    let ops: [ActivationOp]

    var summary: String { "\(name) [\(ops.map(\.rawValue).joined(separator: "→"))]" }

    static let presets: [ActivationStrategy] = [
        ActivationStrategy(name: "s1", ops: [.activate, .raise]),
        ActivationStrategy(name: "s2", ops: [.raise, .activate]),
        ActivationStrategy(name: "s3", ops: [.frontmost, .main, .raise]),
        ActivationStrategy(name: "s4", ops: [.frontmost, .main, .raise, .activate]),
        ActivationStrategy(name: "s5", ops: [.main, .raise, .frontmost]),
    ]

    /// Accepts `all`, a comma list of preset names (`s1,s3`), or a custom op chain (`raise+frontmost`).
    static func parse(_ spec: String) -> [ActivationStrategy]? {
        if spec == "all" { return presets }
        var result: [ActivationStrategy] = []
        for token in spec.split(separator: ",").map(String.init) {
            if let preset = presets.first(where: { $0.name == token }) {
                result.append(preset)
                continue
            }
            let ops = token.split(separator: "+").compactMap { ActivationOp(rawValue: String($0)) }
            guard !ops.isEmpty, ops.count == token.split(separator: "+").count else { return nil }
            result.append(ActivationStrategy(name: "custom", ops: ops))
        }
        return result.isEmpty ? nil : result
    }
}

struct OpOutcome {
    let op: ActivationOp
    let ok: Bool
    let detail: String

    var invalidatesTarget: Bool { detail == AXError.invalidUIElement.name }
    var compact: String { "\(op.rawValue)=\(detail)" }
}

enum Activator {
    /// Return values are recorded but never trusted as proof of success; see FocusProbe.
    static func apply(_ strategy: ActivationStrategy, to target: RingWindow) -> [OpOutcome] {
        strategy.ops.map { op in
            switch op {
            case .activate:
                let ok = target.instance.app.activate(options: [])
                return OpOutcome(op: op, ok: ok, detail: ok ? "true" : "false")
            case .raise:
                let error = AX.perform(target.element, kAXRaiseAction)
                return OpOutcome(op: op, ok: error == .success, detail: error.name)
            case .main:
                let error = AX.set(target.element, kAXMainAttribute, true)
                return OpOutcome(op: op, ok: error == .success, detail: error.name)
            case .frontmost:
                let error = AX.set(target.instance.axApp, kAXFrontmostAttribute, true)
                return OpOutcome(op: op, ok: error == .success, detail: error.name)
            }
        }
    }
}

/// Three independent views of "did the switch land": AX focused app, AX focused window of the
/// target process, and the window server's top-most normal window (what the user sees).
struct FocusObservation {
    let axAppPid: pid_t?
    let axWindowMatches: Bool
    let workspacePid: pid_t?
    let topWindow: ScreenWindow?
    let topMatches: Bool

    func axAppMatches(_ target: RingWindow) -> Bool { axAppPid == target.instance.pid }
    func workspaceMatches(_ target: RingWindow) -> Bool { workspacePid == target.instance.pid }
    func confirmed(_ target: RingWindow) -> Bool { axAppMatches(target) && axWindowMatches && topMatches }
}

enum FocusProbe {
    static func observe(_ target: RingWindow, ring: [RingWindow]) -> FocusObservation {
        let axAppPid = AX.focusedApplicationPid()
        let focusedWindow = AX.element(target.instance.axApp, kAXFocusedWindowAttribute)
        let frame = AX.frame(target.element) ?? target.frame
        let top = topWindow(ring: ring)
        return FocusObservation(
            axAppPid: axAppPid,
            axWindowMatches: focusedWindow.map { CFEqual($0, target.element) } ?? false,
            workspacePid: NSWorkspace.shared.frontmostApplication?.processIdentifier,
            topWindow: top,
            topMatches: top.map { $0.pid == target.instance.pid && $0.bounds.approximatelyEquals(frame) } ?? false
        )
    }

    /// Front-most normal window, skipping Firefox-owned windows that are not ring members
    /// (popovers, PiP, panels): those ride along with their parent window rather than obscure it.
    /// Windows of any other app still count as obstruction.
    static func topWindow(ring: [RingWindow]) -> ScreenWindow? {
        let firefoxPids = Set(ring.map(\.instance.pid))
        return ScreenOrder.normalWindows().first { window in
            !firefoxPids.contains(window.pid)
                || ring.contains { $0.instance.pid == window.pid && $0.frame.approximatelyEquals(window.bounds) }
        }
    }
}
