import SwiftUI

/// One note: the summary and its points, with the raw dictation behind a tab.
///
/// ## Why the transcript is a separate tab rather than a section
///
/// The summary and the points are a *reading* of the recording; the transcript
/// is the recording. Putting them in one scroll makes the page mostly the
/// thing nobody came to read — a two-minute note is a wall of unpunctuated
/// speech — while burying it entirely would mean the derived text is the only
/// copy, and this digest is heuristic. It is right there, one tap away, and it
/// is what gets shared.
struct NoteDetailView: View {
    let note: Note
    @ObservedObject var store: NoteStore

    private enum Pane: String, CaseIterable, Identifiable {
        case notes = "Notes"
        case transcript = "Transcript"
        var id: String { rawValue }
    }

    @State private var pane: Pane = .notes
    @State private var isConfirmingDelete = false
    @Environment(\.dismiss) private var dismiss

    var body: some View {
        VStack(spacing: 0) {
            Picker("View", selection: $pane) {
                ForEach(Pane.allCases) { pane in
                    Text(pane.rawValue).tag(pane)
                }
            }
            .pickerStyle(.segmented)
            .padding(.horizontal, Theme.Space.screen)
            .padding(.bottom, Theme.Space.s)
            .accessibilityIdentifier("note-pane")

            ScrollView {
                switch pane {
                case .notes:      digest
                case .transcript: transcript
                }
            }
        }
        .navigationTitle(note.title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) {
                Menu {
                    ShareLink(item: shareText) {
                        Label("Share", systemImage: "square.and.arrow.up")
                    }
                    Button(role: .destructive) {
                        isConfirmingDelete = true
                    } label: {
                        Label("Delete", systemImage: "trash")
                    }
                } label: {
                    Image(systemName: "ellipsis.circle")
                }
                .accessibilityLabel("Note options")
            }
        }
        .confirmationDialog("Delete this note?", isPresented: $isConfirmingDelete,
                            titleVisibility: .visible) {
            Button("Delete", role: .destructive) {
                store.delete(note)
                dismiss()
            }
        } message: {
            Text("The recording was never kept, so the transcript goes with it.")
        }
    }

    // MARK: - Panes

    private var digest: some View {
        VStack(alignment: .leading, spacing: Theme.Space.m) {
            if let summary = note.digest.summary.nilIfBlank {
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    SectionLabel(text: "Summary")
                    ATCard {
                        Text(summary)
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textPrimary)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                            .padding(Theme.Space.m)
                    }
                }
            }

            VStack(alignment: .leading, spacing: Theme.Space.xs) {
                SectionLabel(text: "Notes")
                VStack(alignment: .leading, spacing: Theme.Space.s) {
                    ForEach(Array(note.digest.bullets.enumerated()), id: \.offset) { _, bullet in
                        HStack(alignment: .top, spacing: Theme.Space.s) {
                            Circle()
                                .fill(Theme.cyanSubdued)
                                .frame(width: 5, height: 5)
                                // Sits on the first line's baseline rather than
                                // centred on a bullet that may wrap to four.
                                .padding(.top, 7)
                            Text(bullet)
                                .font(.ataruBody())
                                .foregroundStyle(Theme.textSecondary)
                                .fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
            }

            Text(note.createdAt, format: .dateTime.weekday(.wide).month().day()
                .hour().minute())
                .font(.ataruCaption())
                .foregroundStyle(Theme.textTertiary)
                .padding(.top, Theme.Space.xs)
        }
        .padding(.horizontal, Theme.Space.screen)
        .padding(.bottom, Theme.Space.l)
    }

    @ViewBuilder
    private var transcript: some View {
        VStack(alignment: .leading, spacing: Theme.Space.s) {
            SectionLabel(text: "As spoken")

            if let turns = note.turns, note.hasMultipleSpeakers {
                // Attributed only when the app can actually tell, which is
                // rarer than it sounds - SpeakerSplit returns nil unless two
                // clusters are genuinely separated.
                ForEach(Array(turns.enumerated()), id: \.offset) { _, turn in
                    VStack(alignment: .leading, spacing: 2) {
                        Text(turn.speaker.label)
                            .font(.ataruCaption())
                            .foregroundStyle(turn.speaker == .you
                                             ? Theme.cyan : Theme.textTertiary)
                        Text(turn.text)
                            .font(.ataruBody())
                            .foregroundStyle(Theme.textSecondary)
                            .textSelection(.enabled)
                            .fixedSize(horizontal: false, vertical: true)
                            .frame(maxWidth: .infinity, alignment: .leading)
                    }
                    .padding(.bottom, Theme.Space.xs)
                }
            } else {
                Text(note.transcript)
                    .font(.ataruBody())
                    .foregroundStyle(Theme.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.horizontal, Theme.Space.screen)
        .padding(.bottom, Theme.Space.l)
    }

    /// What leaves the app when the user asks it to — and the only way any of
    /// this ever does.
    private var shareText: String {
        var lines = [note.title, ""]
        if let summary = note.digest.summary.nilIfBlank {
            lines += [summary, ""]
        }
        lines += note.digest.bullets.map { "• \($0)" }
        return lines.joined(separator: "\n")
    }
}
