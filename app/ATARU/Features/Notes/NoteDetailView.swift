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
    @State private var isParsing = false
    @EnvironmentObject private var state: AppState
    @Environment(\.dismiss) private var dismiss

    /// The store's copy, not the one this view was constructed with - ticking a
    /// box has to redraw, and the `note` parameter is a value that never
    /// changes. Falls back to that value while a delete is animating out.
    private var live: Note { store.note(id: note.id) ?? note }

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
        // Progressive enhancement, and it must stay that way: the note already
        // has tickable items from its own bullets, so this only ever upgrades
        // them. A backend without the route throws notFound, nothing changes,
        // and the user never learns there was a server involved.
        .task {
            guard !live.isParsed, !live.tasks.isEmpty else { return }
            isParsing = true
            defer { isParsing = false }
            do {
                let parsed = try await state.service.parseTasks(transcript: live.transcript)
                if parsed.isEmpty {
                    store.markParsed(live)
                } else {
                    store.adopt(parsed, for: live)
                }
            } catch {
                // Left unparsed on purpose, so the next launch tries again -
                // the server being down once should not cost this note its
                // structure forever.
            }
        }
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
                HStack(spacing: Theme.Space.xs) {
                    SectionLabel(text: "To do")
                    Spacer(minLength: 0)
                    if isParsing {
                        ProgressView().controlSize(.mini).tint(Theme.textTertiary)
                    }
                }
                VStack(alignment: .leading, spacing: Theme.Space.xs) {
                    ForEach(live.tasks) { task in
                        TaskRow(task: task) { done in
                            store.setTask(task, done: done, in: live)
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
        var lines = [live.title, ""]
        if let summary = live.digest.summary.nilIfBlank {
            lines += [summary, ""]
        }
        // Ticked state travels: a shared list that has lost which half is done
        // is a list the reader has to ask about.
        lines += live.tasks.map { "\($0.isDone ? "[x]" : "[ ]") \($0.title)" }
        return lines.joined(separator: "\n")
    }
}

/// One tickable item.
private struct TaskRow: View {
    let task: NoteTask
    let setDone: (Bool) -> Void

    var body: some View {
        Button {
            setDone(!task.isDone)
            Haptics.fire(.selection)
        } label: {
            HStack(alignment: .top, spacing: Theme.Space.s) {
                Image(systemName: task.isDone ? "checkmark.circle.fill" : "circle")
                    .font(.system(size: 19, weight: .light))
                    .foregroundStyle(task.isDone ? Theme.cyan : Theme.textTertiary)
                    // Aligned to the first line of a title that may wrap.
                    .padding(.top, 1)

                VStack(alignment: .leading, spacing: 3) {
                    Text(task.title)
                        .font(.ataruBody())
                        .foregroundStyle(task.isDone ? Theme.textTertiary : Theme.textPrimary)
                        .strikethrough(task.isDone, color: Theme.textTertiary)
                        .fixedSize(horizontal: false, vertical: true)
                        .multilineTextAlignment(.leading)

                    if !task.subtasks.isEmpty {
                        ForEach(task.subtasks, id: \.self) { step in
                            Text("– \(step)")
                                .font(.ataruCaption())
                                .foregroundStyle(Theme.textTertiary)
                                .multilineTextAlignment(.leading)
                        }
                    }

                    if let detail = metadata {
                        Text(detail)
                            .font(.ataruCaption())
                            .foregroundStyle(Theme.cyanSubdued)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .accessibilityIdentifier("task-\(task.title.prefix(24))")
        .accessibilityAddTraits(task.isDone ? [.isButton, .isSelected] : .isButton)
    }

    /// Only what the model actually established. A due date invented for every
    /// task would make the real ones invisible.
    private var metadata: String? {
        var parts: [String] = []
        if let due = task.dueDate {
            parts.append(task.hasTimeTrigger
                         ? due.formatted(.dateTime.month().day().hour().minute())
                         : due.formatted(.dateTime.month().day()))
        }
        if let minutes = task.estimatedMinutes, minutes > 0 {
            parts.append("\(minutes) min")
        }
        if task.category.caseInsensitiveCompare("Personal") != .orderedSame {
            parts.append(task.category)
        }
        return parts.isEmpty ? nil : parts.joined(separator: " · ")
    }
}
