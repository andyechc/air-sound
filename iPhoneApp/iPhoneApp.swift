import SwiftUI

@main
struct AirSoundiPhoneApp: App {
    @State private var model = IphoneModel()
    @Environment(\.scenePhase) private var scenePhase

    var body: some Scene {
        WindowGroup {
            ContentView()
                .environment(model)
                // Discovery used to be wired nowhere: the browser never
                // started, so only Connect by IP worked. Start it with the UI,
                // and revive it after a trip to Settings or the background.
                .task { model.startDiscovery() }
                .onChange(of: scenePhase) { _, phase in
                    if phase == .active { model.restartDiscovery() }
                }
        }
    }
}
