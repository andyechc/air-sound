import Foundation

/// Metadata frame the Mac sends as the first frame of every session.
///
/// The iPhone builds its player graph from `sampleRate` and `channelCount`, so
/// changing the Mac's output device mid-session is not supported in v1 (each
/// connection snapshots the spec at connect time).
public struct StreamSpec: Codable, Equatable {
    public var senderName: String
    public var protocolVersion: Int
    public var sampleRate: Double
    public var channelCount: Int

    public init(senderName: String, protocolVersion: Int, sampleRate: Double, channelCount: Int) {
        self.senderName = senderName
        self.protocolVersion = protocolVersion
        self.sampleRate = sampleRate
        self.channelCount = channelCount
    }
}
