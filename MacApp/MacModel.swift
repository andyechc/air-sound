import AirSoundCore
import AppKit
import Darwin
import Observation
import SystemConfiguration

/// Main-thread orchestrator for the Mac app: owns the lifecycle of the system
/// audio tap, the FIFO, and the Bonjour/TCP server.
@Observable
@MainActor
final class MacModel {
    var senderName: String = MacModel.prettyComputerName()
    private(set) var statusText = "Idle"
    private(set) var isStreaming = false
    private(set) var sampleRate: Double?
    private(set) var port: UInt16?
    private(set) var listenerCount = 0
    private(set) var localAddresses: [String] = []

#if DEBUG
    /// Seeds a synthetic "streaming" session for design work: Xcode previews
    /// and window screenshots. Runs no audio and no networking; only reachable
    /// through the preview helper or the `-demo` launch argument.
    init(demo: Bool = false) {
        if demo || CommandLine.arguments.contains("-demo") {
            senderName = "Andy's MacBook"
            isStreaming = true
            sampleRate = 48_000
            port = 56_725
            listenerCount = 1
            localAddresses = ["192.168.1.57", "10.0.1.157"]
            statusText = "Streaming. Open Air Sound on your iPhone."
        } else if CommandLine.arguments.contains("-demo-idle") {
            senderName = "Andy's MacBook"
        }
    }
#else
    init() {}
#endif

    private var fifo: PCMFIFO?
    private var tap: SystemAudioTap?
    private var server: AudioSendServer?

    /// Human-readable Mac name via SystemConfiguration; the (removed in the
    /// 27 SDK) AppKit `Host` API did this pre-2025.
    private static func prettyComputerName() -> String {
        if let store = SCDynamicStoreCreate(nil, "com.andyechc.airsound" as CFString, nil, nil),
           let name = SCDynamicStoreCopyComputerName(store, nil) as String? {
            return name
        }
        let hostName = ProcessInfo.processInfo.hostName
        if !hostName.isEmpty {
            return hostName.replacingOccurrences(of: ".local", with: "")
        }
        return "My Mac"
    }

    func startSharing() {
        stopSharing()
        do {
            // ~2 s of buffering at 48 kHz stereo; the ring starts overwriting
            // the oldest audio if nothing consumes it, keeping latency bounded.
            let fifo = PCMFIFO(capacityFrames: 96_000, channels: 2)
            let tap = SystemAudioTap(fifo: fifo)
            try tap.start()
            sampleRate = tap.sampleRate
            self.fifo = fifo
            self.tap = tap

            let spec = StreamSpec(
                senderName: senderName,
                protocolVersion: AirSoundCore.protocolVersion,
                sampleRate: tap.sampleRate,
                channelCount: 2)
            let server = AudioSendServer(fifo: fifo, specProvider: { spec })
            server.listenersChanged = { [weak self] count in
                Task { @MainActor in self?.listenerCount = count }
            }
            server.portChanged = { [weak self] value in
                Task { @MainActor in self?.port = value }
            }
            try server.start(name: senderName)
            self.server = server
            localAddresses = MacModel.ownIPv4Addresses()
            isStreaming = true
            statusText = "Streaming. Open Air Sound on your iPhone and tap \"\(senderName)\"."
        } catch {
            stopSharing()
            statusText = "Failed: \(error.localizedDescription)"
        }
    }

    func stopSharing() {
        server?.stop()
        server = nil
        tap?.stop()
        tap = nil
        fifo?.dropAll()
        fifo = nil
        isStreaming = false
        sampleRate = nil
        port = nil
        listenerCount = 0
        localAddresses = []
        statusText = "Idle"
    }

    /// "host:port" strings the iPhone manual-connect field accepts. The port is
    /// OS-assigned per start, so this list is only meaningful while streaming.
    var reachHints: [String] {
        guard let port else { return [] }
        return localAddresses.map { "\($0):\(port)" }
    }

#if DEBUG
    /// DEBUG-only: advertise and accept TCP clients without touching Core
    /// Audio, so discovery and pairing can be tested without the System Audio
    /// Recording TCC grant. The UI reports a live session; the stream is silent.
    func startDemoServer() {
        stopSharing()
        senderName = "Demo Mac"
        let fifo = PCMFIFO(capacityFrames: 96_000, channels: 2)
        self.fifo = fifo
        let spec = StreamSpec(
            senderName: senderName,
            protocolVersion: AirSoundCore.protocolVersion,
            sampleRate: 48_000,
            channelCount: 2)
        let server = AudioSendServer(fifo: fifo, specProvider: { spec })
        server.listenersChanged = { [weak self] count in
            Task { @MainActor in self?.listenerCount = count }
        }
        server.portChanged = { [weak self] value in
            Task { @MainActor in self?.port = value }
        }
        do {
            try server.start(name: senderName)
            self.server = server
            sampleRate = 48_000
            localAddresses = MacModel.ownIPv4Addresses()
            isStreaming = true
            statusText = "Demo server (silent)."
        } catch {
            statusText = "Demo server failed: \(error.localizedDescription)"
        }
    }
#endif

    /// Snapshot of this Mac's non-loopback IPv4 addresses, for the iPhone's
    /// manual "connect by host:port" fallback (AP-isolated WiFi kills mDNS).
    private static func ownIPv4Addresses() -> [String] {
        var result: [String] = []
        var ifap: UnsafeMutablePointer<ifaddrs>?
        guard getifaddrs(&ifap) == 0, let first = ifap else { return [] }
        defer { freeifaddrs(ifap) }
        var entry = first
        while true {
            if let addressPointer = entry.pointee.ifa_addr, addressPointer.pointee.sa_family == sa_family_t(AF_INET) {
                var buffer = [CChar](repeating: 0, count: Int(NI_MAXHOST))
                let status = withUnsafePointer(to: addressPointer.pointee) { raw in
                    raw.withMemoryRebound(to: sockaddr.self, capacity: 1) { saPointer in
                        getnameinfo(saPointer, socklen_t(MemoryLayout<sockaddr_in>.size), &buffer, socklen_t(buffer.count), nil, 0, NI_NUMERICHOST)
                    }
                }
                if status == 0 {
                    let address = String(cString: buffer)
                    if !address.hasPrefix("127."), !address.hasPrefix("169.254") {
                        result.append(address)
                    }
                }
            }
            if let next = entry.pointee.ifa_next {
                entry = next
            } else {
                break
            }
        }
        return result.sorted()
    }
}
