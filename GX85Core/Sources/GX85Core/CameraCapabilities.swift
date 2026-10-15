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
    public let diagnostics: [String]
    public init() { values = [:]; owners = [:]; diagnostics = [] }
    private init(values: [ExposureParameter: [CameraParameterOption]], diagnostics: [String], owners: [String: [String]] = [:]) {
        self.values = values; self.diagnostics = diagnostics; self.owners = owners
    }
    public func options(for parameter: ExposureParameter) -> [CameraParameterOption] { values[parameter] ?? [] }

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
        return CameraCapabilities(values: updated, diagnostics: diagnostics, owners: owners)
    }

    public func disablingOptions(reason: String) -> CameraCapabilities {
        CameraCapabilities(values: values.mapValues { $0.map { CameraParameterOption(id: $0.id, label: $0.label, rawValue: $0.rawValue, enabled: false) } }, diagnostics: diagnostics + [reason], owners: owners)
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
            let label = node.attributes["title"] ?? titles[titleID] ?? rawValue
            let enabled = !["no", "false", "0"].contains(node.attributes["enable"]?.lowercased() ?? "")
            owners[key] = nodeOwners[ObjectIdentifier(node)] ?? []
            values[parameter, default: []].append(CameraParameterOption(id: key, label: String(label.prefix(64)), rawValue: rawValue, enabled: enabled))
        }
        return CameraCapabilities(values: values, diagnostics: values.isEmpty ? ["菜单未提供可识别的曝光选项。"] : [], owners: owners)
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
