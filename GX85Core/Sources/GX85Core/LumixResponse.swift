import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public struct LumixResponse: Equatable, Sendable {
    public enum Status: Equatable, Sendable {
        case success, pendingApproval
        case rejected(String)
    }
    public let status: Status
    public let fields: [String: String]
    public let summary: String
    public let body: Data

    public init(status: Status, fields: [String: String] = [:], summary: String = "", body: Data = Data()) {
        self.status = status
        self.fields = fields
        self.summary = String(summary.prefix(512))
        self.body = body
    }

    public static func parse(data: Data) throws -> LumixResponse {
        try parse(data: data, maximumSize: 256 * 1024)
    }

    public static func parseMenu(data: Data) throws -> LumixResponse {
        try parse(data: data, maximumSize: 2 * 1024 * 1024)
    }

    private static func parse(data: Data, maximumSize: Int) throws -> LumixResponse {
        guard data.count <= maximumSize,
              let raw = String(data: data, encoding: .utf8) else { throw ResponseError.malformed }
        let text = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !text.isEmpty else { throw ResponseError.malformed }
        var fields: [String: String] = [:]
        let result: String
        if text.hasPrefix("<") {
            let delegate = ReplyXMLParser()
            let parser = XMLParser(data: Data(text.utf8))
            parser.shouldResolveExternalEntities = false
            parser.delegate = delegate
            guard parser.parse(), delegate.root == "camrply", let value = delegate.fields["result"] else {
                throw ResponseError.malformed
            }
            result = value
            fields = delegate.fields
        } else {
            let tokens = text.split(separator: ",", omittingEmptySubsequences: false)
            result = String(tokens[0])
                .trimmingCharacters(in: .whitespacesAndNewlines)
            if tokens.count == 2 { fields["value"] = String(tokens[1]).trimmingCharacters(in: .whitespacesAndNewlines) }
        }
        let token = result.lowercased()
        let status: Status
        if token == "ok" { status = .success }
        else if token == "err_wait" { status = .pendingApproval }
        else if token.hasPrefix("err_") { status = .rejected(token) }
        else { throw ResponseError.malformed }
        return LumixResponse(status: status, fields: fields, summary: text, body: data)
    }
}

public enum ResponseError: LocalizedError {
    case malformed
    public var errorDescription: String? { "无法识别相机回应，请在诊断页查看记录。" }
}

private final class ReplyXMLParser: NSObject, XMLParserDelegate {
    var root: String?
    var fields: [String: String] = [:]
    private var path: [String] = []
    private var textStack: [String] = []

    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if root == nil { root = elementName.lowercased() }
        path.append(elementName.lowercased())
        textStack.append("")
        if path == ["camrply", "settingvalue"] {
            for name in ["focusmode", "focal", "shtrspeed", "iso"] {
                if let value = attributeDict[name] { fields[name] = value }
            }
        }
    }

    func parser(_ parser: XMLParser, foundCharacters string: String) {
        guard !textStack.isEmpty else { return }
        textStack[textStack.count - 1] += string
    }

    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        guard let value = textStack.popLast(), let name = path.popLast() else { return }
        let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines)
        if !trimmed.isEmpty {
            // Only the direct result field is authoritative, never a nested metadata result.
            if name != "result" || path == ["camrply"] { fields[name] = trimmed }
        }
    }
}
