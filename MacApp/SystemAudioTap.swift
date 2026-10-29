import AirSoundCore
import CoreAudio
import Foundation

/// Captures the Mac's system output mix with a Core Audio process tap
/// (`AudioHardwareCreateProcessTap`, macOS 14.2+) and pushes 2-channel
/// interleaved Float32 into a `PCMFIFO` from the audio IO thread.
///
/// Invariants verified empirically against a global stereo tap:
/// - The tap yields Float32, interleaved, 2 channel blocks at the output
///   device's sample rate (48 kHz on modern Macs).
/// - Tap audio arrives on the IOProc `inInputData` side of a private
///   aggregate device created with only the tap in its tap list.
/// - The process audio object for a pid comes from translating the pid with
///   `kAudioHardwarePropertyTranslatePIDToProcessObject`; passing a raw pid to
///   `CATapDescription` fails with kAudioHardwareBadObjectError.
/// - Capturing requires the "System Audio Recording" TCC permission, gated by
///   `NSAudioCaptureUsageDescription` in the app's Info.plist. Without the
///   grant, everything succeeds but the tap delivers zeros.
final class SystemAudioTap {
    enum TapError: LocalizedError {
        case status(OSStatus, String)
        case formatUnavailable

        var errorDescription: String? {
            switch self {
            case .status(let status, let what): "\(what) failed (OSStatus \(status))"
            case .formatUnavailable: "could not read the tap's audio format"
            }
        }
    }

    private let fifo: PCMFIFO
    private var tapID: AudioObjectID = 0
    private var aggregateID: AudioObjectID = 0
    private var ioProcID: AudioDeviceIOProcID?

    /// Sample rate as reported by the aggregate's input stream format.
    private(set) var sampleRate: Double = 48_000

    init(fifo: PCMFIFO) {
        self.fifo = fifo
    }

    func start() throws {
        // Exclude this app's own audio from the tap (keeps the loop null even if
        // the app ever plays audio itself).
        let exclude: [AudioObjectID]
        if let ownObject = SystemAudioTap.processObject(forPID: ProcessInfo.processInfo.processIdentifier) {
            exclude = [ownObject]
        } else {
            exclude = []
        }
        let description = CATapDescription(stereoGlobalTapButExcludeProcesses: exclude)
        var createdTap = AudioObjectID(0)
        try check(AudioHardwareCreateProcessTap(description, &createdTap), "create system tap")
        tapID = createdTap

        // A private aggregate device whose only IO source is the tap; running
        // its IOProc pumps the tap's samples to us.
        let aggregate: [String: Any] = [
            kAudioAggregateDeviceUIDKey as String: "com.andyechc.airsound.aggregate-\(UUID().uuidString)",
            kAudioAggregateDeviceNameKey as String: "Air Sound Stream",
            kAudioAggregateDeviceIsPrivateKey as String: 1,
            kAudioAggregateDeviceTapAutoStartKey as String: 1,
            kAudioAggregateDeviceTapListKey as String: [[kAudioSubTapUIDKey as String: description.uuid.uuidString]],
        ]
        var aggID = AudioObjectID(0)
        try check(AudioHardwareCreateAggregateDevice(aggregate as CFDictionary, &aggID), "create aggregate device")
        aggregateID = aggID

        sampleRate = try readSampleRate(ofDevice: aggID)

        var procID: AudioDeviceIOProcID?
        try check(AudioDeviceCreateIOProcIDWithBlock(&procID, aggID, nil, { [weak self] _, inData, _, _, _ in
            self?.ingest(inData)
        }), "register IOProc")
        ioProcID = procID
        try check(AudioDeviceStart(aggID, procID!), "start device")
    }

    func stop() {
        if let ioProcID, aggregateID != 0 {
            AudioDeviceStop(aggregateID, ioProcID)
            AudioDeviceDestroyIOProcID(aggregateID, ioProcID)
        }
        if aggregateID != 0 {
            AudioHardwareDestroyAggregateDevice(aggregateID)
        }
        if tapID != 0 {
            AudioHardwareDestroyProcessTap(tapID)
        }
        ioProcID = nil
        aggregateID = 0
        tapID = 0
    }

    // MARK: - Audio path

    /// Scratch buffer used by the deinterleaved fallback path; audio-thread
    /// only (the IOProc never runs reentrantly), so no synchronization needed.
    private var scratch: [Float32] = []

    private func ingest(_ bufferList: UnsafePointer<AudioBufferList>) {
        let buffers = UnsafeMutableAudioBufferListPointer(UnsafeMutablePointer(mutating: bufferList))
        let channels = fifo.channels

        // Fast path: the verified stereo-global-tap layout, one interleaved
        // 2-channel Float32 buffer.
        if buffers.count == 1, let data = buffers[0].mData, Int(buffers[0].mNumberChannels) == channels {
            let floats = Int(buffers[0].mDataByteSize) / MemoryLayout<Float32>.stride
            _ = fifo.pushPointer(data.assumingMemoryBound(to: Float32.self), frames: floats / channels)
            return
        }

        // Fallback: deinterleaved (or differently-shaped) layout — downmix the
        // first two channels (duplicating channel 0 if the tap is mono).
        var channelBuffers: [[Float32]] = buffers.compactMap { buffer in
            guard let data = buffer.mData else { return nil }
            let reads = Int(buffer.mDataByteSize) / MemoryLayout<Float32>.stride
            return [Float32](UnsafeBufferPointer(start: data.assumingMemoryBound(to: Float32.self), count: reads))
        }
        guard !channelBuffers.isEmpty, let frames = channelBuffers.map(\.count).min(), frames > 0 else { return }
        scratch.removeAll(keepingCapacity: true)
        scratch.reserveCapacity(frames * channels)
        for frame in 0..<frames {
            for channel in 0..<channels {
                let source = channelBuffers[min(channel, channelBuffers.count - 1)]
                scratch.append(source[frame])
            }
        }
        _ = fifo.push(scratch, channels: channels)
    }

    private func readSampleRate(ofDevice device: AudioObjectID) throws -> Double {
        var asbd = AudioStreamBasicDescription()
        var size = UInt32(MemoryLayout<AudioStreamBasicDescription>.size)
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioDevicePropertyStreamFormat,
            mScope: kAudioObjectPropertyScopeInput,
            mElement: kAudioObjectPropertyElementMain)
        let status = AudioObjectGetPropertyData(device, &address, 0, nil, &size, &asbd)
        guard status == noErr, asbd.mSampleRate > 0 else { throw TapError.formatUnavailable }
        return asbd.mSampleRate
    }

    // MARK: - Static helpers

    private static func processObject(forPID pid: pid_t) -> AudioObjectID? {
        var pidValue = pid
        var address = AudioObjectPropertyAddress(
            mSelector: kAudioHardwarePropertyTranslatePIDToProcessObject,
            mScope: kAudioObjectPropertyScopeGlobal,
            mElement: kAudioObjectPropertyElementMain)
        var objectID = AudioObjectID(kAudioObjectUnknown)
        var size = UInt32(MemoryLayout<AudioObjectID>.size)
        let status = AudioObjectGetPropertyData(
            AudioObjectID(kAudioObjectSystemObject),
            &address,
            UInt32(MemoryLayout<pid_t>.size),
            &pidValue,
            &size,
            &objectID)
        guard status == noErr, objectID != AudioObjectID(kAudioObjectUnknown) else { return nil }
        return objectID
    }

    private func check(_ status: OSStatus, _ what: String) throws {
        guard status == noErr else { throw TapError.status(status, what) }
    }
}
