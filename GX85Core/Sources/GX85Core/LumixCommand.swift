import Foundation

public enum LumixCommand: Equatable, Sendable {
    case requestAccess(clientID: String, name: String)
    case state, recordMode, stopStream, capture
    case startStream(port: UInt16)

    public func makeURL(endpoint: CameraEndpoint) throws -> URL {
        var components = URLComponents()
        components.scheme = "http"
        components.host = endpoint.host
        components.path = "/cam.cgi"
        let items: [(String, String)]
        switch self {
        case let .requestAccess(id, name):
            items = [("mode", "accctrl"), ("type", "req_acc"), ("value", id), ("value2", name)]
        case .state: items = [("mode", "getstate")]
        case .recordMode: items = [("mode", "camcmd"), ("value", "recmode")]
        case .stopStream: items = [("mode", "stopstream")]
        case .capture: items = [("mode", "camcmd"), ("value", "capture")]
        case let .startStream(port): items = [("mode", "startstream"), ("value", String(port))]
        }
        components.queryItems = items.map { URLQueryItem(name: $0.0, value: $0.1) }
        guard let url = components.url else { throw EndpointError.invalidAddress }
        return url
    }

    public var label: String {
        switch self {
        case .requestAccess: return "请求连接"
        case .state: return "读取状态"
        case .recordMode: return "进入拍摄模式"
        case .startStream: return "启动监看"
        case .stopStream: return "停止监看"
        case .capture: return "快门"
        }
    }
}
