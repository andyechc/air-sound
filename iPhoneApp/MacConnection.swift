import AirSoundCore
import Foundation
import Network

/// TCP connection to a discovered Mac. Parses the Air Sound frame stream on
/// its own queue; metadata is decoded here, PCM payload bytes are handed to
/// `onPCM` so the caller can schedule audio without hopping threads.
final class MacConnection {
    private let connection: NWConnection
    private var reader = FrameReader()
    private var isCancelled = false

    /// Decoded session spec (first frame of every connection).
    var onSpec: ((StreamSpec) -> Void)?
    /// Raw PCM frame payloads, on the connection queue.
    var onPCM: ((Data) -> Void)?
    /// Connection ended by either side (success or error).
    var onClosed: ((String?) -> Void)?
    private(set) var state: NWConnection.State = .setup

    init(to endpoint: NWEndpoint) {
        connection = NWConnection(to: endpoint, using: NWParameters.tcp)
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.receiveLoop()
            case .failed(let error):
                self.state = state
                self.onClosed?(error.localizedDescription)
            case .cancelled:
                self.state = state
                self.onClosed?(nil)
            default:
                self.state = state
            }
        }
        connection.start(queue: queue)
    }

    func stop() {
        isCancelled = true
        connection.cancel()
    }

    private func receiveLoop() {
        guard !isCancelled else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [weak self] data, _, isComplete, error in
            guard let self else { return }
            if let data, !data.isEmpty {
                do {
                    for frame in try self.reader.feed(data) {
                        switch frame.type {
                        case FrameType.metadata where self.onSpec != nil:
                            if let spec = try? JSONDecoder().decode(StreamSpec.self, from: frame.payload) {
                                self.onSpec?(spec)
                            }
                        case FrameType.pcm where self.onPCM != nil:
                            self.onPCM?(frame.payload)
                        default:
                            break
                        }
                    }
                } catch {
                    self.stop()
                    self.onClosed?("The Mac stream was corrupted.")
                    return
                }
            }
            if isComplete || error != nil {
                self.onClosed?(isComplete ? nil : error?.localizedDescription)
                return
            }
            self.receiveLoop()
        }
    }

    private let queue = DispatchQueue(label: "com.andyechc.airsound.connection")
}
