import Foundation
import XCTest
import GX85Core
@testable import GX85Monitor

@MainActor
final class CameraParameterTests: XCTestCase {
    private func connected(_ camera: ParameterCamera) async -> CameraSession {
        let settings = CameraSettings(defaults: UserDefaults(suiteName: UUID().uuidString)!)
        settings.accessID = "parameter-test"
        let session = CameraSession(settings: settings, makeClient: { _ in camera }, makeReceiver: { ParameterReceiver() })
        session.connect()
        for _ in 0..<400 {
            if session.parameterOptions[.iso]?.isEmpty == false { return session }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTFail("Camera parameters were not loaded")
        return session
    }

    func testCurrentMenuDisablesAShutterAndSAperture() throws {
        let all = try CameraCapabilities.parse(data: Data(ParameterCamera.allMenu(aperture: "392/256").utf8))
        let apertureMode = try all.applyingCurrentMenu(data: Data(ParameterCamera.currentMenu(shutter: false, aperture: true).utf8))
        XCTAssertFalse(try XCTUnwrap(apertureMode.options(for: .shutter).first).enabled)
        XCTAssertTrue(try XCTUnwrap(apertureMode.options(for: .aperture).first).enabled)
        let shutterMode = try all.applyingCurrentMenu(data: Data(ParameterCamera.currentMenu(shutter: true, aperture: false).utf8))
        XCTAssertTrue(try XCTUnwrap(shutterMode.options(for: .shutter).first).enabled)
        XCTAssertFalse(try XCTUnwrap(shutterMode.options(for: .aperture).first).enabled)
    }

    func testMissingCurrentMenuEntryDoesNotEnableUnknownControl() throws {
        let all = try CameraCapabilities.parse(data: Data(ParameterCamera.allMenu(aperture: "392/256").utf8))
        let current = try all.applyingCurrentMenu(data: Data("<camrply><result>ok</result><menuinfo><photosettings/></menuinfo></camrply>".utf8))
        XCTAssertTrue(current.options(for: .iso).allSatisfy { !$0.enabled })
    }

    func testMFDoesNotDisableExposureAndRawValueIsReadBack() async throws {
        let camera = ParameterCamera()
        let session = await connected(camera)
        let option = try XCTUnwrap(session.parameterOptions[.iso]?.first(where: { $0.rawValue == "400" }))
        session.updateParameter(.iso, option: option)
        for _ in 0..<400 {
            if !session.actionInProgress && session.parameterValues[.iso] == "400" { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(session.parameterValues[.iso], "400")
        let calls = await camera.calls
        XCTAssertTrue(calls.contains(.setSetting(type: "iso", value: "400")))
        XCTAssertFalse(calls.contains(.autoFocus))
        session.disconnect()
    }

    func testRejectedSettingKeepsPreviouslyReadValue() async throws {
        let camera = ParameterCamera(reject: true)
        let session = await connected(camera)
        XCTAssertEqual(session.parameterValues[.iso], "100")
        let option = try XCTUnwrap(session.parameterOptions[.iso]?.first(where: { $0.rawValue == "400" }))
        session.updateParameter(.iso, option: option)
        for _ in 0..<400 {
            if !session.actionInProgress && session.notice != nil { break }
            try? await Task.sleep(nanoseconds: 5_000_000)
        }
        XCTAssertEqual(session.parameterValues[.iso], "100")
        XCTAssertNotNil(session.notice)
        XCTAssertTrue(session.isActive)
        session.disconnect()
    }

    func testDifferentLensesDoNotShareOptionCache() async {
        let first = await connected(ParameterCamera(aperture: "392/256"))
        let second = await connected(ParameterCamera(aperture: "780/256"))
        XCTAssertEqual(first.parameterOptions[.aperture]?.first?.rawValue, "392/256")
        XCTAssertEqual(second.parameterOptions[.aperture]?.first?.rawValue, "780/256")
        first.disconnect(); second.disconnect()
    }
}

private actor ParameterCamera: CommandSending {
    private let reject: Bool
    private let aperture: String
    private var iso = "100"
    private(set) var calls: [LumixCommand] = []
    init(reject: Bool = false, aperture: String = "392/256") { self.reject = reject; self.aperture = aperture }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        calls.append(command)
        if command == .getInfo("allmenu") { return try LumixResponse.parseMenu(data: Data(Self.allMenu(aperture: aperture).utf8)) }
        if command == .getInfo("curmenu") { return try LumixResponse.parseMenu(data: Data(Self.currentMenu(shutter: true, aperture: true).utf8)) }
        if case .setSetting(type: "iso", value: let value) = command {
            if reject { throw CommandError.cameraRejected("err_reject") }
            iso = value
        }
        if case .getSetting(let type) = command {
            return LumixResponse(status: .success, fields: [type: type == "iso" ? iso : (type == "focal" ? aperture : (type == "focusmode" ? "mf" : "1780/256"))])
        }
        return LumixResponse(status: .success, fields: ["rec": "off", "lens": aperture])
    }
    // Synthetic fixtures use the published Lumix menu and language element schema.
    nonisolated static func allMenu(aperture: String) -> String {
        """
        <camrply><result>ok</result><menuset><qmenu>
          <menu id="shutter"><item id="ss125" cmd_mode="setsetting" cmd_type="shtrspeed" cmd_value="1780/256" title="1/125"/></menu>
          <menu id="aperture"><item id="fmin" cmd_mode="setsetting" cmd_type="focal" cmd_value="\(aperture)" title_id="fmin"/></menu>
          <menu id="sensitivity"><item id="iso100" cmd_mode="setsetting" cmd_type="iso" cmd_value="100" title="100"/><item id="iso400" cmd_mode="setsetting" cmd_type="iso" cmd_value="400" title="400"/></menu>
        </qmenu><titlelist><language code="en" default="yes"><title id="fmin">minimum</title></language></titlelist></menuset></camrply>
        """
    }
    nonisolated static func currentMenu(shutter: Bool, aperture: Bool) -> String {
        """
        <camrply><result>ok</result><menuinfo><photosettings>
          <item id="shutter" enable="\(shutter ? "yes" : "no")"/>
          <item id="aperture" enable="\(aperture ? "yes" : "no")"/>
          <item id="sensitivity" enable="yes"/>
        </photosettings></menuinfo></camrply>
        """
    }
}
private final class ParameterReceiver: LiveViewReceiving {
    func start(endpoint: CameraEndpoint, onDatagram: @escaping @Sendable (Data) -> Void) async throws { }
    func stop() { }
}
