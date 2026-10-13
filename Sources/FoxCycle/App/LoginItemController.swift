import ServiceManagement

/// "Start at Login" through `SMAppService.mainApp`: the app itself is the login item, no helper.
///
/// The system owns the state, and the user can change it in System Settings as well, so nothing is
/// stored here: callers read `state` whenever they need it.
@MainActor
final class LoginItemController {
    enum State: String {
        case off
        case on
        /// Registered, but switched off in System Settings > General > Login Items.
        case needsApproval
    }

    var state: State {
        switch SMAppService.mainApp.status {
        case .enabled: .on
        case .requiresApproval: .needsApproval
        case .notRegistered, .notFound: .off
        @unknown default: .off
        }
    }

    func setEnabled(_ enabled: Bool) throws {
        if enabled {
            try SMAppService.mainApp.register()
        } else {
            try SMAppService.mainApp.unregister()
        }
        Log.app.info("login item: \(self.state.rawValue, privacy: .public)")
    }

    func openSettings() {
        SMAppService.openSystemSettingsLoginItems()
    }
}
