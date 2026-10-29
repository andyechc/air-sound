import Foundation

/// Payload type carried in a frame.
public enum FrameType {
    /// Payload is JSON-encoded `StreamSpec`.
    public static let metadata: UInt8 = 1
    /// Payload is little-endian Float32 samples, interleaved, 2 channels.
    public static let pcm: UInt8 = 2
}

/// A single decoded wire frame (header + payload already validated).
public struct Frame: Equatable {
    public let type: UInt8
    public let payload: Data

    public init(type: UInt8, payload: Data) {
        self.type = type
        self.payload = payload
    }
}

public enum FramingError: Error {
    /// Stream is not Air Sound data (bad magic/version/payload length).
    case corrupt
}

/// Length-prefixed framing over a byte stream (TCP).
///
/// Layout: 3 bytes magic "ASR", 1 byte protocol version, 1 byte frame type,
/// 4 bytes payload length (little-endian), then the payload.
public enum Framing {
    public static let headerLength = 9
    /// Largest single payload the receiver will trust before treating the
    /// stream as corrupt.
    private static let magic: [UInt8] = [0x41, 0x53, 0x52] // "ASR"
    public static let maxPayloadLength: Int = 1 << 20

    public static func encode(type: UInt8, payload: Data, version: UInt8 = UInt8(AirSoundCore.protocolVersion)) -> Data {
        var header = Data(capacity: headerLength + payload.count)
        header.append(contentsOf: magic)
        header.append(version)
        header.append(type)
        let length = UInt32(payload.count)
        header.append(UInt8(length & 0xFF))
        header.append(UInt8((length >> 8) & 0xFF))
        header.append(UInt8((length >> 16) & 0xFF))
        header.append(UInt8((length >> 24) & 0xFF))
        header.append(payload)
        return header
    }
}

/// Incremental parser that turns a byte stream into complete frames.
public struct FrameReader {
    private var buffer: [UInt8] = []

    public init() {}

    /// Feed incoming bytes; returns every frame that became complete.
    /// Partial input is held for the next call.
    public mutating func feed(_ data: Data) throws -> [Frame] {
        buffer.append(contentsOf: data)
        var frames: [Frame] = []
        while true {
            guard buffer.count >= Framing.headerLength else { break }
            guard buffer[0] == 0x41, buffer[1] == 0x53, buffer[2] == 0x52 else { throw FramingError.corrupt }
            guard buffer[3] == UInt8(AirSoundCore.protocolVersion) else { throw FramingError.corrupt }
            let type = buffer[4]
            let length = Int(buffer[5])
                | Int(buffer[6]) << 8
                | Int(buffer[7]) << 16
                | Int(buffer[8]) << 24
            guard length >= 0, length <= Framing.maxPayloadLength else { throw FramingError.corrupt }
            let total = Framing.headerLength + length
            guard buffer.count >= total else { break }
            frames.append(Frame(type: type, payload: Data(buffer[9 ..< total])))
            buffer.removeFirst(total)
        }
        return frames
    }
}
