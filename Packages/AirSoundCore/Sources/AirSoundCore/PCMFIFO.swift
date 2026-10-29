import Foundation
import os

/// Single-producer / single-consumer ring buffer of interleaved Float32 samples.
///
/// The producer is the Mac's audio IO thread (coreaudio realtime callback);
/// the consumer is the network sender thread. Writes overwrite the oldest
/// samples once full, which keeps sender-side latency bounded if no receiver
/// is consuming. `OSAllocatedUnfairLock` is used because its brief critical
/// sections are realtime-safety friendly; this is v1-simple, not a lock-free
/// audio-grade FIFO.
public final class PCMFIFO {
    public let channels: Int
    private let capacityFloats: Int

    private struct State {
        var storage: [Float32]
        var readIndex = 0
        var count = 0
        var dropped = 0
    }

    private let state: OSAllocatedUnfairLock<State>
    private let available = DispatchSemaphore(value: 0)

    public init(capacityFrames: Int, channels: Int = 2) {
        self.channels = channels
        capacityFloats = capacityFrames * channels
        state = OSAllocatedUnfairLock(initialState: State(storage: [Float32](repeating: 0, count: capacityFloats)))
    }

    /// Queue depth in frames (i.e. samples divided by channel count).
    public var framesAvailable: Int {
        state.withLock { $0.count / channels }
    }

    /// Total frames not retained since creation: overwritten-oldest frames plus
    /// overshooting newest frames discarded when a push exceeds capacity.
    /// Invariant: `pop`ped frames + `framesAvailable` + `droppedFrames`
    /// == total frames ever pushed.
    public var droppedFrames: Int {
        state.withLock { $0.dropped / channels }
    }

    /// Push `samples` (interleaved, one entry per channel per frame).
    /// Overwrites the oldest data when the buffer can't fit the new payload.
    public func push(_ samples: [Float32], channels: Int) -> Int {
        guard channels == self.channels else { return 0 }
        return samples.withUnsafeBufferPointer { buffer -> Int in
            guard let base = buffer.baseAddress else { return 0 }
            return pushPointer(base, frames: buffer.count / channels)
        }
    }

    /// Zero-copy push from a raw Float32 pointer (use from the audio callback).
    ///
    /// Note: Swift flags the `pointer` capture inside the `withLock` closure as
    /// non-Sendable; the warning is a false positive here because the pointer
    /// is only dereferenced on the same thread that made the push call. The
    /// lock only guards the ring state shared with the consumer thread.
    public func pushPointer(_ pointer: UnsafePointer<Float32>, frames: Int) -> Int {
        let n = frames * channels
        guard n > 0, capacityFloats > 0 else { return 0 }
        let written = state.withLock { s -> Int in
            let free = capacityFloats - s.count
            let writeIndex = (s.readIndex + s.count) % capacityFloats
            let overflow = max(0, n - free)
            s.count = min(capacityFloats, s.count + n)
            if overflow > 0 {
                s.readIndex = (s.readIndex + overflow) % capacityFloats
                s.dropped += overflow
            }
            let start = max(0, n - capacityFloats)
            let usable = min(n, capacityFloats)
            var index = writeIndex
            for i in 0..<usable {
                s.storage[index] = pointer[start + i]
                index += 1
                if index == capacityFloats { index = 0 }
            }
            return frames
        }
        available.signal()
        return written
    }

    /// Pop up to `maxFrames` frames, blocking up to `timeout`.
    /// Returns interleaved samples (length = frames * channels) or nil.
    public func pop(maxFrames: Int, timeout: TimeInterval = 0.1) -> [Float32]? {
        _ = available.wait(timeout: .now() + timeout)
        return state.withLock { s -> [Float32]? in
            guard s.count > 0 else { return nil }
            let take = min(maxFrames * channels, s.count)
            var out = [Float32]()
            out.reserveCapacity(take)
            for i in 0..<take {
                out.append(s.storage[(s.readIndex + i) % capacityFloats])
            }
            s.readIndex = (s.readIndex + take) % capacityFloats
            s.count -= take
            return out
        }
    }

    /// Drop everything currently queued (used on stop / spec change).
    public func dropAll() {
        state.withLock { s in
            s.readIndex = 0
            s.count = 0
        }
    }
}
