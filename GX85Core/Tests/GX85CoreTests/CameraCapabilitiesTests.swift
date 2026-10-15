import Foundation
import XCTest
@testable import GX85Core

final class CameraCapabilitiesTests: XCTestCase {
    // Synthetic protocol fixture using Lumix menuset item attributes; not a captured GX85 reply.
    private let menu = """
    <camrply><result>ok</result><menuset model="DMC-GX85" version="1">
      <qmenu><menu id="menu_item_id_f_and_ss_angle"><group>
        <item id="aperture_17" cmd_mode="setsetting" cmd_type="focal" cmd_value="392/256" title_id="f17" enable="yes"/>
        <item id="aperture_22" cmd_mode="setsetting" cmd_type="focal" cmd_value="598/256" title_id="f22" enable="no"/>
        <item id="shutter_125" cmd_mode="setsetting" cmd_type="shtrspeed" cmd_value="1780/256" title="1/125"/>
      </group></menu><menu id="menu_item_id_sensitivity">
        <item id="iso_400" cmd_mode="setsetting" cmd_type="iso" cmd_value="400" title="400"/>
      </menu></qmenu>
      <titlelist><lang code="en" default="yes"><title id="f17">F1.7</title><title id="f22">F2.2</title></lang></titlelist>
    </menuset></camrply>
    """

    func testMenuPreservesRawApertureValue() throws {
        let options = try CameraCapabilities.parse(data: Data(menu.utf8)).options(for: .aperture)
        XCTAssertEqual(options.map(\.rawValue), ["392/256", "598/256"])
        XCTAssertEqual(options.map(\.label), ["F1.7", "F2.2"])
        XCTAssertEqual(options.map(\.enabled), [true, false])
    }

    func testNestedMenuRoutesOptionsToMatchingParameter() throws {
        let capabilities = try CameraCapabilities.parse(data: Data(menu.utf8))
        XCTAssertEqual(capabilities.options(for: .shutter).map(\.rawValue), ["1780/256"])
        XCTAssertEqual(capabilities.options(for: .iso).map(\.rawValue), ["400"])
    }

    func testUnknownMenusDoNotInventExposureOptions() throws {
        let xml = "<camrply><result>ok</result><menuset><item cmd_mode=\"camcmd\" cmd_type=\"future\" cmd_value=\"capture\"/></menuset></camrply>"
        let capabilities = try CameraCapabilities.parse(data: Data(xml.utf8))
        for parameter in ExposureParameter.allCases {
            XCTAssertTrue(capabilities.options(for: parameter).isEmpty)
        }
    }

    func testMenuRequiresSuccessfulReplyAndWellFormedXML() {
        for xml in ["<camrply><result>err_busy</result><menuset/></camrply>", "<camrply><result>ok</result><menuset>", "<html><result>ok</result></html>"] {
            XCTAssertThrowsError(try CameraCapabilities.parse(data: Data(xml.utf8)), xml)
        }
    }

    func testMenuHasSeparateBoundedResponseBudget() throws {
        let xml = "<camrply><result>ok</result><menuset><!--" + String(repeating: "x", count: 300_000) + "--></menuset></camrply>"
        XCTAssertNoThrow(try CameraCapabilities.parse(data: Data(xml.utf8)))
        XCTAssertThrowsError(try LumixResponse.parse(data: Data(xml.utf8)))
        XCTAssertThrowsError(try CameraCapabilities.parse(data: Data(repeating: 120, count: 2 * 1024 * 1024 + 1)))
    }

    func testExternalEntitiesAreNotExpanded() {
        let xml = "<!DOCTYPE camrply [<!ENTITY value SYSTEM 'file:///does-not-exist'>]><camrply><result>ok</result><menuset><item cmd_mode=\"setsetting\" cmd_type=\"iso\" cmd_value=\"&value;\"/></menuset></camrply>"
        XCTAssertThrowsError(try CameraCapabilities.parse(data: Data(xml.utf8)))
    }
}
