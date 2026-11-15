import Foundation
import AppKit
import IOKit.hid

struct PermissionChecker {
    private static let hasPromptedKey = "hasPromptedInputMonitoring"

    /// Asks macOS directly. This used to create a keyboard event tap to see
    /// whether that succeeded, and never released it.
    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    static func promptIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: hasPromptedKey) else { return }
        UserDefaults.standard.set(true, forKey: hasPromptedKey)

        if !hasInputMonitoring {
            showPermissionAlert()
        }
    }

    private static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Input Monitoring Required"
        alert.informativeText = "BO3 Launcher needs Input Monitoring permission to launch the game with the Mac fix.\n\nClick \"Open Settings\" and enable BO3 Launcher in the list."
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Settings")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn {
            openInputMonitoringSettings()
        }
    }

    static func openInputMonitoringSettings() {
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_ListenEvent") {
            NSWorkspace.shared.open(url)
        }
    }
}
