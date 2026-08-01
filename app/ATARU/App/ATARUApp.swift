import SwiftUI

@main
struct ATARUApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase

    /// Catches an `INStartCallIntent` delivered at launch. Tapping ATARU in
    /// Recents starts the app cold, and that activity can arrive before any
    /// view exists to receive it — see `PendingCallRequest`.
    @UIApplicationDelegateAdaptor(CallLaunchDelegate.self) private var callLaunch

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(Theme.cyan)
        }
        .onChange(of: scenePhase) { _, phase in
            // Documents pulled from the vault are discarded as soon as the app
            // leaves the foreground. They are copies of files that already live
            // on the user's own server, so there is no reason to keep them on
            // the phone between sessions.
            if phase == .background {
                state.purgeDownloads()
            }
        }
    }
}
