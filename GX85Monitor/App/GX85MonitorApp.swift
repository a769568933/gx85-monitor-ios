import SwiftUI

@main
struct GX85MonitorApp: App {
    @StateObject private var session: CameraSession
    @Environment(\.scenePhase) private var scenePhase
    #if DEBUG && targetEnvironment(simulator)
    private let fixture: CameraDebugFixture?
    #endif

    init() {
        #if DEBUG && targetEnvironment(simulator)
        fixture = ProcessInfo.processInfo.arguments.contains("--fixture-monitor") ? CameraDebugFixture() : nil
        if let fixture {
            _session = StateObject(wrappedValue: fixture.session)
            return
        }
        #endif
        let settings = CameraSettings()
        _session = StateObject(wrappedValue: CameraSession(settings: settings))
    }

    var body: some Scene {
        WindowGroup {
            ZStack(alignment: .top) {
                CameraView(session: session).statusBarHidden()
                #if DEBUG && targetEnvironment(simulator)
                if let fixture {
                    FixtureStatusBadge(model: fixture.status, onNotice: {
                        session.showNotice("模拟长提示：相机仅确认收到指令，尚未确认生成照片。此处用于验证长提示覆盖画面时，取景位置和大小保持不变。请以相机存储卡中的实际文件为准。")
                    }).padding(.top, 96)
                }
                #endif
            }
        }
            .onChange(of: scenePhase) { phase in
                // A permission sheet makes the app inactive; only actual background stops the stream.
                if phase == .background { session.setForeground(false) }
                else if phase == .active { session.setForeground(true) }
            }
    }
}
