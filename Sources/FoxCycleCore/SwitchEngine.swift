public enum ActivationOutcome: Sendable, Equatable {
    case activated
    /// The window no longer exists; try the next candidate.
    case windowGone
    /// The owning process did not answer in time; give up this switch rather than stall input.
    case unresponsive
}

public struct SwitchReport<ID: Hashable & Sendable>: Sendable, Equatable {
    public enum CurrentSource: Sendable, Equatable {
        /// Our own previous target, still within the trust window.
        case lastTarget
        /// The frontmost Firefox process's focused window, via Accessibility.
        case focused
        /// Neither was available; the ring was entered at its start (or end, going backward).
        case unknown
    }

    public enum Outcome: Sendable, Equatable {
        case activated(ID)
        case abandoned(ID)
        case noTarget
    }

    public let current: ID?
    public let currentSource: CurrentSource
    public let windowsGone: [ID]
    public let outcome: Outcome
}

/// Picks and activates the next window. Not thread-safe: drive it from one serial queue.
public struct SwitchEngine<ID: Hashable & Sendable>: Sendable {
    /// Right after a switch, Accessibility focus lags and AX calls into Firefox block while it handles
    /// the activation (measured 70–150ms in Phase 0). Within this window our own last target is
    /// trusted as "current" instead of asking AX.
    public let trustLastTargetNanos: UInt64
    public private(set) var lastTarget: ID?
    private var lastActivatedAt: UInt64?

    public init(trustLastTargetNanos: UInt64 = 750_000_000) {
        self.trustLastTargetNanos = trustLastTargetNanos
    }

    public mutating func performSwitch(
        direction: Direction,
        ring: WindowRing<ID>,
        now: () -> UInt64,
        focusedWindow: () -> ID?,
        activate: (ID) -> ActivationOutcome
    ) -> SwitchReport<ID> {
        let current: ID?
        let source: SwitchReport<ID>.CurrentSource
        if let lastTarget, let lastActivatedAt, now() &- lastActivatedAt < trustLastTargetNanos, ring.contains(lastTarget) {
            current = lastTarget
            source = .lastTarget
        } else if let focused = focusedWindow() {
            current = focused
            source = .focused
        } else {
            current = nil
            source = .unknown
        }

        var gone: [ID] = []
        for candidate in ring.candidates(after: current, direction: direction) {
            switch activate(candidate) {
            case .activated:
                lastTarget = candidate
                lastActivatedAt = now()
                return SwitchReport(current: current, currentSource: source, windowsGone: gone, outcome: .activated(candidate))
            case .windowGone:
                gone.append(candidate)
            case .unresponsive:
                return SwitchReport(current: current, currentSource: source, windowsGone: gone, outcome: .abandoned(candidate))
            }
        }
        return SwitchReport(current: current, currentSource: source, windowsGone: gone, outcome: .noTarget)
    }
}
