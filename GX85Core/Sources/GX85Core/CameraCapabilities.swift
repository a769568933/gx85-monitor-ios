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
    public let diagnostics: [String]
    public init() { values = [:]; diagnostics = [] }
    private init(values: [ExposureParameter: [CameraParameterOption]], diagnostics: [String]) {
        self.values = values; self.diagnostics = diagnostics
    }
    public func options(for parameter: ExposureParameter) -> [CameraParameterOption] { values[parameter] ?? [] }

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
            values[parameter, default: []].append(CameraParameterOption(id: node.attributes["id"] ?? key, label: label, rawValue: rawValue, enabled: enabled))
        }
        return CameraCapabilities(values: values, diagnostics: values.isEmpty ? ["菜单未提供可识别的曝光选项。"] : [])
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
