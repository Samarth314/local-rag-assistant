import SwiftUI

/// Where the server lives, and the two buttons about calls.
///
/// ## What was taken out, and why
///
/// **Demo mode.** "Is there any point in having a demo page. Samarth has his
/// testing URL and so do I so don't see any need for demo." He is right: the
/// dev twin is a URL, production is a URL, and a mode switch on top of that was
/// a second way to express the same choice - one that could disagree with the
/// address in the field directly above it. A URL is a URL now. The Demo service
/// survives as the app's fallback for an unconfigured or malformed address (see
/// `AppState.rebuildService`) and as what the previews and tests run against,
/// but nothing about it is user-facing any more.
///
/// **The Privacy section.** Three sentences of reassurance on a screen only its
/// author ever opens.
///
/// **On-phone transcription.** Removed on measurement: the server path is
/// faster and knows the names, and he keeps the toggle off. See the commit for
/// the tradeoff that goes with it.
struct SettingsView: View {
    @EnvironmentObject private var state: AppState
    @EnvironmentObject private var call: CallService
    // The push service publishes the token and the last registration error;
    // without this row a phone that cannot be rung looks identical to one
    // that can, right up until 7am when it doesn't ring.
    @ObservedObject private var push = CallStack.shared.push

    @State private var baseURL: String = ""
    @State private var token: String = ""
    @State private var isAddingContact = false
    @State private var contactStatus: String?
    @State private var contactFailed = false
    /// The vCard to hand to the share sheet, built on demand. Non-nil is what
    /// presents the sheet - see `ATARUContact`, and note that nothing in that
    /// path touches the address book.
    @State private var contactCard: ATARUContact.Card?

    var body: some View {
        Form {
            Section("Server") {
                TextField("https://ataru.your-tailnet.ts.net", text: $baseURL)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .keyboardType(.URL)
                    .onSubmit(apply)
                    .dismissExclusion()

                if let message = validation.message {
                    Label(message, systemImage: "exclamationmark.triangle")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                }

                SecureField("Access token (optional)", text: $token)
                    .textInputAutocapitalization(.never)
                    .autocorrectionDisabled()
                    .dismissExclusion()

                Button(action: apply) {
                    Text("Save and test")
                }
                .disabled(!validation.isValid)

                connectionRow
            }

            Section("On this device") {
                Button("Delete downloaded files and cached pages", role: .destructive) {
                    state.purgeDownloads(includingCachedTiles: true)
                    Haptics.fire(.success)
                }
                Text("Documents are downloaded only when you preview or send them, and are deleted automatically when ATARU goes to the background. This also clears the last page each tile drew from, which is kept so a tile opens with something on it.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }

            Section("Calls") {
                Button("Add ATARU to Contacts") {
                    addContact()
                }
                .disabled(isAddingContact)

                if let contactStatus {
                    Text(contactStatus)
                        .font(.ataruCaption())
                        .foregroundStyle(contactFailed ? Theme.amber : Theme.green)
                }

                Text("Hands iOS a contact card for ATARU, so you can call it like a person - from Contacts, the Phone app or Siri. ATARU appears as a calling option on that card after the first call; iOS only lists an app once it has seen one.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)

                Button("Test call") {
                    call.reportIncomingCall(after: 5)
                    Haptics.fire(.tap)
                }
                .disabled(call.state.isLive)
                Text("Rings in 5 seconds, so you can check the call screen without waiting for the contact entry to appear. Lock the phone after tapping - the system only takes over the screen when ATARU isn't already in front.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)

                #if DEBUG
                // Development only. The Simulator declines a reported incoming
                // call within about a second, so the ring path cannot be seen
                // there at all - an outgoing call is the only way to exercise
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
        }
        .scrollContentBackground(.hidden)
        .ataruBackdrop()
        .navigationTitle("Settings")
        .navigationBarTitleDisplayMode(.inline)
        .sheet(item: $contactCard) { card in
            // The system's own sheet. "Add to Contacts" appears in it because
            // the item is a vCard, and iOS - not this app - writes the entry.
            ActivityView(items: [card.fileURL]) {
                contactFailed = false
                contactStatus = "Handed to iOS. Choose Add to Contacts."
            }
            .ignoresSafeArea()
        }
        .onAppear {
            baseURL = state.configuration.baseURLString
            token = state.token ?? ""
        }
    }

    /// Builds the card and hands it to the share sheet.
    ///
    /// No permission prompt, because nothing here reads the address book. See
    /// ATARUContact for the whole argument.
    private func addContact() {
        isAddingContact = true
        defer { isAddingContact = false }
        do {
            contactCard = try ATARUContact.card()
            Haptics.fire(.tap)
        } catch {
            contactFailed = true
            contactStatus = (error as? LocalizedError)?.errorDescription
                ?? error.localizedDescription
            Haptics.fire(.warning)
        }
    }

    private var validation: BaseURLValidation {
        AppConfiguration.validate(baseURL)
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
        // ONE change, not two. Setting the token and then the address rebuilt
        // the service twice, and the first rebuild paired the new token with
        // the OLD address - which is where it then registered push. See
        // AppState.apply.
        state.apply(configuration: configuration,
                    token: token.isEmpty ? nil : token)
        Task {
            await state.refreshConnection()
            Haptics.fire(state.connection.isConnected ? .success : .warning)
        }
    }
}

/// The system share sheet, for handing a file to iOS.
///
/// Deliberately thin: it exists so a vCard can be given to the OS without this
/// app ever asking for the address book. `onPresented` fires once the sheet is
/// up, which is the last moment this app knows anything about what happens
/// next - what the user picks in there is between them and iOS.
private struct ActivityView: UIViewControllerRepresentable {
    let items: [Any]
    var onPresented: () -> Void = {}

    func makeUIViewController(context: Context) -> UIActivityViewController {
        let controller = UIActivityViewController(activityItems: items,
                                                  applicationActivities: nil)
        DispatchQueue.main.async { onPresented() }
        return controller
    }

    func updateUIViewController(_ controller: UIActivityViewController, context: Context) {}
}

#Preview {
    NavigationStack {
        SettingsView().environmentObject(AppState())
    }
}
