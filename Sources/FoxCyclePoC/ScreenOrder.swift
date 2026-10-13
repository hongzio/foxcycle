import CoreGraphics
import Foundation

/// A window as the window server composites it. Only owner PID, layer, alpha and bounds are read;
/// window titles would need Screen Recording permission and are deliberately not touched.
struct ScreenWindow {
    let pid: pid_t
    let owner: String
    let layer: Int
    let alpha: Double
    let bounds: CGRect
}

enum ScreenOrder {
    /// On-screen windows, front to back.
    static func current() -> [ScreenWindow] {
        guard let list = CGWindowListCopyWindowInfo([.optionOnScreenOnly, .excludeDesktopElements], kCGNullWindowID)
            as? [[String: Any]]
        else { return [] }
        return list.compactMap { info in
            guard let pid = (info[kCGWindowOwnerPID as String] as? NSNumber)?.int32Value,
                  let boundsDict = info[kCGWindowBounds as String] as? NSDictionary,
                  let bounds = CGRect(dictionaryRepresentation: boundsDict as CFDictionary)
            else { return nil }
            return ScreenWindow(
                pid: pid,
                owner: info[kCGWindowOwnerName as String] as? String ?? "?",
                layer: (info[kCGWindowLayer as String] as? NSNumber)?.intValue ?? -1,
                alpha: (info[kCGWindowAlpha as String] as? NSNumber)?.doubleValue ?? 1,
                bounds: bounds
            )
        }
    }

    static func normalWindows() -> [ScreenWindow] {
        current().filter { $0.layer == 0 && $0.alpha > 0 && $0.bounds.width > 40 && $0.bounds.height > 40 }
    }

    /// The front-most ordinary window — what the user actually sees on top.
    static func topNormalWindow() -> ScreenWindow? {
        normalWindows().first
    }
}

extension CGRect {
    func approximatelyEquals(_ other: CGRect, tolerance: CGFloat = 2) -> Bool {
        abs(minX - other.minX) <= tolerance && abs(minY - other.minY) <= tolerance
            && abs(width - other.width) <= tolerance && abs(height - other.height) <= tolerance
    }

    var compact: String {
        "(\(Int(minX)),\(Int(minY)) \(Int(width))x\(Int(height)))"
    }
}
