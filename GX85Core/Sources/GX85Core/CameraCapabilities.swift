import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum ExposureParameter: String, CaseIterable, Sendable {
    case shutter, aperture, iso
    public var commandType: String {
        switch self { case .shutter: return "shtrspeed"; case .aperture: return "focal"; case .iso: return "iso" }
    }
    public var label: String {
        switch self { case .shutter: return "快门"; case .aperture: return "光圈"; case .iso: return "ISO" }
    }

    /// Lumix encodes Tv and Av in units of 1/256 stop, not literal seconds/f-numbers.
    /// This is presentation only; never replace a menu option's raw wire value.
    public func displayValue(for rawValue: String) -> String? {
        let raw = rawValue.trimmingCharacters(in: .whitespacesAndNewlines)
        if raw.lowercased() == "auto" { return "自动" }
        if self == .iso {
            if raw.lowercased() == "i_iso" { return "智能自动" }
            guard let value = Int(raw), value > 0, value <= 10_000_000 else { return nil }
            return String(value)
        }
        let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
        guard parts.count == 2, parts[1] == "256", let numerator = Int(parts[0]) else { return nil }
        if self == .shutter, numerator == 16384 { return "B" }
        let lowerBound = self == .shutter ? -2048 : -512
        guard (lowerBound...4096).contains(numerator) else { return nil }
        let apex = Double(numerator) / 256
        if self == .aperture {
            let fNumber = pow(2, apex / 2)
            let stops: [Double] = [0.5, 0.6, 0.7, 0.8, 0.9, 0.95, 1, 1.1, 1.2, 1.4, 1.6, 1.7, 1.8, 2, 2.2, 2.5, 2.8, 3.2, 3.5, 4, 4.5, 5, 5.6, 6.3, 7.1, 8, 9, 10, 11, 13, 14, 16, 18, 20, 22, 25, 29, 32, 36, 40, 45, 51, 57, 64]
            return "F" + Self.number(Self.nominal(fNumber, stops: stops))
        }
        let stops: [Double] = [1, 1.3, 1.6, 2, 2.5, 3.2, 4, 5, 6, 8, 10, 13, 15, 20, 25, 30, 40, 50, 60, 80, 100, 125, 160, 200, 250, 320, 400, 500, 640, 800, 1000, 1250, 1600, 2000, 2500, 3200, 4000, 5000, 6400, 8000, 10000, 12800, 16000, 20000, 25600, 32000, 40000, 51200, 64000]
        if numerator <= 0 { return Self.number(Self.nominal(pow(2, -apex), stops: stops)) + "s" }
        return "1/" + Self.number(Self.nominal(pow(2, apex), stops: stops))
    }

    private static func nominal(_ value: Double, stops: [Double]) -> Double {
        guard let closest = stops.min(by: { abs(log($0 / value)) < abs(log($1 / value)) }),
              abs(log(closest / value)) < 0.05 else { return value }
        return closest
    }

    private static func number(_ value: Double) -> String {
        if value == value.rounded() { return String(Int(value)) }
        return String(format: value < 1 ? "%.2g" : "%.2f", locale: Locale(identifier: "en_US_POSIX"), value)
            .replacingOccurrences(of: #"\.?(0+)$"#, with: "", options: .regularExpression)
    }
}

public struct CameraParameterOption: Equatable, Identifiable, Sendable {
    public let id: String
    public let label: String
    public let rawValue: String
    public let enabled: Bool
    public init(id: String, label: String, rawValue: String, enabled: Bool) {
        self.id = id; self.label = label; self.rawValue = rawValue; self.enabled = enabled
    }
}

public struct CameraCapabilities: Equatable, Sendable {
    private let values: [ExposureParameter: [CameraParameterOption]]
    private let owners: [String: [String]]
    private let embeddedAperture: Bool
    public let diagnostics: [String]
    public init() { values = [:]; owners = [:]; diagnostics = []; embeddedAperture = false }
    private init(values: [ExposureParameter: [CameraParameterOption]], diagnostics: [String], owners: [String: [String]] = [:], embeddedAperture: Bool = false) {
        self.values = values; self.diagnostics = diagnostics; self.owners = owners; self.embeddedAperture = embeddedAperture
    }
    public func options(for parameter: ExposureParameter) -> [CameraParameterOption] { values[parameter] ?? [] }

    public var requiresLensApertureLimits: Bool { embeddedAperture && values[.aperture]?.isEmpty != false }

    public func withLensApertureLimits(data: Data) throws -> CameraCapabilities {
        guard requiresLensApertureLimits else { return self }
        guard data.count <= 4096, let text = String(data: data, encoding: .utf8) else { throw ResponseError.malformed }
        let fields = text.trimmingCharacters(in: .whitespacesAndNewlines).split(separator: ",", omittingEmptySubsequences: false).map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
        func numerator(_ raw: String) -> Int? {
            let parts = raw.split(separator: "/", omittingEmptySubsequences: false)
            guard parts.count == 2, parts[1] == "256", let n = Int(parts[0]), (-512...4096).contains(n) else { return nil }
            return n
        }
        // Lumix lens CSV reports closed aperture at index 1 and opened at index 2.
        guard fields.count >= 9, fields[0] == "ok", let closed = numerator(fields[1]),
              let opened = numerator(fields[2]), opened <= closed else { throw ResponseError.malformed }
        // Verified Lumix stop codes; retain the lens's exact endpoints as well.
        let known = [392, 427, 512, 598, 683, 768, 854, 938, 1024, 1110, 1195, 1280, 1366, 1451, 1536, 1622, 1707, 1792, 1878, 1963, 2048, 2134, 2219, 2304]
        let codes = Set(known.filter { (opened...closed).contains($0) } + [opened, closed]).sorted()
        var updated = values, updatedOwners = owners
        updated[.aperture] = codes.compactMap { code in
            let raw = "\(code)/256", id = ExposureParameter.aperture.rawValue + ":" + raw
            guard let label = ExposureParameter.aperture.displayValue(for: raw) else { return nil }
            updatedOwners[id] = ["menu_item_id_aperture"]
            return CameraParameterOption(id: id, label: label, rawValue: raw, enabled: true)
        }
        let messages = diagnostics.filter { !$0.hasPrefix("光圈未提供离散选项") && $0 != "菜单未提供可识别的曝光选项。" }
            + ["镜头光圈范围：\(opened)/256…\(closed)/256；可用性以当前菜单为准。"]
        return CameraCapabilities(values: updated, diagnostics: messages, owners: updatedOwners, embeddedAperture: embeddedAperture)
    }

    public static func supportsVGALiveView(menu data: Data) throws -> Bool {
        let root = try BoundedCameraXML.parse(data: data, maximumSize: 2 * 1024 * 1024)
        guard root.name == "camrply", root.children.first(where: { $0.name == "result" })?.text == "ok",
              let menu = root.children.first(where: { $0.name == "menuset" }) else { throw ResponseError.malformed }
        func containsEnabledVGA(_ node: CameraXMLNode) -> Bool {
            if ["no", "false", "0", "off"].contains(node.attributes["enable"]?.lowercased() ?? "") { return false }
            if node.attributes["cmd_mode"] == "setsetting", node.attributes["cmd_type"] == "liveviewsize",
               node.attributes["cmd_value"] == "vga" { return true }
            return node.children.contains(where: containsEnabledVGA)
        }
        return containsEnabledVGA(menu)
    }

    public static func driveMode(currentMenu data: Data) throws -> String? {
        let root = try BoundedCameraXML.parse(data: data, maximumSize: 2 * 1024 * 1024)
        guard root.name == "camrply", root.children.first(where: { $0.name == "result" })?.text == "ok",
              let info = root.children.first(where: { $0.name == "menuinfo" }) else { throw ResponseError.malformed }
        let modes = Set(info.descendants.filter { $0.attributes["id"] == "menu_item_id_drivemode" }.compactMap { node -> String? in
            guard let value = node.attributes["value"], !value.isEmpty, value.utf8.count <= 64 else { return nil }
            return value.lowercased()
        })
        return modes.count == 1 ? modes.first : nil
    }

    public func applyingCurrentMenu(data: Data) throws -> CameraCapabilities {
        let root = try BoundedCameraXML.parse(data: data, maximumSize: 2 * 1024 * 1024)
        guard root.name == "camrply", root.children.first(where: { $0.name == "result" })?.text == "ok",
              let info = root.children.first(where: { $0.name == "menuinfo" }) else { throw ResponseError.malformed }
        var flags: [String: Bool] = [:]
        for node in info.descendants {
            guard let id = node.attributes["id"], let raw = node.attributes["enable"]?.lowercased() else { continue }
            if ["yes", "true", "1", "on"].contains(raw) { flags[id] = true }
            else if ["no", "false", "0", "off"].contains(raw) { flags[id] = false }
        }
        let updated = values.mapValues { options in
            options.map { option in
                let permissions = (owners[option.id] ?? []).compactMap { flags[$0] }
                return CameraParameterOption(id: option.id, label: option.label, rawValue: option.rawValue,
                                             enabled: option.enabled && permissions.contains(true) && !permissions.contains(false))
            }
        }
        let interesting = ["menu_item_id_aperture", "menu_item_id_shutter_speed", "menu_item_id_f_and_ss", "menu_item_id_drivemode"]
        let details = info.descendants.filter { interesting.contains($0.attributes["id"] ?? "") }.prefix(6).map { node in
            ["id", "enable", "value"].compactMap { key in node.attributes[key].map { "\(key)=\($0)" } }.joined(separator: ",")
        }
        return CameraCapabilities(values: updated, diagnostics: diagnostics + details.map { "当前菜单：" + $0 }, owners: owners, embeddedAperture: embeddedAperture)
    }

    public func disablingOptions(reason: String) -> CameraCapabilities {
        CameraCapabilities(values: values.mapValues { $0.map { CameraParameterOption(id: $0.id, label: $0.label, rawValue: $0.rawValue, enabled: false) } }, diagnostics: diagnostics + [reason], owners: owners, embeddedAperture: embeddedAperture)
    }

    public static func parse(data: Data) throws -> CameraCapabilities {
        let root = try BoundedCameraXML.parse(data: data, maximumSize: 2 * 1024 * 1024)
        guard root.name == "camrply", root.children.first(where: { $0.name == "result" })?.text == "ok",
              let menu = root.children.first(where: { $0.name == "menuset" }) else { throw ResponseError.malformed }
        var titles: [String: String] = [:]
        // Prefer the declared default language, otherwise the first available language.
        let titleList = menu.descendants.first(where: { $0.name == "titlelist" })
        let language = titleList?.children.first(where: { $0.attributes["default"] == "yes" }) ?? titleList?.children.first
        for title in language?.descendants ?? [] where title.name == "title" {
            if let id = title.attributes["id"], !title.text.isEmpty { titles[id] = title.text }
        }
        var values: [ExposureParameter: [CameraParameterOption]] = [:]
        var nodeOwners: [ObjectIdentifier: [String]] = [:]
        func collectOwners(_ node: CameraXMLNode, path: [String]) {
            let next = path + (node.attributes["id"].map { [$0] } ?? [])
            nodeOwners[ObjectIdentifier(node)] = next
            for child in node.children { collectOwners(child, path: next) }
        }
        collectOwners(menu, path: [])
        var owners: [String: [String]] = [:]
        var seen = Set<String>()
        for node in menu.descendants where node.name == "item" {
            guard node.attributes["cmd_mode"] == "setsetting",
                  let parameter = ExposureParameter.allCases.first(where: { $0.commandType == node.attributes["cmd_type"] }),
                  let rawValue = node.attributes["cmd_value"], !rawValue.isEmpty else { continue }
            let key = parameter.rawValue + ":" + rawValue
            guard seen.insert(key).inserted else { continue }
            let titleID = node.attributes["title_id"] ?? ""
            let provided = node.attributes["title"] ?? titles[titleID]
            let label = provided.flatMap { $0.isEmpty || $0 == rawValue ? nil : $0 } ?? parameter.displayValue(for: rawValue) ?? "未知"
            let enabled = !["no", "false", "0"].contains(node.attributes["enable"]?.lowercased() ?? "")
            owners[key] = nodeOwners[ObjectIdentifier(node)] ?? []
            values[parameter, default: []].append(CameraParameterOption(id: key, label: String(label.prefix(64)), rawValue: rawValue, enabled: enabled))
        }
        var diagnostics = values.isEmpty ? ["菜单未提供可识别的曝光选项。"] : []
        for parameter in ExposureParameter.allCases where values[parameter]?.isEmpty != false {
            let identifiers: [String]
            switch parameter {
            case .shutter: identifiers = ["menu_item_id_shutter_speed", "menu_item_id_f_and_ss"]
            case .aperture: identifiers = ["menu_item_id_aperture", "menu_item_id_f_and_ss"]
            case .iso: identifiers = ["menu_item_id_sensitivity"]
            }
            let details = menu.descendants.filter { identifiers.contains($0.attributes["id"] ?? "") }.prefix(3).map { node in
                ["id", "func_type", "cmd_mode", "cmd_type", "cmd_value", "min", "max", "step"].compactMap { key in node.attributes[key].map { "\(key)=\($0)" } }.joined(separator: ",")
            }.joined(separator: ";")
            diagnostics.append("\(parameter.label)未提供离散选项" + (details.isEmpty ? "。" : "：\(details)"))
        }
        let model = (menu.attributes["model"] ?? "").uppercased()
        let embedded = ["GX80", "GX85", "DMC-GX80", "DMC-GX85"].contains(model)
            && menu.descendants.contains { $0.attributes["id"] == "menu_item_id_aperture" && $0.attributes["func_type"] == "sp_embeded_aperture" }
        return CameraCapabilities(values: values, diagnostics: diagnostics, owners: owners, embeddedAperture: embedded)
    }
}

// Shared bounded tree for camera XML. It is confined to a parse call and never crosses actors.
final class CameraXMLNode {
    let name: String
    let attributes: [String: String]
    var text = ""
    var children: [CameraXMLNode] = []
    init(name: String, attributes: [String: String]) { self.name = name; self.attributes = attributes }
    var descendants: [CameraXMLNode] { children.flatMap { [$0] + $0.descendants } }
}

final class BoundedCameraXML: NSObject, XMLParserDelegate {
    private var stack: [CameraXMLNode] = []
    private var root: CameraXMLNode?
    private var count = 0
    private var invalid = false
    static func parse(data: Data, maximumSize: Int) throws -> CameraXMLNode {
        guard data.count <= maximumSize, let text = String(data: data, encoding: .utf8),
              !text.uppercased().contains("<!DOCTYPE"), !text.uppercased().contains("<!ENTITY") else { throw ResponseError.malformed }
        let delegate = BoundedCameraXML()
        let parser = XMLParser(data: data)
        parser.shouldProcessNamespaces = true
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), !delegate.invalid, let root = delegate.root else { throw ResponseError.malformed }
        return root
    }
    func parser(_ parser: XMLParser, didStartElement name: String, namespaceURI: String?, qualifiedName: String?, attributes: [String: String] = [:]) {
        count += 1
        guard stack.count < 64, count <= 20_000 else { invalid = true; parser.abortParsing(); return }
        let node = CameraXMLNode(name: name, attributes: attributes)
        if let parent = stack.last { parent.children.append(node) } else { root = node }
        stack.append(node)
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { stack.last?.text += string }
    func parser(_ parser: XMLParser, foundCDATA CDATABlock: Data) { stack.last?.text += String(decoding: CDATABlock, as: UTF8.self) }
    func parser(_ parser: XMLParser, didEndElement name: String, namespaceURI: String?, qualifiedName: String?) {
        if let node = stack.popLast() { node.text = node.text.trimmingCharacters(in: .whitespacesAndNewlines) }
    }
}
