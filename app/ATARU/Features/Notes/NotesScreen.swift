import SwiftUI

/// Everything spoken into the app, newest first.
///
/// One button does the whole feature: hit record, talk, hit stop. The note
/// that lands carries an executive summary and the points underneath it — see
/// `NoteDigest`, and note especially that none of this asks the assistant
/// anything.
struct NotesScreen: View {
    @StateObject private var store = NoteStore()
    @StateObject private var recorder = NoteRecorder()
    @State private var justSaved: Note?

    var body: some View {
        ScrollView {
            LazyVStack(spacing: Theme.Space.m) {
                if let failure = store.failure {
                    // Never the empty state on top of a file problem: "No
                    // notes yet" over an unreadable file says the notes are
                    // gone when they are sitting on the disk.
                    Label(failure, systemImage: "exclamationmark.triangle")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.amber)
                        .fixedSize(horizontal: false, vertical: true)
                        .frame(maxWidth: .infinity, alignment: .leading)
                        .padding(.top, Theme.Space.s)
                }
                if store.notes.isEmpty {
                    if store.failure == nil { empty }
                } else {
                    ForEach(store.notes) { note in
                        NavigationLink(value: note) {
                            NoteCard(note: note)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
            .padding(.horizontal, Theme.Space.screen)
            .padding(.bottom, Theme.Space.l)
        }
        .navigationTitle("Notes")
        .navigationBarTitleDisplayMode(.inline)
        .navigationDestination(for: Note.self) { note in
            NoteDetailView(note: note, store: store)
        }
        // The recorder rides above the list rather than inside it, so it stays
        // put while the notes scroll under it.
        .safeAreaInset(edge: .bottom) {
            NoteRecorderBar(recorder: recorder) { note in
                store.add(note)
                // "Saved" only when it was. A write that failed puts its own
                // line at the top of the list instead.
                justSaved = store.failure == nil ? note : nil
            }
        }
        .overlay(alignment: .top) {
            if let justSaved {
                SavedToast(title: justSaved.title)
                    .padding(.top, Theme.Space.xs)
                    .transition(.move(edge: .top).combined(with: .opacity))
                    .task {
                        try? await Task.sleep(nanoseconds: 2_200_000_000)
                        withAnimation(.easeOut(duration: 0.25)) { self.justSaved = nil }
                    }
            }
        }
        .animation(.spring(response: 0.3, dampingFraction: 0.85), value: justSaved)
    }

    private var empty: some View {
        VStack(spacing: Theme.Space.s) {
            Image(systemName: "waveform.badge.mic")
                .font(.system(size: 34, weight: .ultraLight))
                .foregroundStyle(Theme.cyanSubdued)
            Text("No notes yet")
                .font(.ataruTitle())
                .foregroundStyle(Theme.textPrimary)
            Text("Hit record and talk. ATARU writes it down, pulls out a summary, and keeps the points underneath — it does not answer back.")
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
                .multilineTextAlignment(.center)
        }
        .padding(.top, Theme.Space.xl)
        .padding(.horizontal, Theme.Space.m)
    }
}

// MARK: - List card

private struct NoteCard: View {
    let note: Note

    var body: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                Text(note.title)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textPrimary)
                    .lineLimit(2)
                    .multilineTextAlignment(.leading)

                if let first = note.digest.bullets.first {
                    Text(first)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textSecondary)
                        .lineLimit(2)
                        .multilineTextAlignment(.leading)
                }

                HStack(spacing: Theme.Space.xs) {
                    Text(note.createdAt, format: .dateTime.month().day().hour().minute())
                    Text("·")
                    Text(progress)
                    if note.duration >= 1 {
                        Text("·")
                        Text(Self.length.string(from: note.duration) ?? "")
                    }
                    Spacer(minLength: 0)
                }
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .padding(Theme.Space.m)
        }
    }

    /// Done out of total, because a note you have half worked through is a
    /// different thing from one you have not opened.
    private var progress: String {
        let total = note.tasks.count
        guard total > 0 else { return "no items" }
        let done = note.tasks.filter(\.isDone).count
        return done == 0 ? "\(total) to do" : "\(done)/\(total) done"
    }

    private static let length: DateComponentsFormatter = {
        let formatter = DateComponentsFormatter()
        formatter.allowedUnits = [.minute, .second]
        formatter.unitsStyle = .positional
        formatter.zeroFormattingBehavior = .pad
        return formatter
    }()
}

// MARK: - Toast

private struct SavedToast: View {
    let title: String

    var body: some View {
        Label("Saved “\(title)”", systemImage: "checkmark.circle")
            .font(.ataruCaption())
            .foregroundStyle(Theme.textPrimary)
            .lineLimit(1)
            .padding(.horizontal, Theme.Space.m)
            .padding(.vertical, Theme.Space.s)
            .background(Ataru.metal, in: Capsule())
            .overlay { Capsule().strokeBorder(Theme.cyanSubdued, lineWidth: 1) }
            .padding(.horizontal, Theme.Space.screen)
    }
}
