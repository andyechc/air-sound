import AirSoundCore
import Foundation
import Observation
import Network

/// Main-actor orchestrator for the iPhone app: discovery, connection, engine.
@Observable
@MainActor
final class IphoneModel {
    private(set) var discovered: [MacDiscovery.Entry] = []
    private(set) var connectedTo: String?
    private(set) var senderName: String?
    private(set) var routeName = "iPhone"
    private(set) var statusText = "Searching for a Mac that is sharing audio…"
    private(set) var paused = false
    private(set) var connectionLostMessage: String?
    private(set) var browserProblem: String?

    var volume: Float = 1 {
        didSet { engine.volume = volume }
    }

    private let discovery = MacDiscovery()
    private let engine = AudioPlaybackEngine()
    private var connection: MacConnection?

    init() {
        discovery.onChange = { [weak self] entries in
            Task { await self?.applyDiscoveryResults(entries) }
        }
        discovery.onState = { [weak self] message in
            Task { await self?.applyBrowserState(message) }
        }
        engine.onRouteChanged = { [weak self] route in
            Task { await self?.setRoute(route) }
        }
        engine.onUnderflow = { [weak self] in
            Task { await self?.setBuffering() }
        }
        engine.onInterruption = { [weak self] shouldResume in
            Task { await self?.setPaused(!shouldResume) }
        }

#if DEBUG
        // DEBUG-only screenshot seeds, selected by launch argument. Nothing
        // runs audio or a real connection here.
        if CommandLine.arguments.contains("-demo-playing") {
            applyDemoPlaying()
        } else if CommandLine.arguments.contains("-demo") {
            applyDemoBrowsing()
        }
#endif
    }

#if DEBUG
    /// DEBUG-only seeds for Xcode previews and simulator screenshots
    /// (documented in AGENTS.md); never present in release builds.
    static func demoBrowsing() -> IphoneModel {
        let model = IphoneModel()
        model.applyDemoBrowsing()
        return model
    }

    static func demoPlaying() -> IphoneModel {
        let model = IphoneModel()
        model.applyDemoPlaying()
        return model
    }

    private func applyDemoBrowsing() {
        discovered = [
            MacDiscovery.Entry(
                id: "demo-macbook",
                name: "Andy's MacBook",
                endpoint: .hostPort(host: "192.168.1.57", port: 56725)),
            MacDiscovery.Entry(
                id: "demo-imac",
                name: "Studio iMac",
                endpoint: .hostPort(host: "192.168.1.58", port: 56725)),
        ]
        statusText = "Tap a Mac to start listening."
    }

    private func applyDemoPlaying() {
        connectedTo = "Andy's MacBook"
        senderName = connectedTo
        routeName = "AirPods Pro · headphones"
        statusText = "Receiving · 48 kHz"
        paused = false
    }
#endif

    // MARK: - Actions

    func startDiscovery() {
        guard !demoMode else { return }
        discovery.start()
    }

    /// Called when returning to the foreground or from the retry button.
    func restartDiscovery() {
        guard !demoMode else { return }
        discovery.restart()
    }

    /// Screenshot/preview seeds must not be overwritten by a real browse; that
    /// was visibly true on the simulator once discovery started on launch.
    private var demoMode: Bool {
#if DEBUG
        CommandLine.arguments.contains("-demo")
            || CommandLine.arguments.contains("-demo-playing")
#else
        false
#endif
    }

    func connect(to entry: MacDiscovery.Entry) {
        start(connection: MacConnection(to: entry.endpoint), label: "\"\(entry.name)\"")
    }

    /// Fallback for WiFi networks that block mDNS (VPN / AP isolation):
    /// connects straight to "host:port" exactly as shown on the Mac window.
    func connectManually(_ text: String) {
        let trimmed = text.trimmingCharacters(in: .whitespacesAndNewlines)
        let host: String
        let portNumber: UInt16
        if let colon = trimmed.lastIndex(of: ":") {
            host = String(trimmed[..<colon])
            guard let parsed = UInt16(trimmed[trimmed.index(after: colon)...]) , parsed != 0 else {
                statusText = "Use IP:port exactly as shown on the Mac."
                return
            }
            portNumber = parsed
        } else {
            statusText = "Include the port, like 192.168.1.5:56725."
            return
        }
        // SDK 27: NWEndpoint.Host(String) is non-optional; validate the input
        // ourselves instead of relying on a failable init.
        guard !host.isEmpty, !host.contains(" ") else {
            statusText = "Invalid host."
            return
        }
        let hostInstance = NWEndpoint.Host(host)
        guard let port = NWEndpoint.Port(rawValue: portNumber) else {
            statusText = "Invalid port."
            return
        }
        start(
            connection: MacConnection(to: .hostPort(host: hostInstance, port: port)),
            label: trimmed)
    }

    private func start(connection newConnection: MacConnection, label: String) {
        guard connection == nil else { return }
        statusText = "Connecting to \(label)…"
        let connection = newConnection
        let engine = engine
        connection.onSpec = { [weak self, weak connection] spec in
            // Rare event (once per connection); safe to hop to the main actor.
            Task { await self?.apply(spec: spec, connection: connection) }
        }
        connection.onPCM = { payload in
            // Hot path: stays on the connection queue.
            let samples = payload.withUnsafeBytes { raw -> [Float32] in
                let stride = MemoryLayout<Float32>.stride
                let count = raw.count / stride
                var out = [Float32](repeating: 0, count: count)
                out.withUnsafeMutableBufferPointer { dst in
                    if let dstBase = dst.baseAddress, let srcBase = raw.baseAddress {
                        UnsafeMutableRawPointer(dstBase).copyMemory(from: srcBase, byteCount: count * stride)
                    }
                }
                return out
            }
            engine.enqueue(samples: samples)
        }
        connection.onClosed = { [weak self] message in
            Task { await self?.handleClosure(message) }
        }
        self.connection = connection
        connection.start()
    }

    func stopConnection() {
        teardown()
        connectedTo = nil
        senderName = nil
        connectionLostMessage = nil
        refreshDiscoveryStatus()
    }

    func dismissConnectionLost() {
        connectionLostMessage = nil
    }

    func togglePause() {
        if paused { engine.resume() } else { engine.pause() }
        paused.toggle()
    }

    // MARK: - Internals

    private func applyDiscoveryResults(_ entries: [MacDiscovery.Entry]) {
        discovered = entries
        refreshDiscoveryStatus()
#if DEBUG
        // Test hook: proves a discovered Bonjour endpoint is connectable,
        // not just visible. Debug builds only, opt-in via launch argument.
        if CommandLine.arguments.contains("-auto-connect"),
           connectedTo == nil, connection == nil, let first = entries.first {
            connect(to: first)
        }
#endif
    }

    private func applyBrowserState(_ message: String?) {
        browserProblem = message
        refreshDiscoveryStatus()
    }

    private func refreshDiscoveryStatus() {
        guard connectedTo == nil else { return }
        if let browserProblem {
            statusText = browserProblem
        } else if discovered.isEmpty {
            statusText = "Searching for a Mac that is sharing audio… If nothing appears, use the IP below."
        } else {
            statusText = "Tap a Mac below to start listening."
        }
    }

    private func apply(spec: StreamSpec, connection: MacConnection?) {
        senderName = spec.senderName
        connectedTo = spec.senderName
        connectionLostMessage = nil
        statusText = "Receiving · \(Self.formatSampleRate(spec.sampleRate))"
        do {
            try engine.start(spec: spec)
            paused = false
        } catch {
            statusText = "Audio engine failed: \(error.localizedDescription)"
            connection?.stop()
        }
    }

    /// 48000 reads as "48 kHz"; 44100 keeps its decimal.
    private static func formatSampleRate(_ rate: Double) -> String {
        let kHz = rate / 1000
        return kHz == kHz.rounded()
            ? "\(Int(kHz)) kHz"
            : String(format: "%.1f kHz", kHz)
    }

    private func teardown() {
        connection?.stop()
        connection = nil
        engine.stop()
    }

    private func setRoute(_ route: String) {
        routeName = route
    }

    private func setBuffering() {
        if !paused {
            statusText = "Buffering…"
        }
    }

    private func setPaused(_ paused: Bool) {
        self.paused = paused
    }

    private func handleClosure(_ message: String?) {
        guard connection != nil else { return }
        teardown()
        connectedTo = nil
        senderName = nil
        paused = false
        if let message, !message.isEmpty {
            connectionLostMessage = message
            statusText = "Disconnected: \(message)"
        } else {
            refreshDiscoveryStatus()
        }
    }
}
