import SwiftUI

/// What came back from the picker.
enum GymExerciseChoice {
    /// A row of openGym's own catalogue. Written into the routine with the
    /// catalogue's id and NOTHING added to `customEx` - the same entry the web
    /// app writes when the same exercise is picked there.
    case library(GymLibraryEntry)
    /// A name the catalogue does not have. Becomes a real openGym custom
    /// exercise, exactly as it did before there was a picker.
    case custom(String)
}

/// Pick an exercise to add to a routine.
///
/// ## Why this replaced a text field
///
/// The routine editor used to add by name, because the catalogue was not
/// reachable from the phone. Adding by name always creates a CUSTOM exercise,
/// so typing "barbell squat" - which openGym has had all along, at id
/// `"0043"` - produced a private second copy with a different id, no body
/// part, no equipment and no animation, that no other client could match
/// against. The picker makes the common case the correct one.
///
/// ## Searching 1324 rows as he types
///
/// The list is rendered in the server's order and never re-sorted: openGym
/// sorts case-folded with the id as the tiebreak, and a naive Swift sort over
/// a lower-case dataset puts `"3/4 sit-up"` somewhere else entirely, so a
/// picker that re-sorted would disagree with every other view of the same
/// list. Unsearched, it is capped rather than fully drawn - a `LazyVStack` of
/// 1324 rows each holding a thumbnail is 1324 image requests waiting to
/// happen.
///
/// His own custom exercises come first. There are a handful of them, they are
/// his, and they are merged in from the state document rather than from the
/// cached catalogue so one added two minutes ago in the browser is not hidden
/// by a day-old cache.
struct GymExercisePicker: View {
    @ObservedObject var store: GymStore
    let onPick: (GymExerciseChoice) -> Void

    @State private var query = ""
    @State private var custom = ""
    @FocusState private var isNamingCustom: Bool

    var body: some View {
        ScrollView {
            LazyVStack(alignment: .leading, spacing: Theme.Space.xs) {
                searchField

                if store.library == nil {
                    InlineNote(text: "The built-in catalogue hasn't loaded. Your "
                               + "own exercises are still here, and a new custom "
                               + "one can be created below.")
                }

                let matches = store.searchableExercises(matching: query)
                if matches.isEmpty {
                    Text(query.isEmpty
                         ? "Nothing to pick from yet."
                         : "Nothing matches \"\(query)\".")
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .padding(.vertical, Theme.Space.s)
                } else {
                    ForEach(matches) { entry in
                        row(entry)
                    }
                }

                customCard
            }
            .padding(Theme.Space.screen)
        }
        .ataruBackdrop()
        .navigationTitle("Add exercise")
        .navigationBarTitleDisplayMode(.inline)
        .dismissableNumberPads()
    }

    // MARK: Search

    private var searchField: some View {
        HStack(spacing: Theme.Space.xs) {
            Image(systemName: "magnifyingglass")
                .font(.system(size: 13, weight: .regular))
                .foregroundStyle(Theme.textTertiary)
            TextField("Name, body part or equipment", text: $query)
                .font(.ataruBody())
                .foregroundStyle(Theme.textPrimary)
                .autocorrectionDisabled()
                .textInputAutocapitalization(.never)
                .submitLabel(.search)
            if !query.isEmpty {
                Button {
                    query = ""
                } label: {
                    Image(systemName: "xmark.circle.fill")
                        .font(.system(size: 14))
                        .foregroundStyle(Theme.textTertiary)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Clear the search")
            }
        }
        .padding(.horizontal, Theme.Space.s)
        .frame(height: Theme.minHitTarget)
        .background {
            RoundedRectangle(cornerRadius: Theme.Radius.small, style: .continuous)
                .fill(Theme.surfaceElevated)
        }
        .padding(.bottom, Theme.Space.xs)
    }

    // MARK: A row

    /// Thumbnail, name, what it works - and two separate targets: the demo,
    /// and adding it.
    ///
    /// Two rather than one because "show me what this is" and "put it in my
    /// routine" are different intentions, and a picker where looking at
    /// something adds it is a picker that adds things by accident.
    private func row(_ entry: GymLibraryEntry) -> some View {
        ATCard {
            HStack(spacing: Theme.Space.s) {
                NavigationLink {
                    GymExerciseDetail(name: entry.name, entry: entry,
                                      gifURL: store.library?.gifURL(for: entry))
                } label: {
                    GymExerciseThumbnail(url: store.library?.gifURL(for: entry))
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Preview \(entry.name)")

                VStack(alignment: .leading, spacing: 1) {
                    Text(entry.name)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                        .lineLimit(2)
                    Text(entry.gif == nil && entry.tagline.isEmpty
                         ? "your own exercise" : entry.tagline)
                        .font(.ataruCaption())
                        .foregroundStyle(Theme.textTertiary)
                        .lineLimit(1)
                }
                Spacer(minLength: Theme.Space.xs)

                Button {
                    onPick(.library(entry))
                } label: {
                    Image(systemName: "plus.circle")
                        .font(.system(size: 20, weight: .light))
                        .foregroundStyle(Theme.cyan)
                        .hitTarget()
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Add \(entry.name)")
            }
            .padding(Theme.Space.s)
        }
    }

    // MARK: Custom

    /// At the BOTTOM, deliberately. A custom exercise is the answer for a name
    /// the catalogue does not have, and putting it first is what made every
    /// exercise a custom one.
    private var customCard: some View {
        ATCard {
            VStack(alignment: .leading, spacing: Theme.Space.s) {
                SectionHeader(text: "Not in the list")
                HStack(spacing: Theme.Space.s) {
                    TextField("Create custom", text: $custom)
                        .font(.ataruBody())
                        .foregroundStyle(Theme.textPrimary)
                        .focused($isNamingCustom)
                        .autocorrectionDisabled()
                        .padding(.horizontal, Theme.Space.s)
                        .frame(height: Theme.minHitTarget)
                        .background {
                            RoundedRectangle(cornerRadius: Theme.Radius.small,
                                             style: .continuous)
                                .fill(Theme.surfaceElevated)
                        }
                        .accessibilityLabel("Name of a new custom exercise")
                    Button("Create") {
                        isNamingCustom = false
                        onPick(.custom(custom))
                    }
                    .font(.ataruBody())
                    .foregroundStyle(canCreate ? Theme.cyan : Theme.textTertiary)
                    .frame(minHeight: Theme.minHitTarget)
                    .disabled(!canCreate)
                }
                Text("Added to your profile's own catalogue, with no animation "
                     + "- openGym's built-in media only covers its own 1324.")
                    .font(.ataruCaption())
                    .foregroundStyle(Theme.textTertiary)
            }
            .padding(Theme.Space.m)
        }
        .padding(.top, Theme.Space.s)
    }

    private var canCreate: Bool {
        !custom.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
    }
}
