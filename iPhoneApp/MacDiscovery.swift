import AirSoundCore
import Foundation
import Network

/// Watches the local network for Macs advertising `_airsound._tcp`.
final class MacDiscovery {
    struct Entry: Identifiable, Equatable {
        /// Stable-ish id for list identity.
        let id: String
        /// Display name (Bonjour service instance name).
        let name: String
        /// Endpoint usable in an `NWConnection`.
        let endpoint: NWEndpoint
    }

    private var browser: NWBrowser?
    private let queue = DispatchQueue(label: "com.andyechc.airsound.browser")

    /// Called on `queue` with the complete current result set.
    var onChange: (([Entry]) -> Void)?
    /// Called on `queue` with a ready-to-show message, or nil when browsing is
    /// healthy. Surfaced so the UI can tell users a browse is *failing*
    /// (usually the Local Network privacy grant) instead of just staying empty.
    var onState: ((String?) -> Void)?

    /// Idempotent: the app starts discovery on launch and again whenever it
    /// returns to the foreground, so a browse that iOS suspended is revived.
    func start() {
        guard browser == nil else { return }
        let parameters = NWParameters.tcp
        parameters.includePeerToPeer = false
        let browser = NWBrowser(
            for: .bonjour(type: AirSoundCore.serviceType, domain: "local."),
            using: parameters)
        // The identity check drops callbacks from a browse we just replaced;
        // otherwise its late "cancelled" would clear a real error message.
        browser.browseResultsChangedHandler = { [weak self, weak browser] results, _ in
            guard let self, let browser, self.browser === browser else { return }
            self.post(results)
        }
        browser.stateUpdateHandler = { [weak self, weak browser] state in
            guard let self, let browser, self.browser === browser else { return }
            switch state {
            case .ready:
                self.onState?(nil)
            case .failed(let error), .waiting(let error):
                self.onState?(Self.describe(error))
            case .cancelled:
                self.onState?("browsing stopped")
            default:
                break
            }
        }
        browser.start(queue: queue)
        self.browser = browser
        post([])
    }

    func restart() {
        stop()
        start()
    }

    func stop() {
        let old = browser
        browser = nil
        old?.cancel()
    }

    private func post(_ results: Set<NWBrowser.Result>) {
        let entries = results.compactMap { result -> Entry? in
            guard case .service(let name, _, _, _) = result.endpoint else { return nil }
            return Entry(id: name, name: name, endpoint: result.endpoint)
        }
        .sorted { $0.name < $1.name }
        onChange?(entries)
    }

    /// A denied Local Network toggle surfaces as `kDNSServiceErr_PolicyDenied`
    /// (-65570); Network.framework's default text is not actionable for users.
    private static func describe(_ error: NWError) -> String {
        switch error {
        case .dns(let code) where code == -65570:
            return "Local Network access is off. Allow Air Sound in Settings → Privacy & Security → Local Network."
        case .posix(let code) where code == .EACCES || code == .EPERM:
            return "Local Network access is off. Allow Air Sound in Settings → Privacy & Security → Local Network."
        default:
            return "Local network search failed: \(error.localizedDescription)"
        }
    }
}
