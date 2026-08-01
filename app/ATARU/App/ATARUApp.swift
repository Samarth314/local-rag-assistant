import SwiftUI

@main
struct ATARUApp: App {
    @StateObject private var state = AppState()
    @Environment(\.scenePhase) private var scenePhase
    @AppStorage("hasRequestedVoicePermissions") private var hasRequestedVoicePermissions = false

    /// Catches an `INStartCallIntent` delivered at launch. Tapping ATARU in
    /// Recents starts the app cold, and that activity can arrive before any
    /// view exists to receive it — see `PendingCallRequest`.
    @UIApplicationDelegateAdaptor(CallLaunchDelegate.self) private var callLaunch

    var body: some Scene {
        WindowGroup {
            RootView(state: state)
                .environmentObject(state)
                .preferredColorScheme(.dark)
                .tint(Theme.cyan)
                .task {
                    // Voice is the app's front door, so the speech and
                    // microphone consent dialogs belong to the first launch,
                    // not the middle of the first call. iOS will not grant
                    // either without showing its dialog; asking here is the
                    // closest the platform allows to "assumed on install".
                    guard !hasRequestedVoicePermissions else { return }
                    hasRequestedVoicePermissions = true
                    _ = await SpeechDictation.requestAuthorization()
                }
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
