import XCTest
@testable import AirSoundCore

final class FramingTests: XCTestCase {
    private func lengthBytes(_ v: UInt32) -> [UInt8] {
        [UInt8(v & 0xFF), UInt8((v >> 8) & 0xFF), UInt8((v >> 16) & 0xFF), UInt8((v >> 24) & 0xFF)]
    }

    func testRoundTripSingleFrame() throws {
        let payload = Data("hello frames".utf8)
        let encoded = Framing.encode(type: FrameType.metadata, payload: payload)
        var reader = FrameReader()
        let frames = try reader.feed(encoded)
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].type, FrameType.metadata)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testSplitAcrossFeeds() throws {
        let payload = Data(repeating: 0xAB, count: 5000)
        let encoded = Framing.encode(type: FrameType.pcm, payload: payload)
        var reader = FrameReader()
        XCTAssertTrue(try reader.feed(encoded.prefix(7)).isEmpty, "no frame until header is complete")
        XCTAssertTrue(try reader.feed(encoded.dropFirst(7).prefix(1000 - 7)).isEmpty, "partial payload holds back")
        let frames = try reader.feed(encoded.dropFirst(1000))
        XCTAssertEqual(frames.count, 1)
        XCTAssertEqual(frames[0].payload, payload)
    }

    func testMultipleFramesInOneFeed() throws {
        let a = Framing.encode(type: FrameType.metadata, payload: Data([1, 2, 3]))
        let b = Framing.encode(type: FrameType.pcm, payload: Data(repeating: 9, count: 64))
        var reader = FrameReader()
        let frames = try reader.feed(a + b)
        XCTAssertEqual(frames.count, 2)
        XCTAssertEqual(frames[0].type, FrameType.metadata)
        XCTAssertEqual(frames[1].type, FrameType.pcm)
        XCTAssertEqual(frames[1].payload, Data(repeating: 9, count: 64))
    }

    func testBadMagicThrows() {
        var payload = Framing.encode(type: FrameType.metadata, payload: Data([1]))
        payload[0] = 0x58 // break "ASR"
        var reader = FrameReader()
        XCTAssertThrowsError(try reader.feed(payload))
    }

    func testOversizedLengthThrows() {
        var data = Data([0x41, 0x53, 0x52, UInt8(AirSoundCore.protocolVersion), FrameType.pcm])
        data.append(contentsOf: lengthBytes(UInt32(Framing.maxPayloadLength) + 1))
        var reader = FrameReader()
        XCTAssertThrowsError(try reader.feed(data))
    }

    func testUnknownVersionThrows() {
        var data = Data([0x41, 0x53, 0x52, 200, FrameType.pcm])
        data.append(contentsOf: lengthBytes(4))
        var reader = FrameReader()
        XCTAssertThrowsError(try reader.feed(data))
    }
}
