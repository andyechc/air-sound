import Foundation
import Network
import AirSoundCore

/// Bonjour + TCP server. Advertises `_airsound._tcp` under the given name on an
/// OS-assigned port; every accepted iPhone gets one metadata frame and then a
/// continuously paced PCM stream.
final class AudioSendServer {
    private let queue = DispatchQueue(label: "com.andyechc.airsound.server")
    private var listener: NWListener?
    private var peers: [SenderPeer] = []
    private let fifo: PCMFIFO
    private let specProvider: () -> StreamSpec

    var listenersChanged: ((Int) -> Void)?
    var portChanged: ((UInt16) -> Void)?

    init(fifo: PCMFIFO, specProvider: @escaping () -> StreamSpec) {
        self.fifo = fifo
        self.specProvider = specProvider
    }

    func start(name: String) throws {
        let listener = try NWListener(using: NWParameters.tcp, on: .any)
        // The service name is what the iPhone will see; Bonjour auto-renames
        // on conflicts ("My Mac (2)"), so no uniqueness handling needed here.
        listener.service = NWListener.Service(name: name, type: AirSoundCore.serviceType)
        listener.newConnectionHandler = { [weak self] connection in
            self?.accept(connection)
        }
        listener.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            if case .ready = state {
                self.portChanged?(listener.port?.rawValue ?? 0)
            }
        }
        listener.start(queue: queue)
        self.listener = listener
    }

    func stop() {
        peers.forEach { $0.close() }
        peers.removeAll()
        listener?.cancel()
        listener = nil
    }

    private func accept(_ connection: NWConnection) {
        let peer = SenderPeer(connection: connection, fifo: fifo, specProvider: specProvider) { [weak self] in
            self?.postListenerCount()
        }
        peers.append(peer)
        peer.start()
    }

    private func postListenerCount() {
        let livePeers = peers.filter { !$0.isClosed }
        peers = livePeers
        listenersChanged?(livePeers.count)
    }
}

/// One connected iPhone. Sends a `StreamSpec` metadata frame on connect, then
/// wakes on FIFO availability and sends up to ~21 ms chunks, completion-chained
/// so at most one frame is in flight.
final class SenderPeer {
    private let connection: NWConnection
    private let fifo: PCMFIFO
    private let specProvider: () -> StreamSpec
    private let onChange: () -> Void
    private let waitTimer = DispatchQueue(label: "com.andyechc.airsound.sender.peer")
    private var closed = false

    var isClosed: Bool { closed }

    init(connection: NWConnection, fifo: PCMFIFO, specProvider: @escaping () -> StreamSpec, onChange: @escaping () -> Void) {
        self.connection = connection
        self.fifo = fifo
        self.specProvider = specProvider
        self.onChange = onChange
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            switch state {
            case .ready:
                self?.sendMetadata()
            case .failed, .cancelled:
                self?.markClosed()
            default:
                break
            }
        }
        connection.start(queue: connectionQueue)
        detectDisconnect()
    }

    func close() {
        markClosed()
        connection.cancel()
    }

    private func markClosed() {
        guard !closed else { return }
        closed = true
        onChange()
    }

    private func sendMetadata() {
        let spec = specProvider()
        let payload = (try? JSONEncoder().encode(spec)) ?? Data()
        send(Framing.encode(type: FrameType.metadata, payload: payload)) { [weak self] _ in
            self?.pump()
        }
    }

    /// Send loop: pop what the ring has (up to ~1024 frames ≈ 21 ms @ 48 kHz),
    /// send, repeat. When the ring is empty (MIC device idle) poll gently.
    private func pump() {
        guard !closed else { return }
        if let chunk = fifo.pop(maxFrames: 1024, timeout: 0.1) {
            let payload = chunk.withUnsafeBufferPointer { buffer -> Data in
                guard let base = buffer.baseAddress else { return Data() }
                return Data(buffer: UnsafeBufferPointer(start: base, count: buffer.count))
            }
            send(Framing.encode(type: FrameType.pcm, payload: payload)) { [weak self] _ in
                self?.pump()
            }
        } else {
            waitTimer.asyncAfter(deadline: .now() + 0.02) { [weak self] in
                self?.pump()
            }
        }
    }

    private func send(_ data: Data, completion: @escaping (Error?) -> Void) {
        connection.send(content: data, completion: .contentProcessed { error in
            if error != nil {
                completion(error)
                if error is NWError {
                    self.markClosed()
                    self.connection.cancel()
                }
            } else {
                completion(nil)
            }
        })
    }

    /// Passive receive that only watches for EOF/errors so the peer attribute
    /// reflects disconnection. Incoming data (if any) is discarded.
    private func detectDisconnect() {
        guard !closed else { return }
        connection.receive(minimumIncompleteLength: 1, maximumLength: 1) { [weak self] _, _, isComplete, error in
            guard let self else { return }
            if isComplete || error != nil {
                self.markClosed()
                self.connection.cancel()
                return
            }
            self.connectionQueue.async { self.detectDisconnect() }
        }
    }

    /// Reuse one queue for connection + sends; Network.framework keeps internal
    /// state on connection-related queues and send completions arrive on it.
    private var connectionQueue: DispatchQueue { waitTimer }
}
