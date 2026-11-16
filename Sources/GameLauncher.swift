import Foundation
import AppKit

struct GameLauncher {
    static let steamAppID = "311210"

    private static let offlineModeKey = "launchWithoutSteam"

    static var launchWithoutSteam: Bool {
        get { UserDefaults.standard.bool(forKey: offlineModeKey) }
        set { UserDefaults.standard.set(newValue, forKey: offlineModeKey) }
    }

    static let steamPlayStartsGameKey = "steamPlayStartsGame"

    /// Posted after Steam integration is installed or removed, so the Options
    /// menu can update.
    static let steamIntegrationChanged = Notification.Name("SteamIntegrationChanged")

    /// With Steam integration, Steam's Play button opens the launcher through
    /// `bo3launcher://steam-play`. When this is on, the launcher starts the
    /// game straight away instead of waiting for a second click.
    static var steamPlayStartsGame: Bool {
        UserDefaults.standard.bool(forKey: steamPlayStartsGameKey)
    }

    /// Set while a game the launcher started is running, so a second press of
    /// Steam's Play button doesn't start another copy.
    private(set) static var isGameRunning = false

    static func handleSteamPlay() {
        NSApp.activate(ignoringOtherApps: true)
        guard steamPlayStartsGame, !isGameRunning else { return }
        launch()
    }

    static let steamOverlayKey = "steamOverlay"

    /// Loads Steam's in-game overlay (Shift+Tab) into the game. On by default.
    static var steamOverlay: Bool {
        UserDefaults.standard.object(forKey: steamOverlayKey) as? Bool ?? true
    }

    private static var steamOverlayDylib: String {
        NSHomeDirectory() + "/Library/Application Support/Steam/Steam.AppBundle/Steam/Contents/MacOS/gameoverlayrenderer.dylib"
    }

    static let friendsOnlyKey = "friendsOnlyMessages"

    /// BO3MacFix's `BO3MACFIX_FRIENDSONLY`: drops the game's instant messages
    /// (invites and the like, sent through Activision's service) from anyone
    /// who isn't a Steam friend. Past BO3 exploits arrived that way. Off by
    /// default, since it isn't known which features rely on messages from
    /// strangers. It does not make a lobby private.
    static var friendsOnlyMessages: Bool {
        get { UserDefaults.standard.bool(forKey: friendsOnlyKey) }
        set { UserDefaults.standard.set(newValue, forKey: friendsOnlyKey) }
    }

    static func launch() {
        guard MacFixInstaller.isGamePresent else {
            MacFixInstaller.promptInstallIfNeeded()
            return
        }

        if Paths.installType == .nonSteam {
            launchWithoutSteam = true
        }

        if !MacFixInstaller.isInstalled {
            MacFixInstaller.promptInstallIfNeeded()
            guard MacFixInstaller.isInstalled else { return }
        }

        // Every fix lives in the injected libraries rather than the launcher,
        // and both are copied into the game folder, so an update only reaches
        // the player once those copies are refreshed.
        MacFixInstaller.syncMacFixDylib()
        MacFixInstaller.syncRumbleDylib()

        launchWithFix()
    }

    private static func launchWithFix() {
        let bo3Root = Paths.bo3Root
        let gameExe = bo3Root + "/CoDBlkOps3.app/Contents/MacOS/CoDBlkOps3_Exe"
        let gameDir = bo3Root + "/CoDBlkOps3.app/Contents/MacOS"
        let fixDylib = bo3Root + "/BO3MacFix/BO3MacFix.dylib"
        let winePrefix = bo3Root + "/BO3MacFix/pfx"

        guard FileManager.default.fileExists(atPath: gameExe) else {
            launchViaSteamOrReport()
            return
        }

        ControllerManager.shared.suspend()

        let rumbleDylib = bo3Root + "/BO3MacFix/DualSenseRumble.dylib"

        var env = ProcessInfo.processInfo.environment
        var dylibs = fixDylib
        if FileManager.default.fileExists(atPath: rumbleDylib) {
            dylibs += ":" + rumbleDylib
        }
        // Steam loads its overlay into whatever it starts, which with Steam
        // integration is the redirector, not the game. Load it here instead.
        // It needs the Steam client running, so not for offline launches.
        if steamOverlay && !launchWithoutSteam && FileManager.default.fileExists(atPath: steamOverlayDylib) {
            dylibs += ":" + steamOverlayDylib
            env["SteamGameId"] = steamAppID
            env["SteamOverlayGameId"] = steamAppID
        }
        if let existing = env["DYLD_INSERT_LIBRARIES"] {
            dylibs += ":" + existing
        }
        env["DYLD_INSERT_LIBRARIES"] = dylibs
        env["WINEPREFIX"] = winePrefix
        env["SteamAppId"] = steamAppID
        setWinePath(&env)
        if launchWithoutSteam {
            env["BO3MACFIX_OFFLINE"] = "1"
        }
        if friendsOnlyMessages {
            env["BO3MACFIX_FRIENDSONLY"] = "1"
        }
        // The shim swaps every controller prompt to PlayStation unless this is
        // set, which showed PlayStation buttons to Xbox and Switch players.
        // Only keep the swap when a PlayStation controller is connected at
        // launch. The shim only checks that the variable exists.
        if env["DS_XBOX_GLYPHS"] == nil && !ControllerManager.playStationControllerConnected {
            env["DS_XBOX_GLYPHS"] = "1"
        }

        let pid = spawnDetached(exe: gameExe, dir: gameDir, env: env)
        if pid > 0 {
            isGameRunning = true
            DispatchQueue.main.async { LoadingOverlay.shared.show() }
            monitorPid(pid)
        } else {
            // There used to be a step here that ran `Install_BO3MacFix 9`. The
            // installer ignores its arguments and reads the menu choice from
            // stdin, which is empty when the launcher starts it, so it redrew
            // its menu in a busy loop forever instead of starting the game.
            ControllerManager.shared.resume()
            launchViaSteamOrReport()
        }
    }

    /// With Steam integration on, Steam's Play button opens this launcher, so
    /// falling back to Steam would only bring the launcher back, and with
    /// "Steam's Play Starts the Game" on it would try again in a loop. Say what
    /// went wrong instead.
    private static func launchViaSteamOrReport() {
        if isSteamIntegrated {
            showAlert("Couldn't Start the Game", "BO3 Launcher couldn't start Call of Duty: Black Ops III from:\n\(Paths.bo3Root)\n\nCheck that the game is fully installed, or use Verify Integrity of Game Files in Steam.")
        } else {
            launchViaSteam()
        }
    }

    /// BO3MacFix only searches Homebrew and `/Applications` for Wine. Passing
    /// the path also covers the `~/Applications` fallback `WineInstaller` uses
    /// when `/Applications` isn't writable.
    ///
    /// BO3MacFix runs Wine with the game's environment while the game waits on
    /// it. If the prefix wasn't prepared, Wine would offer to install Mono and
    /// Gecko in a dialog hidden behind the frozen game, so disable both, as
    /// `WineInstaller.createPrefixIfNeeded` does. The debug output only slows
    /// the conversion down.
    private static func setWinePath(_ env: inout [String: String]) {
        if env["BO3MACFIX_WINEPATH"] == nil, let wine = WineInstaller.findWine() {
            env["BO3MACFIX_WINEPATH"] = wine
        }
        if env["WINEDLLOVERRIDES"] == nil { env["WINEDLLOVERRIDES"] = "mscoree,mshtml=" }
        if env["WINEDEBUG"] == nil { env["WINEDEBUG"] = "-all" }
    }

    /// Spawn a process in its own session so it doesn't inherit our HID claims.
    private static func spawnDetached(exe: String, dir: String, env: [String: String], args: [String] = []) -> pid_t {
        var pid: pid_t = 0
        var attr: posix_spawnattr_t?
        posix_spawnattr_init(&attr)
        posix_spawnattr_setflags(&attr, Int16(POSIX_SPAWN_SETSID))

        let envStrings = env.map { "\($0.key)=\($0.value)" }
        var cEnv = envStrings.map { strdup($0)! as UnsafeMutablePointer<CChar>? }
        cEnv.append(nil)

        var cArgs: [UnsafeMutablePointer<CChar>?] = [strdup(exe)]
        for arg in args { cArgs.append(strdup(arg)) }
        cArgs.append(nil)

        // The child's working directory is set through a file action rather
        // than by changing ours around the call, which is process-wide and
        // races with anything else resolving relative paths at the time.
        var actions: posix_spawn_file_actions_t?
        posix_spawn_file_actions_init(&actions)
        posix_spawn_file_actions_addchdir_np(&actions, dir)

        let result = posix_spawn(&pid, exe, &actions, &attr, &cArgs, &cEnv)

        posix_spawn_file_actions_destroy(&actions)
        posix_spawnattr_destroy(&attr)
        cArgs.compactMap({ $0 }).forEach { free($0) }
        cEnv.compactMap({ $0 }).forEach { free($0) }

        return result == 0 ? pid : -1
    }

    private static func monitorPid(_ pid: pid_t) {
        DispatchQueue.global(qos: .utility).async {
            var status: Int32 = 0
            waitpid(pid, &status, 0)
            DispatchQueue.main.async {
                isGameRunning = false
                LoadingOverlay.shared.dismiss()
                ControllerManager.shared.resume()
            }
        }
    }

    static func launchViaSteam() {
        if let url = URL(string: "steam://rungameid/\(steamAppID)") {
            NSWorkspace.shared.open(url)
        }
    }

    private static var appBundleExePath: String { Paths.bo3Root + "/CoDBlkOps3.app/Contents/MacOS/AppBundleExe" }
    private static var appBundleExeBackupPath: String { Paths.bo3Root + "/CoDBlkOps3.app/Contents/MacOS/AppBundleExe_original" }

    /// Checks the executable itself, not just the backup. Verifying the game
    /// in Steam restores the original `AppBundleExe` and leaves the backup
    /// behind, and a backup-only check kept reporting integration as on.
    static var isSteamIntegrated: Bool {
        isRedirector(appBundleExePath)
    }

    /// Every build of the redirector, including the ones older launchers
    /// compiled on the player's Mac, carries this message. Aspyr's launcher doesn't.
    private static func isRedirector(_ path: String) -> Bool {
        guard let data = FileManager.default.contents(atPath: path) else { return false }
        return data.range(of: Data("BO3 Launcher.app not found".utf8)) != nil
    }

    private static let pendingSteamIntegrationKey = "pendingSteamIntegration"

    static func resumeSteamIntegrationIfNeeded() {
        if UserDefaults.standard.bool(forKey: pendingSteamIntegrationKey) {
            UserDefaults.standard.removeObject(forKey: pendingSteamIntegrationKey)
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
                installSteamIntegration()
            }
        }
    }

    static func installSteamIntegration() {
        if !AppMover.isInApplications {
            UserDefaults.standard.set(true, forKey: pendingSteamIntegrationKey)
            if AppMover.moveToApplicationsIfNeeded() {
                return
            }
            UserDefaults.standard.removeObject(forKey: pendingSteamIntegrationKey)
            if !AppMover.isInApplications {
                showAlert("Steam Integration", "Steam integration requires BO3 Launcher to be in /Applications.\n\nMove the app there and try again.")
                return
            }
        }

        let fm = FileManager.default
        let appBundleExe = appBundleExePath
        let backupPath = appBundleExeBackupPath

        // Prebuilt and signed with the app. It used to be compiled with clang
        // on the player's Mac, which failed for anyone without Xcode's command
        // line tools.
        guard let builtRedirector = Bundle.main.path(forAuxiliaryExecutable: "SteamRedirector") else {
            showAlert("Steam Integration", "The Steam redirector is missing from the app bundle. Reinstall BO3 Launcher and try again.")
            return
        }

        // Back up the original. If Steam restored or updated it since an
        // earlier install, the file in place is the newer original, so it
        // replaces the old backup.
        if fm.fileExists(atPath: appBundleExe) && !isRedirector(appBundleExe) {
            do {
                if fm.fileExists(atPath: backupPath) {
                    try fm.removeItem(atPath: backupPath)
                }
                try fm.moveItem(atPath: appBundleExe, toPath: backupPath)
            } catch let error as NSError {
                showAlert("Backup Failed", permissionMessage(for: error, path: appBundleExe))
                return
            }
        }

        // Copy redirector
        do {
            if fm.fileExists(atPath: appBundleExe) {
                try fm.removeItem(atPath: appBundleExe)
            }
            try fm.copyItem(atPath: builtRedirector, toPath: appBundleExe)

            let chmod = Process()
            chmod.executableURL = URL(fileURLWithPath: "/bin/chmod")
            chmod.arguments = ["755", appBundleExe]
            try chmod.run()
            chmod.waitUntilExit()

            let xattr = Process()
            xattr.executableURL = URL(fileURLWithPath: "/usr/bin/xattr")
            xattr.arguments = ["-dr", "com.apple.quarantine", appBundleExe]
            try xattr.run()
            xattr.waitUntilExit()

            NotificationCenter.default.post(name: steamIntegrationChanged, object: nil)
            showAlert("Steam Integration Installed", "When you click Play in Steam, it will now open BO3 Launcher.\n\nTo start the game in one click instead, turn on \"Steam's Play Starts the Game\" in Options.")
        } catch let error as NSError {
            // Put the original back, so a failed install doesn't leave Steam's
            // Play button with nothing to run.
            if fm.fileExists(atPath: backupPath) {
                try? fm.removeItem(atPath: appBundleExe)
                try? fm.moveItem(atPath: backupPath, toPath: appBundleExe)
            }
            showAlert("Install Failed", permissionMessage(for: error, path: appBundleExe))
        }
    }

    static func uninstallSteamIntegration() {
        let appBundleExe = appBundleExePath
        let backupPath = appBundleExeBackupPath

        guard FileManager.default.fileExists(atPath: backupPath) else {
            showAlert("No Backup Found", "Cannot restore — no backup of the original launcher was found.")
            return
        }

        do {
            if FileManager.default.fileExists(atPath: appBundleExe) {
                try FileManager.default.removeItem(atPath: appBundleExe)
            }
            try FileManager.default.moveItem(atPath: backupPath, toPath: appBundleExe)
            NotificationCenter.default.post(name: steamIntegrationChanged, object: nil)
            showAlert("Steam Integration Removed", "The original launcher has been restored. Steam will open the default Aspyr launcher again.")
        } catch let error as NSError {
            showAlert("Restore Failed", permissionMessage(for: error, path: appBundleExe))
        }
    }

    private static func permissionMessage(for error: NSError, path: String) -> String {
        if error.domain == NSCocoaErrorDomain &&
           (error.code == NSFileWriteNoPermissionError || error.code == NSFileReadNoPermissionError) {
            return "Permission denied for:\n\(path)\n\nTry running the app as an administrator, or check that your user has write access to the game folder."
        }
        return error.localizedDescription
    }

    private static func showAlert(_ title: String, _ message: String) {
        let alert = NSAlert()
        alert.messageText = title
        alert.informativeText = message
        alert.runModal()
    }

    /// Read from the bundle, never written out as a literal. A hardcoded string
    /// here went stale and the launcher reported v1.1.0 for three releases.
    /// The fork numbers its releases from 2.0.0, apart from redxam's 1.x, and
    /// says so next to the number.
    static var gameVersion: String {
        "v" + (Bundle.main.infoDictionary?["CFBundleShortVersionString"] as? String ?? "0.0.0") + " · fork"
    }
}
