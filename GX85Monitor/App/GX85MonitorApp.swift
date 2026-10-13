import SwiftUI

@main
struct GX85MonitorApp: App {
    @StateObject private var session: CameraSession
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let settings = CameraSettings()
        _session = StateObject(wrappedValue: CameraSession(settings: settings))
    }

    var body: some Scene {
        WindowGroup { CameraView(session: session).statusBarHidden() }
            .onChange(of: scenePhase) { phase in
                // A permission sheet makes the app inactive; only actual background stops the stream.
                if phase == .background { session.setForeground(false) }
                else if phase == .active { session.setForeground(true) }
            }
    }
}
