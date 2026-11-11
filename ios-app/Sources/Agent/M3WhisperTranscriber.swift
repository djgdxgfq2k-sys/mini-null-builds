import AVFoundation
import Foundation
import WhisperKit

/// On-device speech-to-text for the note agent: WhisperKit `openai_whisper-small` (CoreML, encoder and
/// decoder on the Neural Engine) fed by AVAudioEngine at 16 kHz mono, with an energy-based voice
/// activity detector that ends the utterance after a short pause.
///
/// The model (~470 MB) is downloaded from Hugging Face on first use and cached by WhisperKit; after
/// that transcription runs fully offline. Audio never leaves the iPad, only the transcript does.
actor M3WhisperTranscriber {
    struct Options: Sendable {
        var model = "openai_whisper-small"
        /// nil = detect the language per utterance; "de" or "en" skips detection and is slightly faster.
        var language: String? = nil
        var maxSeconds: Double = 30
        /// Silence after speech that ends the utterance.
        var endSilence: Double = 0.9
        /// Give up if nobody speaks within this time.
        var noSpeechTimeout: Double = 8
    }

    enum Phase: Sendable, Equatable { case loadingModel, listening, transcribing }

    enum Failure: LocalizedError {
        case microphoneDenied, noMicrophone
        var errorDescription: String? {
            switch self {
            case .microphoneDenied: return "Mikrofonzugriff wird benötigt (Einstellungen → NullMini → Mikrofon)."
            case .noMicrophone: return "Kein verfügbares Mikrofon."
            }
        }
    }

    static let sampleRate = 16_000.0

    private let options: Options
    private var pipe: WhisperKit?
    private var engine: AVAudioEngine?
    private var sink: SampleSink?

    init(options: Options = Options()) { self.options = options }

    var isModelLoaded: Bool { pipe != nil }

    /// Loads (and on first use downloads) the CoreML model. Safe to call repeatedly.
    func prepare() async throws {
        guard pipe == nil else { return }
        let config = WhisperKitConfig(model: options.model, verbose: false, prewarm: true, download: true)
        config.computeOptions = ModelComputeOptions(audioEncoderCompute: .cpuAndNeuralEngine, textDecoderCompute: .cpuAndNeuralEngine)
        pipe = try await WhisperKit(config)
    }

    /// Records one utterance (ends on a pause, `stop()`, or `maxSeconds`) and returns its transcript.
    /// Returns "" when nobody spoke. `onPhase` and `onLevel` (0…1) are called off the main thread.
    func listenOnce(onPhase: (@Sendable (Phase) -> Void)? = nil,
                    onLevel: (@Sendable (Float) -> Void)? = nil) async throws -> String {
        if pipe == nil { onPhase?(.loadingModel); try await prepare() }
        onPhase?(.listening)
        let samples = try await record(onLevel: onLevel)
        guard !samples.isEmpty, let pipe else { return "" }
        onPhase?(.transcribing)
        let decode = DecodingOptions(language: options.language, temperature: 0, usePrefillPrompt: true,
                                     detectLanguage: options.language == nil, skipSpecialTokens: true,
                                     withoutTimestamps: true)
        let results = try await pipe.transcribe(audioArray: samples, decodeOptions: decode)
        return results.map(\.text).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
    }

    /// Ends the current recording early; what was said so far is still transcribed.
    func stop() { sink?.finish() }

    // MARK: Capture

    private func record(onLevel: (@Sendable (Float) -> Void)?) async throws -> [Float] {
        guard await AVAudioApplication.requestRecordPermission() else { throw Failure.microphoneDenied }
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.record, mode: .measurement, options: .duckOthers)
        try? session.setPreferredSampleRate(Self.sampleRate)
        try session.setActive(true)

        let engine = AVAudioEngine()
        let input = engine.inputNode
        let hardware = input.outputFormat(forBus: 0)
        guard hardware.sampleRate > 0, hardware.channelCount > 0,
              let target = AVAudioFormat(commonFormat: .pcmFormatFloat32, sampleRate: Self.sampleRate, channels: 1, interleaved: false),
              let converter = AVAudioConverter(from: hardware, to: target) else {
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw Failure.noMicrophone
        }
        let sink = SampleSink(options: options, onLevel: onLevel)
        self.engine = engine; self.sink = sink
        input.installTap(onBus: 0, bufferSize: 1024, format: hardware) { buffer, _ in
            sink.append(Self.resample(buffer, with: converter, to: target))
        }
        engine.prepare()
        do { try engine.start() } catch {
            input.removeTap(onBus: 0); self.engine = nil; self.sink = nil
            try? session.setActive(false, options: .notifyOthersOnDeactivation)
            throw error
        }
        let samples = await sink.result()
        input.removeTap(onBus: 0); engine.stop()
        self.engine = nil; self.sink = nil
        try? session.setActive(false, options: .notifyOthersOnDeactivation)
        return samples
    }

    /// Converts one hardware buffer (often 48 kHz, maybe stereo) to 16 kHz mono Float32.
    private static func resample(_ buffer: AVAudioPCMBuffer, with converter: AVAudioConverter, to format: AVAudioFormat) -> [Float] {
        let ratio = format.sampleRate / buffer.format.sampleRate
        let capacity = AVAudioFrameCount((Double(buffer.frameLength) * ratio).rounded(.up)) + 16
        guard let output = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: capacity) else { return [] }
        var supplied = false
        var error: NSError?
        converter.convert(to: output, error: &error) { _, status in
            if supplied { status.pointee = .noDataNow; return nil }
            supplied = true; status.pointee = .haveData; return buffer
        }
        guard error == nil, let channel = output.floatChannelData?[0] else { return [] }
        return Array(UnsafeBufferPointer(start: channel, count: Int(output.frameLength)))
    }
}

/// Collects 16 kHz samples from the audio thread and runs the voice activity detector.
/// Energy VAD on 30 ms frames: the noise floor adapts during silence; a frame is speech when it is
/// 10 dB above the floor (and above -50 dBFS). Keeps 300 ms of audio before the first speech.
final class SampleSink: @unchecked Sendable {
    private let lock = NSLock()
    private let options: M3WhisperTranscriber.Options
    private let onLevel: (@Sendable (Float) -> Void)?
    private var samples: [Float] = []
    private var pending: [Float] = []
    private var noiseFloor: Float = -60
    private var frames = 0
    private var speechFrames = 0
    private var silentFramesAfterSpeech = 0
    private var firstSpeechSample: Int?
    private var lastSpeechSample = 0
    private var finished = false
    private var waiter: CheckedContinuation<[Float], Never>?

    static let frame = 480                              // 30 ms at 16 kHz
    static let frameSeconds = Double(frame) / M3WhisperTranscriber.sampleRate

    init(options: M3WhisperTranscriber.Options, onLevel: (@Sendable (Float) -> Void)?) {
        self.options = options; self.onLevel = onLevel
    }

    func append(_ chunk: [Float]) {
        var level: Float?
        lock.lock()
        if !finished {
            samples.append(contentsOf: chunk); pending.append(contentsOf: chunk)
            while pending.count >= Self.frame {
                let frame = pending.prefix(Self.frame); pending.removeFirst(Self.frame)
                level = analyze(frame, end: samples.count - pending.count)
                if finished { break }
            }
        }
        lock.unlock()
        if let level { onLevel?(level) }
    }

    /// `end` is the sample index just past this frame. Returns the level 0…1 for a meter.
    /// Must be called with the lock held.
    private func analyze(_ frame: ArraySlice<Float>, end: Int) -> Float {
        frames += 1
        let power = frame.reduce(Float(0)) { $0 + $1 * $1 } / Float(frame.count)
        let db = 10 * log10(max(power, 1e-10))
        let speech = db > max(noiseFloor + 10, -50)
        if speech {
            speechFrames += 1; silentFramesAfterSpeech = 0
            lastSpeechSample = end
            if firstSpeechSample == nil { firstSpeechSample = max(0, end - Self.frame) }
        } else {
            noiseFloor = noiseFloor * 0.95 + db * 0.05          // adapt only on non-speech frames
            if speechFrames > 0 { silentFramesAfterSpeech += 1 }
        }
        let elapsed = Double(frames) * Self.frameSeconds
        let spoke = Double(speechFrames) * Self.frameSeconds >= 0.25
        if spoke && Double(silentFramesAfterSpeech) * Self.frameSeconds >= options.endSilence { finishLocked() }
        else if !spoke && elapsed >= options.noSpeechTimeout { finishLocked() }
        else if elapsed >= options.maxSeconds { finishLocked() }
        return min(1, max(0, (db + 60) / 50))
    }

    func finish() { lock.lock(); finishLocked(); lock.unlock() }

    private func finishLocked() {
        guard !finished else { return }
        finished = true
        let result = trimmed()
        if let waiter { self.waiter = nil; waiter.resume(returning: result) }
    }

    func result() async -> [Float] {
        await withCheckedContinuation { continuation in
            lock.lock()
            if finished { let r = trimmed(); lock.unlock(); continuation.resume(returning: r); return }
            waiter = continuation
            lock.unlock()
        }
    }

    /// Speech span with 300 ms before and 250 ms after; empty if there was no real speech.
    private func trimmed() -> [Float] {
        guard let first = firstSpeechSample, Double(speechFrames) * Self.frameSeconds >= 0.25 else { return [] }
        let rate = Int(M3WhisperTranscriber.sampleRate)
        let start = max(0, first - rate * 3 / 10)
        let end = min(samples.count, lastSpeechSample + rate / 4)
        return start < end ? Array(samples[start ..< end]) : []
    }
}
