import SwiftUI

struct ContentView: View {
    @State private var selectedTab: LauncherTab = .whatsNew
    @State private var installType = Paths.installType

    var body: some View {
        VStack(spacing: 0) {
            if installType == .none {
                HeaderView(selectedTab: $selectedTab, gameMissing: true)
                SetupView { installType = Paths.installType }
            } else {
                HeaderView(selectedTab: $selectedTab, gameMissing: false)

                switch selectedTab {
                case .whatsNew:
                    WhatsNewView()
                case .mods:
                    ModsView()
                }
            }
        }
        .background(Theme.bgDark)
        .onAppear { installType = Paths.installType }
        // Covers players who installed Wine before BO3MacFix, or by hand.
        .task { await WineInstaller.shared.prepareWinePrefixIfNeeded() }
    }
}
