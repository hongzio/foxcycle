import CoreGraphics
import Foundation
import os

/// Whether the screen is locked, for the window registry.
///
/// While the screen is locked, Firefox's Accessibility window list is not its windows (seen on
/// macOS 27). The registry must not read that as "every window closed", or each lock would rebuild
/// the ring with new tokens and possibly in a new order.
final class ScreenLockMonitor: Sendable {
    enum State: Equatable {
        case unlocked
        case locked
        /// Accessibility may not list the windows again right away (measured: within 0.3s).
        case recentlyUnlocked(nanosAgo: UInt64)
    }

    static let unlockGraceNanos: UInt64 = 10_000_000_000

    private struct Tracked {
        var isLocked = false
        var unlockedAt: UInt64?
    }

    private let tracked = OSAllocatedUnfairLock(initialState: Tracked())

    init() {
        let tracked = tracked
        let center = DistributedNotificationCenter.default()
        _ = center.addObserver(forName: .init("com.apple.screenIsLocked"), object: nil, queue: nil) { _ in
            tracked.withLock { $0.isLocked = true }
            Log.app.notice("screen locked")
        }
        _ = center.addObserver(forName: .init("com.apple.screenIsUnlocked"), object: nil, queue: nil) { _ in
            tracked.withLock {
                $0.isLocked = false
                $0.unlockedAt = Clock.now()
            }
            Log.app.notice("screen unlocked")
        }
    }

    var state: State {
        let current = tracked.withLock { $0 }
        // The session flag also covers a lock whose notification has not arrived yet.
        if current.isLocked || Self.sessionReportsLocked() { return .locked }
        if let unlockedAt = current.unlockedAt {
            let elapsed = Clock.now() &- unlockedAt
            if elapsed < Self.unlockGraceNanos { return .recentlyUnlocked(nanosAgo: elapsed) }
        }
        return .unlocked
    }

    /// Undocumented session key, present only while the screen is locked.
    private static func sessionReportsLocked() -> Bool {
        let session = CGSessionCopyCurrentDictionary() as? [String: Any]
        return session?["CGSSessionScreenIsLocked"] as? Bool ?? false
    }
}
