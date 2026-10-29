import XCTest
@testable import AirSoundCore

final class StreamSpecTests: XCTestCase {
    func testJSONRoundTrip() throws {
        let spec = StreamSpec(senderName: "Office Mac", protocolVersion: AirSoundCore.protocolVersion, sampleRate: 48000, channelCount: 2)
        let data = try JSONEncoder().encode(spec)
        let decoded = try JSONDecoder().decode(StreamSpec.self, from: data)
        XCTAssertEqual(decoded, spec)
    }

    func testStreamSpecViaFraming() throws {
        let spec = StreamSpec(senderName: "Andy's Mac", protocolVersion: AirSoundCore.protocolVersion, sampleRate: 44100, channelCount: 2)
        let payload = try JSONEncoder().encode(spec)
        let frame = Framing.encode(type: FrameType.metadata, payload: payload)
        var reader = FrameReader()
        let frames = try reader.feed(frame)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, FrameType.metadata)
        let decoded = try JSONDecoder().decode(StreamSpec.self, from: frames[0].payload)
        XCTAssertEqual(decoded, spec)
    }
}
