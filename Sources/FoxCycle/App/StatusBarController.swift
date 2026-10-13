import AppKit

/// Menu bar UI: Enabled and Start at Login toggles, permission state, Firefox window count, Quit.
@MainActor
final class StatusBarController: NSObject, NSMenuDelegate {
    struct Status {
        var isEnabled: Bool
        var isTrusted: Bool
        var tapFailed: Bool
        var isRunning: Bool
        var windowCount: Int
        var loginItem: LoginItemController.State
    }

    var status: () -> Status = {
        Status(isEnabled: false, isTrusted: false, tapFailed: false, isRunning: false, windowCount: 0, loginItem: .off)
    }
    var onToggleEnabled: (() -> Void)?
    var onToggleLoginItem: (() -> Void)?
    var onOpenSettings: (() -> Void)?
    var onRetry: (() -> Void)?

    private var item: NSStatusItem?
    private let menu = NSMenu()

    func install() {
        let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.squareLength)
        let image = NSImage(systemSymbolName: "rectangle.stack", accessibilityDescription: "FoxCycle")
        image?.isTemplate = true
        item.button?.image = image
        menu.delegate = self
        menu.autoenablesItems = false
        item.menu = menu
        self.item = item
        refresh()
    }

    /// Dims the icon whenever the shortcut is not active.
    func refresh() {
        item?.button?.appearsDisabled = !status().isRunning
    }

    nonisolated func menuNeedsUpdate(_ menu: NSMenu) {
        MainActor.assumeIsolated { rebuild() }
    }

    private func rebuild() {
        let status = status()
        menu.removeAllItems()

        let enabled = NSMenuItem(title: "Enabled", action: #selector(toggleEnabled), keyEquivalent: "")
        enabled.target = self
        enabled.state = status.isEnabled ? .on : .off
        menu.addItem(enabled)
        // Switched off in System Settings: only the user can turn it back on there.
        let loginTitle = status.loginItem == .needsApproval ? "Start at Login (approve in System Settings)" : "Start at Login"
        let login = action(loginTitle, #selector(toggleLoginItem))
        login.state = status.loginItem == .on ? .on : .off
        menu.addItem(login)
        menu.addItem(.separator())

        if !status.isTrusted {
            menu.addItem(info("Accessibility: Not Granted"))
            menu.addItem(action("Open Accessibility Settings…", #selector(openSettings)))
        } else if status.tapFailed {
            menu.addItem(info("Shortcut paused: event tap kept timing out"))
            menu.addItem(action("Retry", #selector(retry)))
        } else {
            menu.addItem(info("Accessibility: Granted"))
        }
        if status.isRunning {
            menu.addItem(info("Firefox windows: \(status.windowCount)"))
        }

        menu.addItem(.separator())
        let quit = NSMenuItem(title: "Quit FoxCycle", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        menu.addItem(quit)
    }

    private func info(_ title: String) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: nil, keyEquivalent: "")
        item.isEnabled = false
        return item
    }

    private func action(_ title: String, _ selector: Selector) -> NSMenuItem {
        let item = NSMenuItem(title: title, action: selector, keyEquivalent: "")
        item.target = self
        return item
    }

    @objc private func toggleEnabled() { onToggleEnabled?() }
    @objc private func toggleLoginItem() { onToggleLoginItem?() }
    @objc private func openSettings() { onOpenSettings?() }
    @objc private func retry() { onRetry?() }
}
