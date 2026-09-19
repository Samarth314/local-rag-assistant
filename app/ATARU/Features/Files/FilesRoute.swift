import Foundation

/// What an answer asked the app to open.
///
/// Pure and unit-tested, because the precedence is a decision rather than an
/// accident: an answer may carry BOTH a document and a listing (the server
/// found one file inside a set it also narrowed to), and opening two things at
/// once is not an option. The specific artefact wins - he asked for a file and
/// got one, and the listing is still one tap away behind it.
enum AnswerRoute: Equatable {
    case openViewer(DocumentRef)
    case openFiles(FilesPayload)
    case none
}

enum AnswerPayloadRouter {
    static func route(document: DocumentRef?, files: FilesPayload?) -> AnswerRoute {
        if let document { return .openViewer(document) }
        if let files { return .openFiles(files) }
        return .none
    }
}

/// The latch a `files` payload lands in on its way to the Files tile.
///
/// Same shape as `PendingNotificationRoute` and `FinanceRoute`, and for the
/// same reason: the thing that RECEIVES the answer (the Ask page's view model,
/// or the docked orb on some other tile) is not the thing that can act on it,
/// and handing a closure down through four initialisers to connect them is how
/// this app used to route. `record` then `post`; `RootView` opens the tile and
/// the browser takes what is waiting.
///
/// `take()` hands the payload over exactly once, so however many delivery
/// routes fire - the notification, and the browser's own appearance - the
/// filters are applied once rather than twice.
@MainActor
enum FilesRoute {
    private static var pending: FilesPayload?

    static func record(_ payload: FilesPayload) { pending = payload }

    static func take() -> FilesPayload? {
        defer { pending = nil }
        return pending
    }

    /// Records the payload and tells whoever is listening. Called from a voice
    /// or chat answer; `RootView` opens the Files tile, and `FilesViewModel`
    /// applies it - whether the tile was already open or has just arrived.
    static func deliver(_ payload: FilesPayload) {
        record(payload)
        NotificationCenter.default.post(name: .ataruFilesRoute, object: nil)
    }
}

extension Notification.Name {
    /// An answer wants the Files tile opened with a narrowing applied.
    static let ataruFilesRoute = Notification.Name("com.ataru.client.filesRoute")

    /// A docked orb has taken the microphone, or given it back.
    ///
    /// The Ask page stays MOUNTED underneath every tile screen, and with it
    /// the "Hey ATARU" listener it armed. Without these two, holding the
    /// docked orb on the Files tile would have that listener hearing the same
    /// sentence from the same room - two microphones open on one question, and
    /// a wake word triggering on the user's own held turn. The Ask page pauses
    /// standby on the first and resumes on the second, exactly as it already
    /// does for a live call.
    static let ataruDockedMicTaken = Notification.Name("com.ataru.client.dockedMicTaken")
    static let ataruDockedMicReleased = Notification.Name("com.ataru.client.dockedMicReleased")
}
