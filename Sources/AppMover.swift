import Foundation
import AppKit

enum AppMover {
    private static let applicationsDir = "/Applications"

    static var isInApplications: Bool {
        Bundle.main.bundlePath.hasPrefix(applicationsDir + "/")
    }

    /// Returns `true` if the app was moved and relaunched (caller should bail out).
    @discardableResult
    static func moveToApplicationsIfNeeded() -> Bool {
        guard let bundlePath = Bundle.main.bundlePath as String?,
              let bundleName = Bundle.main.bundlePath.components(separatedBy: "/").last
        else { return false }

        let destination = (applicationsDir as NSString).appendingPathComponent(bundleName)

        if bundlePath == destination { return false }
        if bundlePath.hasPrefix(applicationsDir + "/") { return false }

        // Ask the user for confirmation
        let alert = NSAlert()
        alert.alertStyle = .informational
        alert.icon = NSApp.applicationIconImage

        let fm = FileManager.default
        let alreadyExists = fm.fileExists(atPath: destination)

        // A downloaded app that wasn't moved with Finder runs from a read-only
        // copy under AppTranslocation. When that copy is the same build as the
        // one in /Applications, there's nothing to replace: clear the download
        // flag there so macOS stops translocating it, and reopen it.
        if alreadyExists && bundlePath.contains("/AppTranslocation/") && isSameBuild(at: destination) {
            alert.messageText = "Finish Installing BO3 Launcher?"
            alert.informativeText = "macOS is running BO3 Launcher from a temporary copy because it was downloaded. The launcher will reopen from /Applications."
            alert.addButton(withTitle: "Reopen")
            alert.addButton(withTitle: "Not Now")
            guard alert.runModal() == .alertFirstButtonReturn else { return false }
            stripQuarantine(destination)
            relaunch(at: destination)
            return true
        }

        if alreadyExists {
            alert.messageText = "Update BO3 Launcher in Applications?"
            alert.informativeText = "An older version exists in /Applications. This will replace it with the current version and relaunch the app."
        } else {
            alert.messageText = "Move to Applications?"
            alert.informativeText = "BO3 Launcher needs to be in /Applications to work properly.\n\nThe app will be moved from its current location and relaunched automatically."
        }

        alert.addButton(withTitle: alreadyExists ? "Replace & Relaunch" : "Move & Relaunch")
        alert.addButton(withTitle: "Not Now")

        guard alert.runModal() == .alertFirstButtonReturn else { return false }

        // Copy into a staging name beside the destination, then swap it in.
        // The old copy used to be deleted first, so a failed move left the
        // player with no launcher in /Applications at all. Now the existing
        // copy and the running one both stay put until the new one is in place.
        let staged = (applicationsDir as NSString)
            .appendingPathComponent(".\(bundleName).new-\(UUID().uuidString)")
        do {
            try fm.copyItem(atPath: bundlePath, toPath: staged)
            if alreadyExists {
                _ = try fm.replaceItemAt(URL(fileURLWithPath: destination),
                                         withItemAt: URL(fileURLWithPath: staged))
            } else {
                try fm.moveItem(atPath: staged, toPath: destination)
            }
        } catch let error as NSError {
            try? fm.removeItem(atPath: staged)
            if error.domain == NSCocoaErrorDomain &&
               (error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError) {
                showError("Permission denied.\n\nYour user account doesn't have write access to /Applications. Try dragging the app there manually, or run the app as an administrator.")
            } else {
                showError("Could not move app to /Applications: \(error.localizedDescription)")
            }
            return false
        }

        // Only now remove the original, making this a move. If that fails, the
        // player just has a spare copy, which is harmless.
        try? fm.removeItem(atPath: bundlePath)

        stripQuarantine(destination)
        relaunch(at: destination)
        return true
    }

    private static func isSameBuild(at path: String) -> Bool {
        guard let other = Bundle(path: path)?.infoDictionary else { return false }
        let mine = Bundle.main.infoDictionary
        return other["CFBundleShortVersionString"] as? String == mine?["CFBundleShortVersionString"] as? String &&
            other["CFBundleVersion"] as? String == mine?["CFBundleVersion"] as? String
    }

    private static func stripQuarantine(_ path: String) {
        let xattr = Process()
        xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
        xattr.arguments = ["-dr", "com.apple.quarantine", path]
        try? xattr.run()
        xattr.waitUntilExit()
    }

    private static func relaunch(at path: String) {
        let url = URL(fileURLWithPath: path)
        let config = NSWorkspace.OpenConfiguration()
        config.createsNewApplicationInstance = true
        NSWorkspace.shared.openApplication(at: url, configuration: config) { _, _ in }

        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) {
            NSApp.terminate(nil)
        }
    }

    private static func showError(_ message: String) {
        let alert = NSAlert()
        alert.messageText = "Move Failed"
        alert.informativeText = message
        alert.alertStyle = .critical
        alert.runModal()
    }
}
