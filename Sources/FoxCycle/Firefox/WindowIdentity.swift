import ApplicationServices
import Foundation

/// One running Firefox app process (= one profile). A PID can be reused after a profile restarts,
/// so the launch date is part of the identity.
struct FirefoxProcess: Hashable, Sendable {
    let pid: pid_t
    let launchDate: Date?
}

/// Session-scoped window identity, issued by the registry when a window is first seen.
/// Titles are never used: they change constantly and are private.
struct WindowToken: Hashable, Sendable, CustomStringConvertible {
    let rawValue: UInt64
    var description: String { "W\(rawValue)" }
}

/// Everything needed to activate one window.
///
/// `@unchecked Sendable`: AXUIElement references are immutable CF objects and the Accessibility API
/// may be called from any thread.
struct WindowHandle: @unchecked Sendable {
    let token: WindowToken
    let pid: pid_t
    let app: AXUIElement
    let window: AXUIElement
}
