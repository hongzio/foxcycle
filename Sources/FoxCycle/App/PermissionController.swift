import AppKit
import ApplicationServices

/// Tracks the Accessibility grant. On macOS 27 the system prompt is titled "Device Control and
/// Data Access", and that single grant also covers the event tap (listen + post).
@MainActor
final class PermissionController {
    static let pollInterval: TimeInterval = 2
    private static let settingsURL = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility")!

    private(set) var isTrusted = AXIsProcessTrusted()
    var onChange: ((Bool) -> Void)?
    private var timer: Timer?

    func start() {
        if !isTrusted {
            // Shows the system prompt once; the user grants it in System Settings.
            _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        }
        // Polling also catches revocation while running (IT-09). AXIsProcessTrusted is cheap.
        timer = Timer.scheduledTimer(withTimeInterval: Self.pollInterval, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.poll() }
        }
    }

    func openSettings() {
        NSWorkspace.shared.open(Self.settingsURL)
    }

    private func poll() {
        let trusted = AXIsProcessTrusted()
        guard trusted != isTrusted else { return }
        isTrusted = trusted
        Log.app.notice("accessibility \(trusted ? "granted" : "revoked", privacy: .public)")
        onChange?(trusted)
    }
}
