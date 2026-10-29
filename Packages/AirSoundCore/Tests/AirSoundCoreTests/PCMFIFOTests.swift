import XCTest
@testable import AirSoundCore

final class PCMFIFOTests: XCTestCase {
    func testPushPopOrderPreserved() {
        let fifo = PCMFIFO(capacityFrames: 1000, channels: 2)
        let input = (0..<600).map { Float($0) } // 300 stereo frames
        XCTAssertEqual(fifo.push(input, channels: 2), 300)
        XCTAssertEqual(fifo.framesAvailable, 300)
        XCTAssertEqual(fifo.pop(maxFrames: 300), input, "pop must return the exact pushed samples")
    }

    func testOverwriteOldestWhenFull() {
        let fifo = PCMFIFO(capacityFrames: 10, channels: 2)
        fifo.push((0..<20).map(Float.init), channels: 2) // fills capacity with two identical halves? no: 10 frames
        let second = (100..<140).map(Float.init) // 20 frames > capacity of 10 frames
        XCTAssertEqual(fifo.push(second, channels: 2), 20)
        // Ring keeps the most recent 10 frames (indices 120..<140).
        XCTAssertEqual(fifo.pop(maxFrames: 10), (120..<140).map(Float.init))
        // dropped counts everything not retained: the 10 overwritten old frames
        // plus the 10 newest frames that exceeded capacity and were discarded.
        XCTAssertEqual(fifo.droppedFrames, 20)
    }

    func testPopTimeoutOnEmpty() {
        let fifo = PCMFIFO(capacityFrames: 8, channels: 2)
        let start = Date()
        XCTAssertNil(fifo.pop(maxFrames: 8, timeout: 0.05))
        XCTAssertLessThan(Date().timeIntervalSince(start), 1.0)
    }

    func testPopLessThanQueued() {
        let fifo = PCMFIFO(capacityFrames: 100, channels: 2)
        fifo.push((0..<40).map(Float.init), channels: 2) // 20 frames
        XCTAssertEqual(fifo.pop(maxFrames: 5)?.count, 10)
        XCTAssertEqual(fifo.framesAvailable, 15)
        XCTAssertEqual(fifo.pop(maxFrames: 1000)?.count, 30)
        XCTAssertNil(fifo.pop(maxFrames: 1, timeout: 0.01))
    }

    func testConcurrentProducerConsumer() {
        let fifo = PCMFIFO(capacityFrames: 4096, channels: 2)
        let producedFrames = 6400
        let produced = DispatchSemaphore(value: 0)
        let group = DispatchGroup()

        let counter = Counter()
        group.enter()
        DispatchQueue.global().async {
            for _ in 0..<(producedFrames / 64) {
                _ = fifo.push([Float](repeating: 0.5, count: 128), channels: 2)
            }
            produced.signal()
        }
        group.leave() // entered then left immediately to allow async to run; guarded by produced semaphore below

        let sem = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            for _ in 0..<(producedFrames / 128) {
                if let samples = fifo.pop(maxFrames: 128, timeout: 0.5) {
                    counter.add(samples.count / 2)
                }
            }
            sem.signal()
        }

        XCTAssertEqual(produced.wait(timeout: .now() + 5), .success, "producer must finish")
        XCTAssertEqual(sem.wait(timeout: .now() + 5), .success, "consumer must finish")
        let received = counter.value
        XCTAssertEqual(received + fifo.framesAvailable + fifo.droppedFrames, producedFrames, "every produced frame is received, queued, or counted as overwritten (no other loss)")
    }

    private final class Counter: @unchecked Sendable {
        private var value_ = 0
        var value: Int { value_ }
        func add(_ v: Int) {
            value_ += v
        }
    }
}
