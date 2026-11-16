import Foundation
import AppKit
import IOKit.hid

struct PermissionChecker {
    /// A new key: the old prompt ("hasPromptedInputMonitoring") went to
    /// everyone at startup, so players with a PlayStation controller who saw it
    /// still get the corrected one once.
    private static let hasPromptedKey = "hasPromptedInputMonitoringForRumble"

    /// Asks macOS directly. This used to create a keyboard event tap to see
    /// whether that succeeded, and never released it.
    static var hasInputMonitoring: Bool {
        IOHIDCheckAccess(kIOHIDRequestTypeListenEvent) == kIOHIDAccessTypeGranted
    }

    /// Input Monitoring is only needed for DualSense rumble: the rumble shim in
    /// the game opens the controller with IOHIDManager to send it output
    /// reports, and macOS gates that behind Input Monitoring. The game runs as
    /// the launcher's child, so macOS checks the launcher's permission. The
    /// launcher itself reads controllers through GameController, and keyboard
    /// and mouse in the game work without it, so only ask when a PlayStation
    /// controller connects.
    static func promptForRumbleIfNeeded() {
        guard !UserDefaults.standard.bool(forKey: hasPromptedKey) else { return }
        UserDefaults.standard.set(true, forKey: hasPromptedKey)

        if !hasInputMonitoring {
            showPermissionAlert()
        }
    }

    private static func showPermissionAlert() {
        let alert = NSAlert()
        alert.messageText = "Allow Rumble on PlayStation Controllers?"
        alert.informativeText = "To make a PlayStation controller rumble, the game has to talk to it directly, which macOS lists under Input Monitoring. Nothing else needs it: you can play without it, just without rumble.\n\nClick \"Open Settings\" and enable BO3 Launcher in the list."
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
