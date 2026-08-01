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

    private(set) var isActive = false

    /// Prepares the engine for a stream in the given format. Safe to call per
    /// sentence; it only rebuilds when the format actually changes.
    func begin(sampleRate: Double, channels: Int) throws {
        if isActive, let format, format.sampleRate == sampleRate,
           format.channelCount == AVAudioChannelCount(channels) {
            return
        }
        stop()

        if managesAudioSession {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .spokenAudio, options: [.duckOthers])
            try session.setActive(true)
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
        await withCheckedContinuation { (continuation: CheckedContinuation<Void, Never>) in
            onDrained = { continuation.resume() }
        }
    }

    /// Stops immediately, discarding anything still queued. For hang-ups.
    func stop() {
        guard isActive else { return }
        teardown()
    }

    private func bufferFinished() {
        scheduled -= 1
        if inputEnded && scheduled <= 0 {
            let drained = onDrained
            teardown()
            drained?()
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
        onDrained = nil
        if managesAudioSession {
            try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
        }
    }
}
