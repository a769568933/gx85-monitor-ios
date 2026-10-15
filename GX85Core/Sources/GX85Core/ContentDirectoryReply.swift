import Foundation

public enum ContentDirectoryReply {
    public static func parse(data: Data, cameraHost: String, startingIndex: Int = 0) throws -> CameraMediaPage {
        let envelope = try BoundedCameraXML.parse(data: data, maximumSize: 4 * 1024 * 1024)
        guard startingIndex >= 0, envelope.name == "Envelope",
              let body = envelope.children.first(where: { $0.name == "Body" }),
              let reply = body.children.first(where: { $0.name == "BrowseResponse" }),
              let result = reply.children.first(where: { $0.name == "Result" }),
              let returnedText = reply.children.first(where: { $0.name == "NumberReturned" })?.text,
              let totalText = reply.children.first(where: { $0.name == "TotalMatches" })?.text,
              let returned = Int(returnedText), (0...40).contains(returned),
              let total = Int(totalText), total >= returned else { throw CameraMediaError.malformedDirectory }
        let (next, overflow) = startingIndex.addingReportingOverflow(returned)
        guard !overflow else { throw CameraMediaError.malformedDirectory }
        if returned == 0 && startingIndex < total { throw CameraMediaError.noProgress }
        // XMLParser has already removed SOAP's escaping/CDATA. Parse DIDL once,
        // so URL ampersands are decoded correctly without recursive unescaping.
        let didl = try BoundedCameraXML.parse(data: Data(result.text.utf8), maximumSize: 4 * 1024 * 1024)
        guard didl.name == "DIDL-Lite" else { throw CameraMediaError.malformedDirectory }
        var items: [CameraMediaItem] = []
        var ids = Set<String>()
        for node in didl.children where node.name == "item" || node.name == "container" {
            guard let id = node.attributes["id"], !id.isEmpty, id.utf8.count <= 1024, ids.insert(id).inserted else { throw CameraMediaError.malformedDirectory }
            let title = String((node.children.first(where: { $0.name == "title" })?.text ?? "未命名文件").prefix(256))
            var resources: [CameraMediaResource] = []
            for resource in node.children where resource.name == "res" {
                guard let rawURL = URL(string: resource.text), let info = resource.attributes["protocolInfo"] else { throw CameraMediaError.malformedDirectory }
                let url = try MediaURLPolicy.validate(rawURL, cameraHost: cameraHost)
                let parts = info.split(separator: ":", maxSplits: 3, omittingEmptySubsequences: false)
                guard parts.count == 4, parts[0].lowercased() == "http-get" else { throw CameraMediaError.malformedDirectory }
                let mime = String(parts[2]).lowercased().trimmingCharacters(in: .whitespacesAndNewlines)
                let profile = parts[3].split(separator: ";").compactMap { token -> String? in
                    let pair = token.split(separator: "=", maxSplits: 1)
                    guard pair.count == 2, pair[0].trimmingCharacters(in: .whitespacesAndNewlines).uppercased() == "PANASONIC.COM_PN" else { return nil }
                    return pair[1].trimmingCharacters(in: .whitespacesAndNewlines).uppercased()
                }.first
                let role: CameraMediaResource.Role
                switch profile {
                case "CAM_ORG", "CAM_AVC_MP4", "CAM_RAW": role = .original
                case "CAM_LRGTN", "CAM_RAW_JPG": role = .preview
                case "CAM_TN": role = .thumbnail
                default: role = .unknown
                }
                let size: Int64?
                if let raw = resource.attributes["size"] {
                    guard let value = Int64(raw), value >= 0 else { throw CameraMediaError.malformedDirectory }
                    size = value
                } else { size = nil }
                resources.append(CameraMediaResource(url: url, mimeType: mime, role: role, size: size))
            }
            let objectClass = node.children.first(where: { $0.name == "class" })?.text.lowercased() ?? ""
            let kind: CameraMediaKind
            if objectClass.contains("videoitem") || resources.contains(where: { $0.mimeType.hasPrefix("video/") }) { kind = .video }
            else if objectClass.contains("imageitem") || resources.contains(where: { $0.mimeType.hasPrefix("image/") }) { kind = .photo }
            else { kind = .other }
            items.append(CameraMediaItem(id: id, title: title, kind: kind, resources: resources, isContainer: node.name == "container"))
        }
        guard items.count == returned, returned == 0 || next <= total else { throw CameraMediaError.malformedDirectory }
        return CameraMediaPage(items: items, numberReturned: returned, totalMatches: total,
                               nextStartingIndex: next < total ? next : nil,
                               updateID: reply.children.first(where: { $0.name == "UpdateID" })?.text)
    }
}
