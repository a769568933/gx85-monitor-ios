import Foundation

public struct CameraEndpoint: Equatable, Sendable {
    public let host: String
    public let port: UInt16

    public init(host: String, port: UInt16 = 49152) throws {
        let trimmed = host.trimmingCharacters(in: .whitespacesAndNewlines)
        let parts = trimmed.split(separator: ".", omittingEmptySubsequences: false)
        guard parts.count == 4, port > 0 else { throw EndpointError.invalidAddress }
        var octets: [UInt8] = []
        for part in parts {
            guard !part.isEmpty, part.allSatisfy({ $0.isASCII && $0.isNumber }),
                  let value = UInt8(part) else { throw EndpointError.invalidAddress }
            octets.append(value)
        }
        guard octets[0] > 0, octets[0] < 224 else { throw EndpointError.invalidAddress }
        self.host = octets.map(String.init).joined(separator: ".")
        self.port = port
    }
}

public enum EndpointError: LocalizedError {
    case invalidAddress
    public var errorDescription: String? { "请输入有效的相机 IPv4 地址和 1–65535 之间的端口。" }
}
