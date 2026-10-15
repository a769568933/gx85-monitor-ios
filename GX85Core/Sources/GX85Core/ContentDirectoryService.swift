import Foundation

public struct ContentDirectoryService: Sendable {
    public let url: URL
    public let serviceType: String

    public static func fallback(cameraHost: String) throws -> ContentDirectoryService {
        let host = try CameraEndpoint(host: cameraHost).host
        let url = URL(string: "http://\(host):60606/Server0/CDS_control")!
        return ContentDirectoryService(url: url, serviceType: "urn:schemas-upnp-org:service:ContentDirectory:1")
    }

    public static func parseDescription(data: Data, descriptionURL: URL, cameraHost: String) throws -> ContentDirectoryService {
        let description = try MediaURLPolicy.validate(descriptionURL, cameraHost: cameraHost)
        let root = try BoundedCameraXML.parse(data: data, maximumSize: 256 * 1024)
        guard root.name == "root" else { throw CameraMediaError.malformedDirectory }
        var base = description
        if let raw = root.children.first(where: { $0.name == "URLBase" })?.text, !raw.isEmpty {
            guard let candidate = URL(string: raw, relativeTo: description)?.absoluteURL else { throw CameraMediaError.invalidURL }
            base = try MediaURLPolicy.validate(candidate, cameraHost: cameraHost)
        }
        for service in root.descendants where service.name == "service" {
            guard let type = service.children.first(where: { $0.name == "serviceType" })?.text,
                  ["urn:schemas-upnp-org:service:ContentDirectory:1", "urn:schemas-upnp-org:service:ContentDirectory:2"].contains(type),
                  let raw = service.children.first(where: { $0.name == "controlURL" })?.text,
                  let candidate = URL(string: raw, relativeTo: base)?.absoluteURL else { continue }
            return ContentDirectoryService(url: try MediaURLPolicy.validate(candidate, cameraHost: cameraHost), serviceType: type)
        }
        throw CameraMediaError.malformedDirectory
    }
}
