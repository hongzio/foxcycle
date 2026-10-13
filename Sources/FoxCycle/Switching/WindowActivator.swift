import ApplicationServices
import FoxCycleCore

enum WindowActivator {
    /// Phase 0 strategy s5: mark main → raise → make the process frontmost,
    /// all through Accessibility. Avoids `NSRunningApplication.activate`, whose success flag is
    /// meaningless and which is subject to macOS 14+ cooperative-activation rules.
    static func activate(_ handle: WindowHandle) -> ActivationOutcome {
        let steps: [(name: String, call: () -> AXError)] = [
            ("main", { AX.set(handle.window, kAXMainAttribute, true) }),
            ("raise", { AX.perform(handle.window, kAXRaiseAction) }),
            ("frontmost", { AX.set(handle.app, kAXFrontmostAttribute, true) }),
        ]
        for step in steps {
            let error = step.call()
            switch error {
            case .success:
                continue
            case .invalidUIElement:
                Log.switching.info("\(handle.token, privacy: .public) gone (\(step.name, privacy: .public))")
                return .windowGone
            case .cannotComplete:
                // Messaging timeout: the profile is busy or hung. Stop here so input never stalls longer.
                Log.switching.error("pid \(handle.pid) unresponsive during \(step.name, privacy: .public)")
                return .unresponsive
            default:
                Log.switching.notice("\(step.name, privacy: .public) on \(handle.token, privacy: .public): \(error.name, privacy: .public)")
            }
        }
        return .activated
    }
}
