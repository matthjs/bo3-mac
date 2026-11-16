import SwiftUI
import AppKit

class AppDelegate: NSObject, NSApplicationDelegate {
    private var menuObserver: Any?

    /// Runs before the window is built, so ContentView sees a resolved path.
    func applicationWillFinishLaunching(_ notification: Notification) {
        Self.migrateSettingsFromUpstream()
        Paths.autoDetectIfNeeded()
    }

    /// This fork changed the bundle ID from upstream's `com.redxam.bo3launcher`,
    /// which moved settings to a new domain. Copy them over once, so a player
    /// switching from the original launcher keeps a custom game folder and the
    /// launch-without-Steam choice. Keys already set here win.
    private static func migrateSettingsFromUpstream() {
        let defaults = UserDefaults.standard
        let doneKey = "migratedFromUpstreamSettings"
        guard !defaults.bool(forKey: doneKey) else { return }
        if let old = defaults.persistentDomain(forName: "com.redxam.bo3launcher") {
            for (key, value) in old where defaults.object(forKey: key) == nil {
                defaults.set(value, forKey: key)
            }
        }
        defaults.set(true, forKey: doneKey)
    }

    /// Steam's Play button can open the launcher before startup is done, so
    /// the request waits for the startup prompts.
    private var startupDone = false
    private var pendingSteamPlay = false

    /// `bo3launcher://steam-play` from the Steam redirector.
    func handleOpenURL(_ url: URL) {
        guard url.scheme == "bo3launcher", url.host == "steam-play" else { return }
        if startupDone {
            GameLauncher.handleSteamPlay()
        } else {
            pendingSteamPlay = true
        }
    }

    func applicationDidFinishLaunching(_ notification: Notification) {
        stripMenuBar()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.5) {
            PermissionChecker.promptIfNeeded()
            // Without the game, the setup screen already says so. Prompting
            // here too would open with a "Game Not Found" dialog.
            if MacFixInstaller.isGamePresent {
                MacFixInstaller.promptInstallIfNeeded()
            }
            GameLauncher.resumeSteamIntegrationIfNeeded()
            self.startupDone = true
            if self.pendingSteamPlay {
                self.pendingSteamPlay = false
                GameLauncher.handleSteamPlay()
            }
        }
        menuObserver = NotificationCenter.default.addObserver(
            forName: NSMenu.didAddItemNotification,
            object: NSApp.mainMenu,
            queue: .main
        ) { [weak self] _ in self?.stripMenuBar() }
    }

    private func stripMenuBar() {
        guard let mainMenu = NSApp.mainMenu else { return }
        let removeTitles: Set<String> = ["File", "Edit", "View", "Window", "Format"]
        for item in mainMenu.items {
            let title = item.submenu?.title ?? item.title
            if removeTitles.contains(title) {
                mainMenu.removeItem(item)
            }
        }

        if let appMenu = mainMenu.items.first?.submenu {
            let keep = appMenu.items.filter {
                $0.title.lowercased().contains("about") ||
                $0.title.lowercased().contains("quit") ||
                ($0.isSeparatorItem && $0 == appMenu.items.last(where: { $0.isSeparatorItem }))
            }
            appMenu.removeAllItems()
            for item in keep { appMenu.addItem(item) }
        }
    }
}

@main
struct LauncherApp: App {
    @NSApplicationDelegateAdaptor(AppDelegate.self) var appDelegate

    var body: some Scene {
        WindowGroup {
            ContentView()
                .frame(width: 1024, height: 640)
                // Deliver bo3launcher:// URLs to this window. Without it,
                // SwiftUI opens a second window for each one.
                .handlesExternalEvents(preferring: ["*"], allowing: ["*"])
                .onOpenURL { appDelegate.handleOpenURL($0) }
        }
        .windowStyle(.hiddenTitleBar)
        .defaultSize(width: 1024, height: 640)
        .windowResizability(.contentSize)
        .commands {
            CommandGroup(replacing: .help) {
                Button("BO3 Community Discord") {
                    NSWorkspace.shared.open(URL(string: "https://discord.gg/2dw7A7p3cA")!)
                }
            }
        }
    }
}
