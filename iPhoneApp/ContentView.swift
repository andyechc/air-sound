import SwiftUI

extension Color {
    /// One step deeper than the brand accent. Sky blue `#0090E9` is right for
    /// icons and tints, but as 17 pt text it only reaches 3.4:1 on white; this
    /// shade keeps the hue and clears AA (5.2:1).
    static let airAction = Color(red: 0, green: 0.443, blue: 0.722)
}

/// iPhone UI. Two screens driven by model state: discovery while
/// `connectedTo == nil`, now-playing otherwise. Native HIG, single sky-blue
/// accent (the "Air" in Air Sound), motion only where it marks real activity.
struct ContentView: View {
    @Environment(IphoneModel.self) private var model

    var body: some View {
        NavigationStack {
            if model.connectedTo != nil {
                PlayingView()
            } else {
                DiscoveryView()
            }
        }
        // A dropped stream sends the user back to discovery; without this the
        // screen just changes with no stated cause.
        .alert(
            "Connection lost",
            isPresented: Binding(
                get: { model.connectionLostMessage != nil },
                set: { if !$0 { model.dismissConnectionLost() } }
            ),
            presenting: model.connectionLostMessage
        ) { _ in
            Button("OK", role: .cancel) { model.dismissConnectionLost() }
        } message: { message in
            Text(message)
        }
    }
}

// MARK: - Discovery

private struct DiscoveryView: View {
    @Environment(IphoneModel.self) private var model
    @State private var manualAddress = ""

    var body: some View {
        List {
            if model.discovered.isEmpty {
                Section {
                    searchingState
                        .listRowSeparator(.hidden)
                        .listRowBackground(Color.clear)
                }
            }

            if !model.discovered.isEmpty {
                Section {
                    ForEach(model.discovered) { mac in
                        Button {
                            model.connect(to: mac)
                        } label: {
                            HStack(spacing: 12) {
                                DeviceTile()
                                VStack(alignment: .leading, spacing: 2) {
                                    Text(mac.name)
                                        .font(.body.weight(.medium))
                                        .foregroundStyle(.primary)
                                    Text("Mac · tap to connect")
                                        .font(.footnote)
                                        .foregroundStyle(Color.primary.opacity(0.62))
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.footnote.weight(.semibold))
                                    .foregroundStyle(.secondary)
                            }
                            .padding(.vertical, 2)
                        }
                        .buttonStyle(.plain)
                    }
                } header: {
                    Text("On your network")
                        .foregroundStyle(Color.primary.opacity(0.62))
                }
            }

            Section {
                HStack(spacing: 10) {
                    ZStack(alignment: .leading) {
                        if manualAddress.isEmpty {
                            Text("e.g. 192.168.1.57:56725")
                                .foregroundStyle(Color.primary.opacity(0.62))
                                .allowsHitTesting(false)
                                .accessibilityHidden(true)
                        }
                        TextField("", text: $manualAddress)
                            .keyboardType(.numbersAndPunctuation)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .accessibilityLabel("Mac address")
                            .onSubmit { model.connectManually(manualAddress) }
                    }
                    Button("Connect") {
                        model.connectManually(manualAddress)
                    }
                    // Label text, not an icon: the brand sky blue is too light
                    // for 17 pt text (3.4:1), the deeper action blue clears AA.
                    .tint(Color.airAction)
                    .disabled(manualAddress.trimmingCharacters(in: .whitespaces).isEmpty)
                }
            } header: {
                Text("Connect by IP")
                    .foregroundStyle(Color.primary.opacity(0.62))
            } footer: {
                Text("Shown in the Mac panel under “Connect by IP”. Handy on Wi‑Fi that keeps devices from seeing each other.")
                    .foregroundStyle(Color.primary.opacity(0.62))
            }
        }
        .navigationTitle("Air Sound")
        .listStyle(.insetGrouped)
    }

    /// Searching/empty/error states (R-27): what is happening, the failure
    /// cause, and the next action.
    private var searchingState: some View {
        VStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .font(.system(size: 34, weight: .light))
                .foregroundStyle(Color.accentColor)
                // Marks a real behavior (browse in flight), not decoration.
                .symbolEffect(.pulse, options: .repeating)
            Text(model.statusText)
                .font(.subheadline)
                .foregroundStyle(Color.primary.opacity(0.62))
                .multilineTextAlignment(.center)
            if let problem = model.browserProblem {
                HStack(alignment: .firstTextBaseline, spacing: 6) {
                    Image(systemName: "exclamationmark.triangle.fill")
                        .font(.footnote)
                        .foregroundStyle(.red)
                    Text(problem)
                        .font(.footnote)
                        .foregroundStyle(.primary)
                }
                .multilineTextAlignment(.center)
                Button("Try again") { model.restartDiscovery() }
                    .buttonStyle(.bordered)
                    .tint(Color.airAction)
            }
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 20)
    }
}

/// Rounded tint tile that makes the Mac row scannable without adding color
/// noise (same accent, 8% fill: the icon clears 3:1 on it).
private struct DeviceTile: View {
    var body: some View {
        RoundedRectangle(cornerRadius: 10)
            .fill(Color.accentColor.opacity(0.08))
            .frame(width: 44, height: 44)
            .overlay {
                Image(systemName: "laptopcomputer.and.iphone")
                    .font(.system(size: 19, weight: .medium))
                    .foregroundStyle(Color.accentColor)
            }
    }
}

// MARK: - Now Playing

private struct PlayingView: View {
    @Environment(IphoneModel.self) private var model

    var body: some View {
        List {
            Section {
                nowPlayingHero
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }

            Section {
                HStack(spacing: 12) {
                    Image(systemName: "speaker.wave.1")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                    Slider(value: Binding(
                        get: { Double(model.volume) },
                        set: { model.volume = Float($0) }
                    ))
                    Image(systemName: "speaker.wave.3")
                        .foregroundStyle(.secondary)
                        .font(.footnote)
                }
            } header: {
                Text("Volume")
                    .foregroundStyle(Color.primary.opacity(0.62))
            }

            Section {
                transportRow
                    .listRowSeparator(.hidden)
                    .listRowBackground(Color.clear)
            }
        }
        .navigationTitle("Now Playing")
        .navigationBarTitleDisplayMode(.inline)
        .listStyle(.insetGrouped)
        .scrollContentBackground(.hidden)
    }

    /// Sender identity, live waveform, route, and receive state.
    private var nowPlayingHero: some View {
        VStack(spacing: 16) {
            ZStack {
                Circle().fill(Color.accentColor.opacity(0.08))
                    .frame(width: 168, height: 168)
                Image(systemName: "waveform")
                    .font(.system(size: 52, weight: .medium))
                    .foregroundStyle(Color.accentColor)
                    // Iterates like a level meter only while audio plays.
                    .symbolEffect(.variableColor.iterative, options: .repeating, isActive: !model.paused)
            }
            VStack(spacing: 4) {
                Text(model.senderName ?? "Mac")
                    .font(.title3.weight(.semibold))
                Text(model.statusText)
                    .font(.footnote)
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .multilineTextAlignment(.center)
                if model.paused {
                    HStack(spacing: 5) {
                        Image(systemName: "pause.fill")
                            .font(.caption2)
                        Text("Paused")
                            .font(.caption.weight(.semibold))
                    }
                    .foregroundStyle(Color.primary.opacity(0.62))
                }
            }
            HStack(spacing: 6) {
                Image(systemName: routeIcon(model.routeName))
                    .font(.footnote.weight(.semibold))
                    .foregroundStyle(Color.primary.opacity(0.62))
                Text(model.routeName)
                    .font(.footnote)
                    .foregroundStyle(Color.primary.opacity(0.62))
                    .lineLimit(1)
            }
            .padding(.horizontal, 12)
            .padding(.vertical, 7)
            .background(Capsule().fill(.quaternary))
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 10)
    }

    private var transportRow: some View {
        HStack(spacing: 36) {
            Button {
                model.togglePause()
            } label: {
                Image(systemName: model.paused ? "play.fill" : "pause.fill")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.accentColor))
            }
            .accessibilityLabel(model.paused ? "Resume playback" : "Pause playback")
            Button {
                model.stopConnection()
            } label: {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.red)
                    .frame(width: 64, height: 64)
                    .background(Circle().fill(Color.red.opacity(0.08)))
            }
            .accessibilityLabel("Disconnect")
        }
        .frame(maxWidth: .infinity)
        .padding(.vertical, 8)
    }
}

private func routeIcon(_ route: String) -> String {
    if route.contains("headphones") { return "headphones" }
    if route.contains("AirPlay") { return "airplayaudio" }
    if route.contains("car") { return "car" }
    if route.contains("speaker") { return "hifispeaker" }
    return "music.note"
}

#if DEBUG
#Preview("Discovery (nothing found)") {
    ContentView()
        .environment(IphoneModel())
}

#Preview("Discovery (Macs seeded)") {
    ContentView()
        .environment(IphoneModel.demoBrowsing())
}

#Preview("Now Playing") {
    ContentView()
        .environment(IphoneModel.demoPlaying())
}
#endif
