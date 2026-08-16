import OSLog

/// Loggers for the two paths that were still writing to stdout.
///
/// `print` goes nowhere useful on a device: it is invisible unless the app is
/// attached to Xcode, it cannot be filtered, and it has no privacy annotation -
/// so anything interpolated into it is written in the clear if it is ever seen
/// at all. Both of the messages that used it are diagnostics about a turn that
/// went wrong, which is exactly the thing you want to be able to stream from a
/// phone in a pocket:
///
///     log stream --device --predicate 'subsystem == "com.ataru.client"'
///
/// The rest of the app already logs this way; these two were left behind.

/// The spoken-answer machine: phases, watchdogs, teardown.
let voiceLog = Logger(subsystem: "com.ataru.client", category: "voice")

/// Transcription, on the server and its fallbacks.
let sttLog = Logger(subsystem: "com.ataru.client", category: "stt")
