import Foundation
import XCTest
import GX85Core
@testable import GX85Monitor

@MainActor
final class CameraParameterTests: XCTestCase {
    func testUnsigned16BitShutterReadbackDisplaysActualLongExposure() async throws {
        let camera = GX80ParameterReply(shutter: "64171/256", aperture: "768/256")
        let snapshot = try await CameraParameterService(controls: CameraControlService(client: camera)).load(lens: "normal")
        XCTAssertEqual(snapshot.values[.shutter], "40s")
    }

    func testMCombinedControlExposesAndConfirmsBothShutterAndLensAperture() async throws {
        let camera = EmbeddedLensCamera(apertureEnabled: false, shutterEnabled: false, combinedEnabled: true)
        let controls = CameraControlService(client: camera)
        let parameters = CameraParameterService(controls: controls)
        let snapshot = try await parameters.load(lens: "normal")
        let shutter = try XCTUnwrap(snapshot.options[.shutter]?.first { $0.rawValue == "1792/256" })
        let aperture = try XCTUnwrap(snapshot.options[.aperture]?.first { $0.rawValue == "1024/256" })
        XCTAssertTrue(shutter.enabled)
        XCTAssertTrue(aperture.enabled)
        XCTAssertEqual(shutter.label, "1/125")
        try await controls.setParameter(.shutter, rawValue: shutter.rawValue)
        try await controls.setParameter(.aperture, rawValue: aperture.rawValue)
        let updated = try await parameters.load(lens: "normal")
        XCTAssertEqual(updated.values[.shutter], "1/125")
        XCTAssertEqual(updated.values[.aperture], "F4")
    }

    func testAperturePriorityDoesNotPresentRetainedManualShutterAsLiveExposure() async throws {
        let camera = EmbeddedLensCamera(apertureEnabled: true, shutterEnabled: false, combinedEnabled: false)
        let snapshot = try await CameraParameterService(controls: CameraControlService(client: camera)).load(lens: "normal")
        XCTAssertEqual(snapshot.values[.shutter], "自动")
        XCTAssertFalse(snapshot.options[.shutter]?.contains { $0.enabled } ?? false)
        XCTAssertEqual(snapshot.values[.aperture], "F2.8")
    }

    func testShutterPriorityAllowsShutterAndMarksApertureAutomatic() async throws {
        let camera = EmbeddedLensCamera(apertureEnabled: false, shutterEnabled: true, combinedEnabled: false)
        let snapshot = try await CameraParameterService(controls: CameraControlService(client: camera)).load(lens: "normal")
        XCTAssertEqual(snapshot.values[.shutter], "1/50")
        XCTAssertTrue(snapshot.options[.shutter]?.contains { $0.enabled } ?? false)
        XCTAssertEqual(snapshot.values[.aperture], "自动")
    }

    func testSuccessfulParameterChangeIsSilent() async throws {
        let session = await connected(ParameterCamera())
        let option = try XCTUnwrap(session.parameterOptions[.iso]?.first { $0.rawValue == "400" })
        session.updateParameter(.iso, option: option)
        for _ in 0..<400 { if !session.actionInProgress { break }; try? await Task.sleep(nanoseconds: 5_000_000) }
        XCTAssertEqual(session.parameterValues[.iso], "400")
        XCTAssertNil(session.notice)
        session.disconnect()
    }

    func testEmbeddedApertureUsesReportedLensLimitsAndCurrentModePermission() async throws {
        let client = EmbeddedLensCamera(apertureEnabled: true)
        let parameters = CameraParameterService(controls: CameraControlService(client: client))
        let snapshot = try await parameters.load(lens: "normal")
        let options = try XCTUnwrap(snapshot.options[.aperture])
        XCTAssertEqual(options.first?.rawValue, "768/256")
        XCTAssertEqual(options.first?.label, "F2.8")
        XCTAssertEqual(options.last?.rawValue, "2304/256")
        XCTAssertEqual(options.last?.label, "F22")
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(options.allSatisfy(\.enabled))
        XCTAssertEqual(snapshot.values[.aperture], "F2.8")
    }

    func testEmbeddedApertureRemainsDisabledWhenCameraControlsIt() async throws {
        let client = EmbeddedLensCamera(apertureEnabled: false)
        let parameters = CameraParameterService(controls: CameraControlService(client: client))
        let snapshot = try await parameters.load(lens: "normal")
        let options = try XCTUnwrap(snapshot.options[.aperture])
        XCTAssertFalse(options.isEmpty)
        XCTAssertTrue(options.allSatisfy { !$0.enabled })
    }

    func testInvalidLensRangeDoesNotInventApertureOptions() async throws {
        let client = EmbeddedLensCamera(apertureEnabled: true, lensInfo: "ok,512/256,768/256,0,0,0,off,0,0")
        let parameters = CameraParameterService(controls: CameraControlService(client: client))
        let snapshot = try await parameters.load(lens: "normal")
        XCTAssertTrue(snapshot.options[.aperture]?.isEmpty == true)
    }

    func testGX80APEXValuesDisplayAsExposureWithoutMenuOptions() async throws {
        // 768/256 is the actual value in the user's GX80 diagnostics for both parameters.
        // Other literals cross-check conventional Lumix APEX shutter and aperture stops.
        let samples = [
            ("768/256", "768/256", "1/8", "F2.8"),
            ("1792/256", "392/256", "1/125", "F1.7"),
            ("2560/256", "1366/256", "1/1000", "F6.3"),
            ("0/256", "2304/256", "1s", "F22"),
            ("-256/256", "1024/256", "2s", "F4"),
            ("16384/256", "512/256", "B", "F2"),
            ("future/256", "NaN", "—", "—")
        ]
        for (shutter, aperture, expectedShutter, expectedAperture) in samples {
            let client = GX80ParameterReply(shutter: shutter, aperture: aperture)
            let parameters = CameraParameterService(controls: CameraControlService(client: client))
            let snapshot = try await parameters.load(lens: "normal")
            XCTAssertEqual(snapshot.values[.shutter], expectedShutter, shutter)
            XCTAssertEqual(snapshot.values[.aperture], expectedAperture, aperture)
            XCTAssertEqual(snapshot.values[.iso], "200")
            XCTAssertTrue(snapshot.options[.shutter]?.isEmpty == true)
        }
    }

    func testUnlabelledExposureMenuPreservesWireValueAndFormatsItsLabel() throws {
        let xml = """
        <camrply><result>ok</result><menuset><qmenu>
          <item id="ss8" cmd_mode="setsetting" cmd_type="shtrspeed" cmd_value="768/256"/>
          <item id="f28" cmd_mode="setsetting" cmd_type="focal" cmd_value="768/256"/>
        </qmenu></menuset></camrply>
        """
        let all = try CameraCapabilities.parse(data: Data(xml.utf8))
        XCTAssertEqual(all.options(for: .shutter).first?.label, "1/8")
        XCTAssertEqual(all.options(for: .aperture).first?.label, "F2.8")
        XCTAssertEqual(all.options(for: .shutter).first?.rawValue, "768/256")
        XCTAssertEqual(all.options(for: .aperture).first?.rawValue, "768/256")
    }

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

/// Synthetic GX80 embedded-menu structure and documented Lumix lens CSV layout.
private actor EmbeddedLensCamera: CommandSending {
    let apertureEnabled: Bool
    let lensInfo: String
    let shutterEnabled: Bool?
    let combinedEnabled: Bool?
    private var values = ["focal": "768/256", "shtrspeed": "1451/256", "iso": "200"]
    init(apertureEnabled: Bool, lensInfo: String = "ok,2304/256,768/256,0,0,0,off,0,0", shutterEnabled: Bool? = nil, combinedEnabled: Bool? = nil) {
        self.apertureEnabled = apertureEnabled; self.lensInfo = lensInfo
        self.shutterEnabled = shutterEnabled; self.combinedEnabled = combinedEnabled
    }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        if command == .getInfo("allmenu") {
            return try LumixResponse.parseMenu(data: Data("<camrply><result>ok</result><menuset model=\"GX80\"><qmenu><item id=\"menu_item_id_aperture\" func_type=\"sp_embeded_aperture\"/><item id=\"menu_item_id_shutter_speed\" func_type=\"sp_embeded_shutter_speed\"/><item id=\"menu_item_id_f_and_ss\" func_type=\"sp_embeded_f_and_ss\"/></qmenu></menuset></camrply>".utf8))
        }
        if command == .getInfo("curmenu") {
            let extra = [("menu_item_id_shutter_speed", shutterEnabled), ("menu_item_id_f_and_ss", combinedEnabled)].compactMap { id, enabled -> String? in
                guard let enabled else { return nil }; return "<item id=\"\(id)\" enable=\"\(enabled ? "yes" : "no")\"/>"
            }.joined()
            return try LumixResponse.parseMenu(data: Data("<camrply><result>ok</result><menuinfo model=\"MC262\"><qmenu2><item id=\"menu_item_id_aperture\" enable=\"\(apertureEnabled ? "yes" : "no")\"/>\(extra)</qmenu2></menuinfo></camrply>".utf8))
        }
        if command == .getInfo("lens") { return try LumixResponse.parseMenu(data: Data(lensInfo.utf8)) }
        if case .setSetting(let type, let value) = command { values[type] = value }
        if case .getSetting(let type) = command { return LumixResponse(status: .success, fields: [type: values[type] ?? ""]) }
        return LumixResponse(status: .success)
    }
}

private actor GX80ParameterReply: CommandSending {
    let shutter: String
    let aperture: String
    init(shutter: String, aperture: String) { self.shutter = shutter; self.aperture = aperture }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        if command == .getInfo("allmenu") {
            return try LumixResponse.parseMenu(data: Data("<camrply><result>ok</result><menuset model=\"GX80\"><qmenu/></menuset></camrply>".utf8))
        }
        if command == .getInfo("curmenu") {
            return try LumixResponse.parseMenu(data: Data("<camrply><result>ok</result><menuinfo model=\"MC262\"><qmenu2/></menuinfo></camrply>".utf8))
        }
        if case .getSetting(let type) = command {
            let raw = type == "shtrspeed" ? shutter : (type == "focal" ? aperture : "200")
            return try LumixResponse.parse(data: Data("<camrply><result>ok</result><settingvalue \(type)=\"\(raw)\"/></camrply>".utf8))
        }
        return LumixResponse(status: .success)
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
