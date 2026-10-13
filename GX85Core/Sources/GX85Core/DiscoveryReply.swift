import Foundation
#if canImport(FoundationXML)
import FoundationXML
#endif

public enum DiscoveryReply {
    public static func location(data: Data, cameraHost: String) -> URL? {
        guard data.count <= 8192, let text = String(data: data, encoding: .utf8),
              text.uppercased().hasPrefix("HTTP/1.1 200") else { return nil }
        for line in text.components(separatedBy: "\n") {
            guard let colon = line.firstIndex(of: ":"), line[..<colon].trimmingCharacters(in: .whitespacesAndNewlines).lowercased() == "location" else { continue }
            let address = String(line[line.index(after: colon)...]).trimmingCharacters(in: .whitespacesAndNewlines)
            guard let url = URL(string: address), url.scheme == "http", url.host == cameraHost,
                  url.user == nil, url.password == nil else { return nil }
            return url
        }
        return nil
    }

    public static func accessID(data: Data) -> String? {
        guard data.count <= 256 * 1024 else { return nil }
        let delegate = DeviceXMLParser()
        let parser = XMLParser(data: data)
        parser.shouldResolveExternalEntities = false
        parser.delegate = delegate
        guard parser.parse(), let udn = delegate.udn else { return nil }
        let id = udn.hasPrefix("uuid:") ? String(udn.dropFirst(5)) : udn
        guard !id.isEmpty, id.count <= 128, id.allSatisfy({ $0.isASCII && ($0.isLetter || $0.isNumber || $0 == "-") }) else { return nil }
        return id
    }
}

private final class DeviceXMLParser: NSObject, XMLParserDelegate {
    var udn: String?
    private var reading = false
    private var text = ""
    func parser(_ parser: XMLParser, didStartElement elementName: String, namespaceURI: String?, qualifiedName qName: String?, attributes attributeDict: [String: String] = [:]) {
        if elementName.lowercased() == "udn" { reading = true; text = "" }
    }
    func parser(_ parser: XMLParser, foundCharacters string: String) { if reading { text += string } }
    func parser(_ parser: XMLParser, didEndElement elementName: String, namespaceURI: String?, qualifiedName qName: String?) {
        if elementName.lowercased() == "udn" {
            if udn == nil { udn = text.trimmingCharacters(in: .whitespacesAndNewlines) }
            reading = false
        }
    }
}
