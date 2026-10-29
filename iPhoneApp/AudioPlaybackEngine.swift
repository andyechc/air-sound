import AirSoundCore
import AVFAudio
import Foundation

/// Plays the received PCM stream through whatever route the iPhone has active
/// (speaker, Bluetooth, AirPlay): an `AVAudioEngine` with an
/// `AVAudioPlayerNode` scheduling raw chunks.
///
/// Latency strategy: start playback once `AirSoundCore.startPlaybackSeconds`
/// of audio is queued; if the queue grows past `AirSoundCore.maxQueuedSeconds`
/// (WiFi hiccup — new audio arrives slower than old audio plays), restart the
/// player with an empty queue and let it re-prime.
final class AudioPlaybackEngine {
    private let engine = AVAudioEngine()
    private let player = AVAudioPlayerNode()
    private let internalQueue = DispatchQueue(label: "com.andyechc.airsound.playback")

    /// UI-facing updates (all called on the connection queue; model hops to main).
    var onRouteChanged: ((String) -> Void)?
    var onUnderflow: (() -> Void)?
    var onInterruption: ((Bool) -> Void)? // true = ended-and-should-resume

    private var format: AVAudioFormat?
    private var spec: StreamSpec?
    private var started = false
    private var pendingFrames = 0
    private var observedNotifications = false

    // MARK: - State

    /// Pretty-printed primary output route, e.g. "AirPods Pro · headphones".
    var routeName: String {
        let outputs = AVAudioSession.sharedInstance().currentRoute.outputs
        guard let port = outputs.first else { return "iPhone" }
        let type = AudioPlaybackEngine.prettyPortType(port.portType)
        // Built-in speaker is named "Speaker" and typed "speaker"; showing both
        // reads as a bug ("Speaker · speaker") rather than useful information.
        if port.portName.caseInsensitiveCompare(type) == .orderedSame {
            return port.portName
        }
        return "\(port.portName) · \(type)"
    }

    var volume: Float {
        get { player.volume }
        set { player.volume = max(0, min(1, newValue)) }
    }

    // MARK: - Lifecycle

    /// Configures the audio session and starts the engine for the given spec.
    /// The session category is `.playback`; with `UIBackgroundModes: audio`,
    /// playback continues while the app is backgrounded or the screen locks.
    func start(spec: StreamSpec) throws {
        self.spec = spec
        let session = AVAudioSession.sharedInstance()
        try session.setCategory(.playback, mode: .default)
        try session.setActive(true)

        // Incoming samples are Float32 at the Mac's device rate; schedule them
        // as non-interleaved buffers and let the engine convert to the output.
        let sourceFormat = AVAudioFormat(
            commonFormat: .pcmFormatFloat32,
            sampleRate: spec.sampleRate,
            channels: AVAudioChannelCount(spec.channelCount),
            interleaved: false)
        guard let format = sourceFormat else { throw PlaybackError.badFormat }
        self.format = format
        engine.attach(player)
        engine.connect(player, to: engine.mainMixerNode, format: format)
        engine.prepare()
        try engine.start()
        pendingFrames = 0
        started = false
        observeSessionNotifications()
        onRouteChanged?(routeName)
    }

    func stop() {
        player.stop()
        engine.stop()
        engine.detach(player)
        spec = nil
        format = nil
        pendingFrames = 0
        started = false
        try? AVAudioSession.sharedInstance().setActive(false, options: [.notifyOthersOnDeactivation])
    }

    func pause() {
        player.pause()
    }

    func resume() {
        player.play()
    }

    // MARK: - Audio

    /// Schedules one received PCM chunk (little-endian Float32, interleaved).
    /// Called from the connection queue; uses the spec captured at
    /// `start(spec:)` so the hot path never touches main-actor state.
    func enqueue(samples: [Float32]) {
        guard let spec, let format else { return }
        let channelCount = spec.channelCount
        let frames = samples.count / channelCount
        guard frames > 0 else { return }
        guard let buffer = AVAudioPCMBuffer(pcmFormat: format, frameCapacity: AVAudioFrameCount(frames)) else { return }
        guard let channelData = buffer.floatChannelData else { return }
        buffer.frameLength = AVAudioFrameCount(frames)
        // Deinterleave for the non-interleaved buffer the engine expects.
        for channel in 0..<channelCount {
            let dest = channelData[channel]
            for frame in 0..<frames {
                dest[frame] = samples[frame * channelCount + channel]
            }
        }
        let scheduledFrames = Int(buffer.frameLength)
        player.scheduleBuffer(buffer) {
            self.internalQueue.async { self.pendingFrames -= scheduledFrames }
        }
        internalQueue.async {
            self.pendingFrames += frames
            let queuedSeconds = Double(self.pendingFrames) / spec.sampleRate
            if !self.started && queuedSeconds >= AirSoundCore.startPlaybackSeconds {
                self.started = true
                self.player.play()
            } else if queuedSeconds > AirSoundCore.maxQueuedSeconds {
                self.trimBacklog()
            } else if !self.player.isPlaying && self.pendingFrames == 0 {
                // Player ran dry (network stall); let the UI show buffering.
                self.onUnderflow?()
            }
        }
    }

    // MARK: - Internals

    private func trimBacklog() {
        // player.stop() clears scheduled buffers; stay stopped so the start
        // gate re-primes playback once enough fresh audio is queued.
        player.stop()
        pendingFrames = 0
        started = false
    }

    private enum PlaybackError: Error {
        case badFormat
    }

    private static func prettyPortType(_ type: AVAudioSession.Port) -> String {
        switch type {
        case .builtInSpeaker: return "speaker"
        case .headphones, .bluetoothLE, .bluetoothA2DP, .bluetoothHFP: return "headphones"
        case .airPlay: return "AirPlay"
        case .carAudio: return "car"
        default: return type.rawValue
        }
    }

    private func observeSessionNotifications() {
        guard !observedNotifications else { return }
        observedNotifications = true
        let center = NotificationCenter.default
        center.addObserver(
            self, selector: #selector(routeDidChange), name: AVAudioSession.routeChangeNotification, object: nil)
        center.addObserver(
            self, selector: #selector(sessionInterrupted), name: AVAudioSession.interruptionNotification, object: nil)
    }

    @objc private func routeDidChange() {
        onRouteChanged?(routeName)
    }

    @objc private func sessionInterrupted(_ notification: Notification) {
        guard let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt,
              let type = AVAudioSession.InterruptionType(rawValue: rawType) else { return }
        switch type {
        case .began:
            pause()
        case .ended:
            let shouldResume = AVAudioSession.InterruptionOptions.shouldResume
            let optionsRaw = notification.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0
            let options = AVAudioSession.InterruptionOptions(rawValue: optionsRaw)
            if options.contains(shouldResume) {
                resume()
                onInterruption?(true)
            } else {
                onInterruption?(false)
            }
        @unknown default:
            break
        }
    }
}
