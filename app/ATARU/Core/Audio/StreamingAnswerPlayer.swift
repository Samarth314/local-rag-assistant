import AVFoundation
import Foundation

/// Plays raw PCM audio as it arrives off the voice stream.
///
/// `AnswerPlayer` needs a complete file before the first sample is heard;
/// this player schedules each chunk into an `AVAudioEngine` the moment it
/// lands, so playback of sentence one overlaps the download — and the server-
/// side synthesis — of everything after it. That overlap is the entire point
/// of the streaming voice path.
@MainActor
final class StreamingAnswerPlayer {

    /// See `AnswerPlayer.managesAudioSession`. False during a call, where
    /// setting `.playback` here would destroy CallKit's `.playAndRecord`
    /// session and force the loudspeaker on regardless of the route toggle.
    var managesAudioSession = true

    /// How loud playback is right now, 0...1, for the orb. Fed by a tap on
    /// the mixer, so it follows what is actually being heard rather than what
    /// has been scheduled.
    private(set) var level: Double = 0

    private let engine = AVAudioEngine()
    private let node = AVAudioPlayerNode()
    private var format: AVAudioFormat?
    /// Chunk boundaries are byte-arbitrary; a sample is two bytes. The odd
    /// byte, when one arrives, waits here for its other half.
    private var pendingByte: Data = Data()
    private var scheduled = 0
    private var inputEnded = false
    private var onDrained: (() -> Void)?
    /// Whether this player is currently counted as a user of the shared
    /// audio session. Tracked so teardown releases exactly once.
    private var sessionHeld = false

    /// Resume whoever is waiting in `finish()`, exactly once.
    ///
    /// `teardown()` used to nil `onDrained` WITHOUT resuming it, so any
    /// teardown while `finish()` was suspended stranded the continuation
    /// forever and the ask task could never be reclaimed - the phone stayed
    /// on "Answering" with nothing playing and no way back. Nil-then-call is
    /// the order that matters: a CheckedContinuation resumed twice traps.
    private func resumeDrain() {
        let drained = onDrained
        onDrained = nil
        drained?()
    }

    private(set) var isActive = false

    /// Prepares the engine for a stream in the given format. Safe to call per
    /// sentence; it only rebuilds when the format actually changes.
    func begin(sampleRate: Double, channels: Int) throws {
        if isActive, let format, format.sampleRate == sampleRate,
           format.channelCount == AVAudioChannelCount(channels) {
            return
        }
        stop()

        // Retain BEFORE activating. Dictation arms a 5s timer that deactivates
        // this same shared session when a turn ends, and answer audio now
        // starts around T+3.3s - so without a retain the session is pulled out
        // from under playback mid-sentence. Retaining also cancels a release
        // that is already armed but has not fired.
        AudioSessionOwner.shared.retain()
        sessionHeld = true
        // ... and give it straight back if this method throws. Three sites
        // below can: the two session calls, the format guard, and
        // `engine.start()`. Each left the retain standing with no `teardown()`
        // to ever undo it (teardown only runs once `isActive` is set, which is
        // the last line here), so a single failed `begin` pinned the holder
        // count above zero for the life of the process - and from then on
        // NOTHING would ever deactivate the session again.
        var opened = false
        defer {
            if !opened, sessionHeld {
                sessionHeld = false
                AudioSessionOwner.shared.release()
            }
        }
        if managesAudioSession {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
            AudioSessionOwner.shared.markActive()
        }

        guard let format = AVAudioFormat(commonFormat: .pcmFormatFloat32,
                                         sampleRate: sampleRate,
                                         channels: AVAudioChannelCount(channels),
                                         interleaved: false) else {
            throw VoiceStreamError.protocolViolation("unplayable format")
        }
        self.format = format

        engine.attach(node)
        engine.connect(node, to: engine.mainMixerNode, format: format)
        engine.mainMixerNode.installTap(onBus: 0, bufferSize: 1024, format: nil) {
            [weak self] buffer, _ in
            let peak = SpeechDictation.peakLevel(of: buffer)
            Task { @MainActor in self?.level = peak }
        }
        try engine.start()
        node.play()

        pendingByte.removeAll()
        scheduled = 0
        inputEnded = false
        onDrained = nil
        isActive = true
        // Past every throwing site: the hold is now teardown's to give back.
        opened = true
    }

    /// Schedules one chunk of little-endian signed 16-bit PCM.
    func enqueue(_ chunk: Data) {
        guard isActive, let format else { return }

        var data = pendingByte + chunk
        if data.count % 2 != 0 {
            pendingByte = data.suffix(1)
            data = data.dropFirst(0).prefix(data.count - 1)
        } else {
            pendingByte.removeAll()
        }
        let sampleCount = data.count / 2
        guard sampleCount > 0,
              let buffer = AVAudioPCMBuffer(pcmFormat: format,
                                            frameCapacity: AVAudioFrameCount(sampleCount)) else {
            return
        }

        buffer.frameLength = AVAudioFrameCount(sampleCount)
        data.withUnsafeBytes { (raw: UnsafeRawBufferPointer) in
            let samples = raw.bindMemory(to: Int16.self)
            let out = buffer.floatChannelData![0]
            for i in 0..<sampleCount {
                out[i] = Float(Int16(littleEndian: samples[i])) / 32768.0
            }
        }

        scheduled += 1
        node.scheduleBuffer(buffer) { [weak self] in
            Task { @MainActor in self?.bufferFinished() }
        }
    }

    /// Marks the input complete and resolves when the last scheduled buffer
    /// has been heard. Resolves immediately if nothing was ever scheduled.
    func finish() async {
        guard isActive else { return }
        inputEnded = true
        if scheduled == 0 {
            teardown()
            return
        }
        // Bounded. If the last buffer never reports finished - the session
        // was yanked, the route changed, CoreAudio reset - this would suspend
        // forever, and the turn above it could never end. A detached watchdog
        // rather than a task group: a group AWAITS every child, so racing a
        // sleep inside one does not time anything out (learned the hard way,
        // 2026-08-01).
        let watchdog = Task { @MainActor [weak self] in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled, let self, self.isActive else { return }
            self.teardown()
        }
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onDrained = { continuation.resume() }
        }
        watchdog.cancel()
    }

    /// Stops immediately, discarding anything still queued. For hang-ups.
    func stop() {
        guard isActive else { return }
        teardown()
    }

    private func bufferFinished() {
        scheduled -= 1
        if inputEnded && scheduled <= 0 {
            // teardown() resumes the drain itself now, so this must NOT also
            // call it - resuming a CheckedContinuation twice is a crash.
            teardown()
        }
    }

    private func teardown() {
        engine.mainMixerNode.removeTap(onBus: 0)
        node.stop()
        engine.stop()
        engine.detach(node)
        format = nil
        level = 0
        isActive = false
        inputEnded = false
        scheduled = 0
        // Resume before dropping it. `finish()` suspends on this continuation
        // with no timeout, so nil-ing it here without resuming stranded the
        // ask task forever - the second half of the wedge, and why the phone
        // sat on "Answering" with nothing playing.
        resumeDrain()
        // Let go rather than deactivating directly: if dictation (or the next
        // turn) still holds the session, tearing it down here would break it.
        if sessionHeld {
            sessionHeld = false
            AudioSessionOwner.shared.release()
        }
    }
}
