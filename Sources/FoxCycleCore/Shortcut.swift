import Foundation

public enum Direction: Sendable, Equatable {
    case forward
    case backward

    public var step: Int { self == .forward ? 1 : -1 }
}

/// The modifier keys that decide whether a grave keypress is ours. Caps Lock, Fn and
/// device-specific bits are deliberately not represented.
public struct Modifiers: OptionSet, Sendable, Hashable {
    public let rawValue: UInt8
    public init(rawValue: UInt8) { self.rawValue = rawValue }

    public static let command = Modifiers(rawValue: 1 << 0)
    public static let shift = Modifiers(rawValue: 1 << 1)
    public static let option = Modifiers(rawValue: 1 << 2)
    public static let control = Modifiers(rawValue: 1 << 3)
}

public enum ShortcutMatcher {
    /// kVK_ANSI_Grave: the physical key left of "1" on ANSI keyboards. Matching the keycode rather
    /// than the produced character keeps it stable across input sources (e.g. Korean 2-set).
    public static let graveKeyCode: Int64 = 50

    /// ⌘` → forward, ⌘⇧` → backward. Any extra ⌥ / ⌃ means "not ours".
    public static func direction(keyCode: Int64, modifiers: Modifiers) -> Direction? {
        guard keyCode == graveKeyCode else { return nil }
        switch modifiers {
        case [.command]: return .forward
        case [.command, .shift]: return .backward
        default: return nil
        }
    }
}

/// What the event tap knows without touching Accessibility. Kept behind a lock and read on every keyDown.
public struct InterceptState: Sendable, Equatable {
    public var isEnabled = false
    public var firefoxFrontmostPid: pid_t?
    public var eligibleWindowCount = 0
    /// Set when a switch is accepted; cleared once that switch's activation calls have returned.
    public var switchStartedAt: UInt64?

    public init() {}
}

public enum KeyDecision: Sendable, Equatable {
    public enum SwallowReason: Sendable, Equatable {
        /// The key is being held down.
        case autorepeat
        /// The previous switch is still landing.
        case inFlight
    }

    /// Not ours: hand the event to the system / app untouched.
    case passThrough
    /// Ours, but nothing to do.
    case swallow(SwallowReason)
    case switchWindow(Direction, firefoxPid: pid_t)
}

public enum InputGate {
    /// Safety valve so a lost "switch finished" signal can never lock the shortcut out.
    public static let inFlightTimeoutNanos: UInt64 = 2_000_000_000

    /// Decides what to do with a keyDown. When it starts a switch it also marks the switch in flight,
    /// so call it under the same lock that guards `state`.
    public static func decide(
        keyCode: Int64, modifiers: Modifiers, isAutorepeat: Bool, now: UInt64, state: inout InterceptState
    ) -> KeyDecision {
        guard let direction = ShortcutMatcher.direction(keyCode: keyCode, modifiers: modifiers) else { return .passThrough }
        guard state.isEnabled, let pid = state.firefoxFrontmostPid, state.eligibleWindowCount >= 2 else {
            return .passThrough
        }
        // Holding the key switches once; presses that arrive while a switch is landing are dropped.
        if isAutorepeat { return .swallow(.autorepeat) }
        if let started = state.switchStartedAt, now &- started < inFlightTimeoutNanos { return .swallow(.inFlight) }
        state.switchStartedAt = now
        return .switchWindow(direction, firefoxPid: pid)
    }
}
