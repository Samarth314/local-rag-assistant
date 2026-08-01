# Architecture

Feature-first, protocol-driven, MVVM where it earns its place. No dependency
injection container, no coordinator layer, no third-party packages.

## The seam

Everything data-shaped goes through one protocol:

```swift
protocol ATARUService: AnyObject, Sendable {
    func checkStatus() async throws -> String?
    func documents(query: String?, category: DocumentCategory) async throws -> DocumentLibraryPage
    func document(id: String) async throws -> IndexedDocument
    func documentContent(id: String) async throws -> DocumentPayload
    func ask(question: String) async throws -> SpokenAnswer
}
```

`LiveATARUService` talks to the backend. `DemoATARUService` serves synthetic
fixtures with simulated latency. Both are used identically by every view model,
which is why Demo is a genuine test of the app rather than a separate code path
that drifts.

`AppState` owns the current service and swaps it when the mode changes. Views
observe it and re-point their view model via `.task(id:)`.

## Layers

```
View  ──observes──▶  ViewModel  ──calls──▶  ATARUService  ──▶  DTO  ──▶  Domain
```

- **Views** are SwiftUI, hold no business logic, and read colours only through
  `Theme`.
- **View models** are `@MainActor` `ObservableObject`s holding an explicit state
  enum. State is never inferred from a set of booleans that can disagree.
- **DTOs** know the wire format (snake_case, Unix timestamps, nullable
  everything). They are the only types that do. A server-side rename is a change
  in `DTOs.swift` and nowhere else.
- **Domain models** are what the UI uses: camelCase, `Date`, `enum`.

## Pure logic is separated so it can be tested without a simulator

`DocumentQuery` (filter, sort, counts), `AppConfiguration.validate`,
`EndpointBuilder`, `DocumentDownloadStore.sanitize` and
`LiveATARUService.filename(from:)` are all pure functions over plain values.
They carry the rules most likely to be wrong, and 35 unit tests cover them
without launching anything.

The UI tests are deliberately shallow: they prove the app launches, both tabs
render real content, and the two flows the product exists for are reachable.

## State machines

**`VoicePhase`** — `idle → listening → thinking → speaking → idle`, with
`failed` reachable from anywhere. The orb, the button label, VoiceOver and the
"can I ask now?" gate all read from this one value, so they cannot disagree
about what the assistant is doing.

**`DocumentsViewModel.LoadState`** — `idle / loading / loaded / failed`.
Distinguishes "nothing indexed" from "your filter matches nothing", which are
different problems with different fixes.

**`DataFreshness`** — `live / demo / stale / offline`. Rendered as a banner on
both tabs. Cached or synthetic content is never presented as live.

## Concurrency

Swift Concurrency throughout. View models are `@MainActor`. `DocumentDownloadStore`
is an `actor` because it is shared mutable filesystem state. In-flight work is
held in a `Task` handle and cancelled when superseded — asking a second question
cancels the first rather than letting two answers race to speak.

## Audio

`SpeechDictation` wraps `AVAudioEngine` + `SFSpeechRecognizer`, pinned to
on-device recognition (see PRIVACY.md). It publishes a live transcript and an
input level; the orb reads the level directly.

`AnswerPlayer` prefers the WAV the server rendered — the same Piper voice the
telephone front door uses, so the app and the phone line sound like one
assistant — and falls back to `AVSpeechSynthesizer` when the server has no voice
engine. Its completion handler always fires, including on failure, so the orb
can always return to idle.

## Design system

`Theme` holds every colour, radius and spacing value as a semantic token. Views
never write a literal colour. Models describe *meaning* (`SemanticTone.amber`)
and stay free of SwiftUI; `SemanticTone.color` maps meaning to palette in the
design-system layer, so a retune never touches a model.

Status is never communicated by colour alone — `StatusDot` pairs colour with a
label and switches to a symbol under Differentiate Without Color. All motion is
suppressed under Reduce Motion.
