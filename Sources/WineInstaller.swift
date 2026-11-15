import Foundation
import AppKit
import CryptoKit

/// Installs Wine, which custom Workshop maps need. The first time one loads,
/// BO3MacFix runs the map SDK's `cod2map64.exe` under Wine to convert the map's
/// navmesh to the Mac format, and without Wine the map errors out mid-load.
///
/// Players used to be told to `brew install --cask wine-stable`. Homebrew
/// disabled that cask on 2026-09-01 because the build isn't notarized, so the
/// launcher now fetches the same Gcenx build itself.
@MainActor
final class WineInstaller: ObservableObject {
    static let shared = WineInstaller()

    enum Phase: Equatable {
        case idle
        case downloading(Double)
        case installing
        case preparing
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var winePath: String? = WineInstaller.findWine()

    // Pinned so a tampered or swapped download is refused. Bump both together.
    private static let downloadURL = URL(string: "https://github.com/Gcenx/macOS_Wine_builds/releases/download/11.0_1/wine-stable-11.0_1-osx64.tar.xz")!
    private static let downloadSHA256 = "b50dc50ec7f41d58b115a6b685d4d1315ba3c797bd3aa0f49213f2703cb82388"
    private static let appName = "Wine Stable.app"

    var isInstalled: Bool { winePath != nil }

    var isBusy: Bool {
        switch phase {
        case .downloading, .installing, .preparing: return true
        case .idle, .failed: return false
        }
    }

    func refresh() {
        winePath = Self.findWine()
    }

    // MARK: - Finding Wine

    /// Same search order as `get_wine_path` in BO3MacFix's `utilities.c`, so
    /// the launcher never reports Wine that the game can't find, plus
    /// `~/Applications` for installs where `/Applications` wasn't writable.
    /// The game gets the result as `BO3MACFIX_WINEPATH`, which BO3MacFix checks
    /// first, so that last location works too.
    nonisolated static func findWine() -> String? {
        let fm = FileManager.default
        if let custom = ProcessInfo.processInfo.environment["BO3MACFIX_WINEPATH"],
           fm.isExecutableFile(atPath: custom) {
            return custom
        }

        // BO3MacFix runs inside the game, under Rosetta on Apple Silicon, and
        // picks the Homebrew prefix by that. Mirror it by hardware, since the
        // launcher itself runs natively.
        let brew = isAppleSilicon ? "/opt/homebrew" : "/usr/local"
        var candidates = ["wine64", "wine"].map { "\(brew)/bin/\($0)" }

        let bundleDirs = ["/Applications", NSHomeDirectory() + "/Applications"]
        for dir in bundleDirs {
            for build in ["Stable", "Staging", "Development"] {
                for exe in ["wine64", "wine"] {
                    candidates.append("\(dir)/Wine \(build).app/Contents/Resources/wine/bin/\(exe)")
                }
            }
        }
        return candidates.first { fm.isExecutableFile(atPath: $0) }
    }

    nonisolated private static var isAppleSilicon: Bool {
        var value: Int32 = 0
        var size = MemoryLayout<Int32>.size
        return sysctlbyname("hw.optional.arm64", &value, &size, nil, 0) == 0 && value == 1
    }

    // MARK: - Installing

    func promptInstall() {
        refresh()
        guard !isInstalled, !isBusy else { return }

        let alert = NSAlert()
        alert.messageText = "Install Wine for Custom Maps?"
        alert.informativeText = """
            Custom Workshop maps need Wine. The first time you load one, BO3MacFix \
            uses it to convert the map for the Mac version of the game.

            This downloads Wine Stable 11.0 (about 185 MB) from the Gcenx macOS \
            Wine builds on GitHub and installs it in Applications. Wine is not \
            notarized by Apple, so the download is checked against a known checksum \
            before anything is installed.
            """
        alert.alertStyle = .informational
        alert.addButton(withTitle: "Install Wine")
        alert.addButton(withTitle: "Cancel")
        guard alert.runModal() == .alertFirstButtonReturn else { return }

        Task { await install() }
    }

    private func install() async {
        phase = .downloading(0)
        let archive = URL(fileURLWithPath: NSTemporaryDirectory())
            .appendingPathComponent("wine-\(UUID().uuidString).tar.xz")
        defer { try? FileManager.default.removeItem(at: archive) }

        do {
            try await download(to: archive)

            phase = .installing
            let digest = try await Task.detached { try Self.sha256(of: archive) }.value
            guard digest == Self.downloadSHA256 else {
                throw InstallError("The Wine download didn't match its expected checksum, so it wasn't installed.")
            }

            let installed = try await installApp(from: archive)
            refresh()
            guard isInstalled else {
                throw InstallError("Wine was unpacked to \(installed) but its wine executable is missing.")
            }

            await createPrefixIfNeeded()
            phase = .idle
            showAlert("Wine Installed", "Custom Workshop maps can now be converted and played. The first load of each map takes a little longer while it's converted.")
        } catch {
            phase = .failed(error.localizedDescription)
            showAlert("Wine Install Failed", error.localizedDescription)
        }
    }

    private func download(to destination: URL) async throws {
        let delegate = DownloadDelegate(destination: destination) { fraction in
            Task { @MainActor in
                if case .downloading = WineInstaller.shared.phase {
                    WineInstaller.shared.phase = .downloading(fraction)
                }
            }
        }
        let session = URLSession(configuration: .default, delegate: delegate, delegateQueue: nil)
        defer { session.finishTasksAndInvalidate() }
        try await withCheckedThrowingContinuation { (continuation: CheckedContinuation<Void, Error>) in
            delegate.continuation = continuation
            session.downloadTask(with: Self.downloadURL).resume()
        }
    }

    /// Unpacks into a staging folder beside the destination, then moves the
    /// app into place, so a failed or interrupted unpack never leaves a broken
    /// `Wine Stable.app` that `findWine` would report as installed.
    private func installApp(from archive: URL) async throws -> String {
        let fm = FileManager.default
        let parent = fm.isWritableFile(atPath: "/Applications")
            ? "/Applications"
            : NSHomeDirectory() + "/Applications"
        try fm.createDirectory(atPath: parent, withIntermediateDirectories: true)

        let staging = parent + "/.bo3-wine-\(UUID().uuidString)"
        try fm.createDirectory(atPath: staging, withIntermediateDirectories: true)
        defer { try? fm.removeItem(atPath: staging) }

        let status = await Self.run("/usr/bin/tar", ["-xJf", archive.path, "-C", staging])
        let unpacked = staging + "/" + Self.appName
        guard status == 0, fm.fileExists(atPath: unpacked) else {
            throw InstallError("Couldn't unpack the Wine download (tar exited with \(status)).")
        }

        // Gatekeeper blocks a quarantined, un-notarized app outright. The
        // download was checksum-verified above, which is the trust check here.
        _ = await Self.run("/usr/bin/xattr", ["-dr", "com.apple.quarantine", unpacked])

        let destination = parent + "/" + Self.appName
        if fm.fileExists(atPath: destination) {
            // Only reached when the existing copy has no wine executable.
            _ = try fm.replaceItemAt(URL(fileURLWithPath: destination),
                                     withItemAt: URL(fileURLWithPath: unpacked))
        } else {
            try fm.moveItem(atPath: unpacked, toPath: destination)
        }
        return destination
    }

    // MARK: - Wine prefix

    /// Creates BO3MacFix's Wine prefix ahead of time. Otherwise Wine builds it
    /// on the first custom map load, which stalls the loading screen long
    /// enough to look like a hang.
    func prepareWinePrefixIfNeeded() async {
        guard !isBusy else { return }
        await createPrefixIfNeeded()
    }

    private func createPrefixIfNeeded() async {
        guard let wine = winePath, MacFixInstaller.isInstalled else { return }
        let prefix = Paths.macFixDir + "/pfx"
        guard !FileManager.default.fileExists(atPath: prefix + "/system.reg") else { return }

        phase = .preparing
        defer { phase = .idle }
        var env = ProcessInfo.processInfo.environment
        env["WINEPREFIX"] = prefix
        env["WINEDEBUG"] = "-all"
        // cod2map is a native program, so skip the .NET and HTML engine
        // installers Wine otherwise offers in dialogs while building a prefix.
        env["WINEDLLOVERRIDES"] = "mscoree,mshtml="
        _ = await Self.run(wine, ["wineboot", "--init"], env: env)
    }

    // MARK: - Helpers

    nonisolated private static func run(_ exe: String, _ args: [String], env: [String: String]? = nil) async -> Int32 {
        await withCheckedContinuation { continuation in
            let process = Process()
            process.executableURL = URL(fileURLWithPath: exe)
            process.arguments = args
            if let env { process.environment = env }
            process.standardOutput = FileHandle.nullDevice
            process.standardError = FileHandle.nullDevice
            process.terminationHandler = { continuation.resume(returning: $0.terminationStatus) }
            do { try process.run() } catch { continuation.resume(returning: -1) }
        }
    }

    nonisolated private static func sha256(of url: URL) throws -> String {
        let handle = try FileHandle(forReadingFrom: url)
        defer { try? handle.close() }
        var hasher = SHA256()
        while let chunk = try handle.read(upToCount: 1 << 20), !chunk.isEmpty {
            hasher.update(data: chunk)
        }
        return hasher.finalize().map { String(format: "%02x", $0) }.joined()
    }

    private func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    private struct InstallError: LocalizedError {
        let errorDescription: String?
        init(_ message: String) { errorDescription = message }
    }
}

/// Reports progress and hands the finished file over before URLSession deletes
/// its temporary copy, which happens as soon as `didFinishDownloadingTo` returns.
private final class DownloadDelegate: NSObject, URLSessionDownloadDelegate, @unchecked Sendable {
    let destination: URL
    let onProgress: (Double) -> Void
    var continuation: CheckedContinuation<Void, Error>?

    init(destination: URL, onProgress: @escaping (Double) -> Void) {
        self.destination = destination
        self.onProgress = onProgress
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didWriteData bytesWritten: Int64, totalBytesWritten: Int64,
                    totalBytesExpectedToWrite: Int64) {
        guard totalBytesExpectedToWrite > 0 else { return }
        onProgress(Double(totalBytesWritten) / Double(totalBytesExpectedToWrite))
    }

    func urlSession(_ session: URLSession, downloadTask: URLSessionDownloadTask,
                    didFinishDownloadingTo location: URL) {
        if let http = downloadTask.response as? HTTPURLResponse, http.statusCode != 200 {
            finish(.failure(URLError(.badServerResponse)))
            return
        }
        do {
            try FileManager.default.moveItem(at: location, to: destination)
            finish(.success(()))
        } catch {
            finish(.failure(error))
        }
    }

    func urlSession(_ session: URLSession, task: URLSessionTask, didCompleteWithError error: Error?) {
        if let error { finish(.failure(error)) }
    }

    private func finish(_ result: Result<Void, Error>) {
        continuation?.resume(with: result)
        continuation = nil
    }
}
