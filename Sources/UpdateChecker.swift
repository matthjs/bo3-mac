import Foundation
import AppKit

/// Checks this fork's GitHub releases for a newer version.
///
/// It used to read upstream's feed on bo3.redxam.com, which would have offered
/// upstream builds and replaced this fork's fixes. Releases are tagged with
/// `MARKETING_VERSION`, e.g. `v1.2.5`. Nothing is installed automatically: the
/// player is sent to the release page to download it.
struct UpdateChecker {
    private static let repo = "matthjs/bo3-mac"
    private static let latestReleaseURL = URL(string: "https://api.github.com/repos/\(repo)/releases/latest")!

    private struct Release: Decodable {
        let tag_name: String
        let name: String?
        let body: String?
        let html_url: String
    }

    static var currentVersion: String {
        Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "1.0.0"
    }

    static func checkForUpdates(silent: Bool = false) {
        Task {
            do {
                var request = URLRequest(url: latestReleaseURL)
                request.setValue("application/vnd.github+json", forHTTPHeaderField: "Accept")
                request.cachePolicy = .reloadIgnoringLocalCacheData
                let (data, response) = try await URLSession.shared.data(for: request)

                // GitHub answers 404 until the first release is published.
                if (response as? HTTPURLResponse)?.statusCode == 404 {
                    if !silent { await showUpToDate() }
                    return
                }
                let release = try JSONDecoder().decode(Release.self, from: data)
                let remoteVersion = release.tag_name.hasPrefix("v")
                    ? String(release.tag_name.dropFirst())
                    : release.tag_name

                if isNewer(remoteVersion, than: currentVersion) {
                    await MainActor.run { promptUpdate(release, version: remoteVersion) }
                } else if !silent {
                    await showUpToDate()
                }
            } catch {
                if !silent {
                    await MainActor.run {
                        let alert = NSAlert()
                        alert.messageText = "Update Check Failed"
                        alert.informativeText = "Could not reach GitHub.\n\n\(error.localizedDescription)"
                        alert.alertStyle = .warning
                        alert.runModal()
                    }
                }
            }
        }
    }

    /// Numeric comparison, so 1.2.10 counts as newer than 1.2.9.
    static func isNewer(_ remote: String, than current: String) -> Bool {
        remote.compare(current, options: .numeric) == .orderedDescending
    }

    @MainActor
    private static func showUpToDate() {
        let alert = NSAlert()
        alert.messageText = "You're Up to Date"
        alert.informativeText = "BO3 Launcher \(currentVersion) is the latest version."
        alert.alertStyle = .informational
        alert.runModal()
    }

    @MainActor
    private static func promptUpdate(_ release: Release, version: String) {
        let alert = NSAlert()
        alert.messageText = "Update Available"
        let notes = release.body?.trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
        alert.informativeText = "BO3 Launcher \(version) is available (you have \(currentVersion))."
            + (notes.isEmpty ? "" : "\n\n\(notes.prefix(600))")
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Open Release Page")
        alert.addButton(withTitle: "Later")

        if alert.runModal() == .alertFirstButtonReturn, let url = URL(string: release.html_url) {
            NSWorkspace.shared.open(url)
        }
    }
}
