import AppKit
import SwiftUI

extension Color {
    /// Filled controls carry white 13 pt labels, so their fill must clear
    /// 4.5:1: the brand sky blue reaches 3.4:1 and `Color.red` 3.5:1. These
    /// deeper steps keep the hues and land at 5.2:1 and 5.4:1.
    static let airAction = Color(red: 0, green: 0.443, blue: 0.722)
    static let airStop = Color(red: 0.843, green: 0, blue: 0.082)
}

/// Mac control panel. One window, three jobs: name the stream, see the session
/// state, and hand the user an IP fallback when the Wi-Fi hides devices from
/// each other. Design: native HIG, single sky-blue accent tied to the "Air" in
/// Air Sound (used on the brand mark and the primary action only).
struct ContentView: View {
    @Environment(MacModel.self) private var model
    @State private var copiedHint: String?

    var body: some View {
        @Bindable var model = model

        VStack(spacing: 0) {
            header
            Divider()
            VStack(alignment: .leading, spacing: 18) {
                nameField
                sessionCard
                if model.isStreaming {
                    connectHints
                }
            }
            .padding(20)
            .frame(maxWidth: .infinity, alignment: .leading)
            primaryButton
                .padding(.horizontal, 20)
                .padding(.bottom, 16)
        }
        .frame(width: 460)
    }

    // MARK: Header

    private var header: some View {
        HStack(spacing: 12) {
            // Brand mark: the radio-waves glyph names the product's job
            // (sending audio through the air) in one symbol.
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 22, weight: .semibold))
                .foregroundStyle(Color.accentColor)
                .frame(width: 44, height: 44)
                .background(Circle().fill(Color.accentColor.opacity(0.08)))
            VStack(alignment: .leading, spacing: 2) {
                Text("Air Sound")
                    .font(.headline)
                HStack(spacing: 5) {
                    // Marks the real isStreaming state; static (no pulse).
                    Circle()
                        .fill(model.isStreaming ? Color.green : Color.secondary.opacity(0.55))
                        .frame(width: 7, height: 7)
                    Text(model.isStreaming ? "Streaming" : "Not sharing")
                        .font(.subheadline)
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
            }
            Spacer()
        }
        .padding(.horizontal, 20)
        .padding(.vertical, 14)
    }

    // MARK: Name

    private var nameField: some View {
        @Bindable var model = model
        return VStack(alignment: .leading, spacing: 6) {
            Text("Name on your iPhone")
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.62))
            TextField("My Mac", text: $model.senderName)
                .textFieldStyle(.roundedBorder)
                .disabled(model.isStreaming)
            if model.isStreaming {
                Text("Stop sharing to rename.")
                    .font(.caption)
                    .foregroundStyle(Color.primary.opacity(0.62))
            }
        }
    }

    // MARK: Session

    private var sessionCard: some View {
        GroupBox {
            VStack(spacing: 10) {
                if let rate = model.sampleRate {
                    statusRow("music.note", "Format", "\(Self.formatRate(rate)) · stereo")
                } else {
                    statusRow("waveform", "Format", "Idle")
                }
                statusRow("person.2", "Listeners", "\(model.listenerCount)")
                if model.isStreaming {
                    // Only advertised while sharing: an idle sender has no
                    // Bonjour name on the network yet.
                    statusRow("wifi", "Broadcasting as", "“\(model.senderName)”")
                }
            }
            .padding(.vertical, 4)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
    }

    private func statusRow(_ symbol: String, _ label: String, _ value: String) -> some View {
        HStack(spacing: 10) {
            Image(systemName: symbol)
                .font(.footnote)
                .foregroundStyle(.secondary)
                .frame(width: 18)
            Text(label)
                .font(.callout)
                .foregroundStyle(Color.primary.opacity(0.62))
            Spacer()
            Text(value)
                .font(.callout)
                .monospacedDigit()
                .lineLimit(1)
                .truncationMode(.middle)
        }
    }

    /// 48000 reads as "48 kHz"; 44100 keeps its decimal.
    private static func formatRate(_ rate: Double) -> String {
        let kHz = rate / 1000
        return kHz == kHz.rounded()
            ? "\(Int(kHz)) kHz"
            : String(format: "%.1f kHz", kHz)
    }

    // MARK: IP fallback

    private var connectHints: some View {
        VStack(alignment: .leading, spacing: 8) {
            Label("Connect by IP (if discovery is blocked)", systemImage: "link")
                .font(.caption)
                .foregroundStyle(Color.primary.opacity(0.62))
            ForEach(model.reachHints, id: \.self) { hint in
                HStack(spacing: 8) {
                    Text(hint)
                        .font(.system(.callout, design: .monospaced))
                        .textSelection(.enabled)
                    Spacer()
                    Button {
                        copyToPasteboard(hint)
                    } label: {
                        Image(systemName: copiedHint == hint ? "checkmark" : "doc.on.doc")
                            .foregroundStyle(copiedHint == hint ? Color.green : Color.secondary)
                    }
                    .buttonStyle(.borderless)
                    .frame(width: 24, height: 24)
                    .contentShape(Rectangle())
                    .help("Copy address")
                    .accessibilityLabel("Copy address")
                }
            }
            Text("Type this on the iPhone under Connect by IP.")
                .font(.footnote)
                .foregroundStyle(Color.primary.opacity(0.62))
        }
    }

    private func copyToPasteboard(_ hint: String) {
        NSPasteboard.general.clearContents()
        NSPasteboard.general.setString(hint, forType: .string)
        copiedHint = hint
        // Restartable delay would fight rapid retries; only reset the check
        // while this hint is still the shown one.
        Task {
            try? await Task.sleep(for: .seconds(1.5))
            if copiedHint == hint {
                copiedHint = nil
            }
        }
    }

    // MARK: Primary action

    private var primaryButton: some View {
        Button {
            model.isStreaming ? model.stopSharing() : model.startSharing()
        } label: {
            Label(
                model.isStreaming ? "Stop sharing" : "Start sharing",
                systemImage: model.isStreaming ? "stop.fill" : "dot.radiowaves.left.and.right")
                .frame(maxWidth: .infinity)
        }
        .buttonStyle(.borderedProminent)
        .controlSize(.large)
        // Accent in, red out: the destructive-looking stop is the one place a
        // second color earns its keep.
        .tint(model.isStreaming ? Color.airStop : Color.airAction)
    }
}

#if DEBUG
#Preview("Idle") {
    ContentView()
        .environment(MacModel())
}

#Preview("Streaming (demo seed)") {
    ContentView()
        .environment(MacModel(demo: true))
}
#endif
