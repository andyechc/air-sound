import Foundation

/// Constants for the Air Sound streaming protocol.
///
/// Direction of travel: the **Mac is the server**. It brings up a Core Audio
/// process tap (see `MacApp`), advertises `_airsound._tcp` over Bonjour, and
/// pushes metadata + PCM frames to every connected iPhone over TCP. The iPhone
/// browses for the service, connects, and schedules received chunks into an
/// `AVAudioEngine` player node, so whatever output route the iPhone has active
/// (speaker, Bluetooth, AirPlay) just works.
public enum AirSoundCore {
    /// Bonjour service type advertised by the Mac app. The iPhone declares this
    /// exact string in Info.plist under `NSBonjourServices` — if the strings
    /// drift, local-network discovery fails silently.
    public static let serviceType = "_airsound._tcp"

    /// Wire protocol version (frame header version byte and metadata `version`).
    /// Bump when framing or `StreamSpec` changes shape.
    public static let protocolVersion = 1

    /// Receiver starts playback once this many seconds of audio are queued.
    public static let startPlaybackSeconds: Double = 0.11

    /// When the played-back-lagging queue grows past this many seconds (a WiFi
    /// stall), the receiver re-trims to `latencyTrimSeconds`.
    public static let maxQueuedSeconds: Double = 3.0

    /// Queue length the receiver trims back to after a stall.
    public static let latencyTrimSeconds: Double = 0.9

    /// Largest single payload the receiver will trust before treating the
    /// stream as corrupt.
    public static let maxPayloadLength = 1 << 20
}
