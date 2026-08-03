import SwiftUI

/// Connection settings and the privacy facts that go with them.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var call: CallService
    // The push service publishes the token and the last registration error;
    // without this row a phone that cannot be rung looks identical to one
    // that can, right up until 8am when it doesn't ring.
    @ObservedObject private var push = CallStack.shared.push

    @State private var baseURL: String = ""
    @State private var token: String = ""
    @State private var isTesting = false
    @State private var isAddingContact = false
    @State private var contactStatus: String?
    @State private var contactFailed = false

    // The rendered label rather than the state: the state stops changing while
    // a load runs, but the label carries the load's elapsed seconds, and a row
    // that only updates when the state changes would freeze at the moment it
    // most needs to be moving.
    @State private var whisperLabel = WhisperTranscriber.State.idle.label
    @State private var whisperStuck = false
    @AppStorage(WhisperTranscriber.offlineKey) private var offlineTranscription = false

    var body: some View {
        Form {
            Section {
                Picker("Mode", selection: modeBinding) {
                    ForEach(AppEnvironmentMode.allCases) { mode in
                        Text(mode.title).tag(mode)
                    }
                }
                .pickerStyle(.segmented)
            } header: {
                Text("Source")
            } footer: {
                Text(state.configuration.mode == .demo
                     ? "Demo answers from bundled sample files. Nothing leaves this device."
                     : "Live connects to your own ATARU server over your Tailnet or LAN.")
            }

            if state.configuration.mode == .live {
                Section("Server") {
                    TextField("http://100.x.y.z:8000", text: $baseURL)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .onSubmit(apply)

                    if let message = validation.message {
                        Label(message, systemImage: "exclamationmark.triangle")
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.amber)
                    }

                    SecureField("Access token (optional)", text: $token)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()

                    Button(action: apply) {
                        Text("Save and test")
                    }
                    .disabled(!validation.isValid)

                    connectionRow
                }
            }

            Section("Dictation") {
                // Which engine actually produced the last transcript. Whisper
                // is the one that can be told a name is likely; until its
                // model has downloaded, Apple's recogniser is standing in, and
                // without this row that difference is invisible.
                Text(offlineTranscription
                     ? whisperLabel
                     : "ATARU transcribes on your own server, biased toward the names it knows.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textSecondary)

                Toggle("Also transcribe on this phone", isOn: $offlineTranscription)
                Text("Off, dictation goes to ATARU's server, which already has the model loaded and knows who you talk to. On, the phone downloads its own copy so dictation still works away from your network - it is ~630MB and takes about a minute to load every time the app starts cold.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)

                if offlineTranscription && whisperStuck {
                    Button("Load the model again") {
                        WhisperTranscriber.shared.prepare(retry: true)
                        Haptics.fire(.success)
                    }
                }
            }

            Section("On this device") {
                Button("Delete downloaded documents", role: .destructive) {
                    state.purgeDownloads()
                    Haptics.fire(.success)
                }
                Text("Documents are downloaded only when you preview or send them, and are deleted automatically when ATARU goes to the background.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }

            Section("Calls") {
                Button("Add ATARU to Contacts") {
                    Task { await addContact() }
                }
                .disabled(isAddingContact)

                if let contactStatus {
                    Text(contactStatus)
                        .font(.ataruCaption())
                        .foregroundStyle(contactFailed ? Theme.amber : Theme.green)
                }

                Text("Creates a contact card for ATARU so you can call it like a person — from Contacts, the Phone app or Siri. ATARU appears as a calling option on that card after the first call; iOS only lists an app once it has seen one.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)

                Button("Test call") {
                    call.reportIncomingCall(after: 5)
                    Haptics.fire(.tap)
                }
                .disabled(call.state.isLive)
                Text("Rings in 5 seconds, so you can check the call screen without waiting for the contact entry to appear. Lock the phone after tapping — the system only takes over the screen when ATARU isn't already in front.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)

                #if DEBUG
                // Development only. The Simulator declines a reported incoming
                // call within about a second, so the ring path cannot be seen
                // there at all — an outgoing call is the only way to exercise
                // the call UI without a device.
                Button("Start a call (debug)") { call.call() }
                    .disabled(call.state.isLive)
                #endif

                if let error = push.registrationError {
                    Label(error, systemImage: "bell.slash")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                } else if push.token != nil {
                    Label("ATARU can ring this phone (\(VoIPPushService.environment) push registered).",
                          systemImage: "bell.badge")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.green)
                } else {
                    Text("No push token yet - iOS hasn't issued one. The build needs the Push Notifications entitlement, and the server must be reachable once so the phone can register.")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                }
            }

            Section("Privacy") {
                PrivacyFact("Questions and answers go only to the server you configure above. There is no analytics endpoint in this app.")
                PrivacyFact("Dictation is transcribed on device. ATARU never sends your audio to Apple for transcription.")
                PrivacyFact("Your access token is stored in the Keychain, never in preferences or logs.")
            }
        }
        .scrollContentBackground(.hidden)
        .ataruBackdrop()
        .task {
            // Polls rather than observes: the transcriber is lock-based, not
            // observable, and this row only has to be right while someone is
            // looking at it.
            while !Task.isCancelled {
                // Turning it on here is the one place a load should start
                // mid-session, so the row means something immediately rather
                // than at the next launch.
                if offlineTranscription { WhisperTranscriber.shared.prepare() }
                let current = WhisperTranscriber.uiState
                whisperLabel = current.label
                // Two minutes is well past a healthy load, so past it the
                // offer to start over is more useful than watching the counter.
                whisperStuck = {
                    if case .failed = current { return true }
                    return (WhisperTranscriber.shared.prepareElapsed ?? 0) > 120
                }()
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .onAppear {
            baseURL = state.configuration.baseURLString
            token = state.token ?? ""
        }
    }

    private func addContact() async {
        isAddingContact = true
        defer { isAddingContact = false }
        do {
            try await ATARUContact.add()
            contactFailed = false
            contactStatus = "Added. Find ATARU in Contacts."
            Haptics.fire(.success)
        } catch {
            // "Already exists" is reported the same way as a real failure on
            // purpose: from the user's side both mean "the button did not do
            // what you expected", and both are resolved by looking in Contacts.
            contactFailed = true
            contactStatus = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
        }
    }

    private var validation: BaseURLValidation {
        AppConfiguration.validate(baseURL)
    }

    private var modeBinding: Binding<AppEnvironmentMode> {
        Binding(
            get: { state.configuration.mode },
            set: { newMode in
                var configuration = state.configuration
                configuration.mode = newMode
                state.configuration = configuration
                Task { await state.refreshConnection() }
            }
        )
    }

    @ViewBuilder
    private var connectionRow: some View {
        HStack(spacing: Theme.Space.xs) {
            switch state.connection {
            case .unknown:
                StatusDot(tone: .unknown, label: "Not tested yet")
            case .checking:
                ProgressView().controlSize(.small)
                Text("Testing…").font(.ataruCaption()).foregroundStyle(Theme.textSecondary)
            case .connected(let detail):
                StatusDot(tone: .online, label: detail.map { "Connected — \($0)" } ?? "Connected",
                          pulses: true)
            case .failed(let message):
                StatusDot(tone: .failure, label: message)
            }
            Spacer(minLength: 0)
        }
    }

    private func apply() {
        guard validation.isValid else { return }
        var configuration = state.configuration
        configuration.baseURLString = baseURL.trimmingCharacters(in: .whitespacesAndNewlines)
        configuration.mode = .live
        state.setToken(token.isEmpty ? nil : token)
        state.configuration = configuration
        isTesting = true
        Task {
            await state.refreshConnection()
            isTesting = false
            Haptics.fire(state.connection.isConnected ? .success : .warning)
        }
    }
}

private struct PrivacyFact: View {
    let text: String
    init(_ text: String) { self.text = text }

    var body: some View {
        HStack(alignment: .top, spacing: Theme.Space.xs) {
            Image(systemName: "lock")
                .font(.system(size: 11))
                .foregroundStyle(Theme.cyanSubdued)
                .padding(.top, 2)
            Text(text)
                .font(.ataruCaption())
                .foregroundStyle(Theme.textSecondary)
                .fixedSize(horizontal: false, vertical: true)
        }
        .accessibilityElement(children: .combine)
    }
}

#Preview {
    NavigationStack {
        SettingsView().environmentObject(AppState())
    }
}
