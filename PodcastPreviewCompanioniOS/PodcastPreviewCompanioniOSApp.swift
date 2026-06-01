import PodcastPreviewShared
import SwiftUI

@main
struct PodcastPreviewCompanioniOSApp: App {
    @Environment(\.scenePhase) private var scenePhase
    @StateObject private var store = CloudKitCompanionStore()

    var body: some Scene {
        WindowGroup {
            CompanionRootView()
                .environmentObject(store)
                .applyThemeEnvironment()
                .themeAppearance(.graphite)
                .environment(\.accentStyle, ThemeAccentStyle.blue)
                .preferredColorScheme(.dark)
        }
        .onChange(of: scenePhase) { _, newPhase in
            switch newPhase {
            case .active:
                store.refresh()
                store.startAutoRefresh()
            case .inactive, .background:
                store.stopAutoRefresh()
            @unknown default:
                store.stopAutoRefresh()
            }
        }
    }
}
