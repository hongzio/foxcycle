/// Stable cycling order across every Firefox profile.
///
/// Order changes only when windows are added (appended) or closed (removed). Focus changes never
/// reorder, and unavailable windows (minimized, or their app hidden) keep their slot and are
/// merely skipped while cycling.
public struct WindowRing<ID: Hashable & Sendable>: Sendable, Equatable {
    public struct Entry: Sendable, Equatable {
        public let id: ID
        public var isAvailable: Bool

        public init(id: ID, isAvailable: Bool) {
            self.id = id
            self.isAvailable = isAvailable
        }
    }

    public private(set) var entries: [Entry] = []

    public init() {}

    public var ids: [ID] { entries.map(\.id) }
    public var availableCount: Int { entries.lazy.filter(\.isAvailable).count }

    public func contains(_ id: ID) -> Bool {
        entries.contains { $0.id == id }
    }

    /// Reconciles with the windows that exist right now, given in discovery order.
    /// Survivors keep their slot (whatever their order in `present`) and take the new availability;
    /// vanished windows are dropped; new ones are appended in `present` order.
    public mutating func sync(present: [Entry]) {
        let availability = Dictionary(present.map { ($0.id, $0.isAvailable) }, uniquingKeysWith: { first, _ in first })
        var next: [Entry] = entries.compactMap { entry in
            availability[entry.id].map { Entry(id: entry.id, isAvailable: $0) }
        }
        var known = Set(next.map(\.id))
        for entry in present where known.insert(entry.id).inserted {
            next.append(entry)
        }
        entries = next
    }

    public mutating func remove(_ id: ID) {
        entries.removeAll { $0.id == id }
    }

    /// Available windows in visiting order after `current`, excluding `current` itself.
    /// With no known current window, forward starts at the first slot and backward at the last.
    public func candidates(after current: ID?, direction: Direction) -> [ID] {
        let count = entries.count
        guard count > 0 else { return [] }
        let origin: Int
        let offsets: ClosedRange<Int>
        if let current, let index = entries.firstIndex(where: { $0.id == current }) {
            guard count > 1 else { return [] }
            origin = index
            offsets = 1...(count - 1)
        } else {
            origin = direction == .forward ? count - 1 : 0
            offsets = 1...count
        }
        return offsets
            .map { entries[((origin + direction.step * $0) % count + count) % count] }
            .filter(\.isAvailable)
            .map(\.id)
    }
}
