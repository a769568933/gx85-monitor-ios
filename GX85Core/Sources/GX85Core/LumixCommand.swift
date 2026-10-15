import Foundation

public enum LumixCommand: Equatable, Sendable {
    case requestAccess(clientID: String, name: String)
    case state, recordMode, stopStream, capture
    case startStream(port: UInt16)
    case getSetting(String), getInfo(String)
    case setSetting(type: String, value: String)
    case autoFocus, releaseCapture, videoStart, videoStop, playbackMode
    case touchFocus(x: Int, y: Int)

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
        case .autoFocus: items = [("mode", "camcmd"), ("value", "oneshot_af")]
        case .releaseCapture: items = [("mode", "camcmd"), ("value", "capture_cancel")]
        case .videoStart: items = [("mode", "camcmd"), ("value", "video_recstart")]
        case .videoStop: items = [("mode", "camcmd"), ("value", "video_recstop")]
        case .playbackMode: items = [("mode", "camcmd"), ("value", "playmode")]
        case let .getSetting(type):
            guard ["shtrspeed", "focal", "iso", "focusmode"].contains(type) else { throw ControlInputError.invalidParameter }
            items = [("mode", "getsetting"), ("type", type)]
        case let .getInfo(type):
            guard ["allmenu", "curmenu"].contains(type) else { throw ControlInputError.invalidParameter }
            items = [("mode", "getinfo"), ("type", type)]
        case let .setSetting(type, value):
            guard ["shtrspeed", "focal", "iso"].contains(type), !value.isEmpty, value.utf8.count <= 64,
                  value.allSatisfy({ $0.isASCII && ($0.isNumber || $0.isLetter || "/.-+_".contains($0)) })
            else { throw ControlInputError.invalidParameter }
            items = [("mode", "setsetting"), ("type", type), ("value", value)]
        case let .touchFocus(x, y):
            guard (0...1000).contains(x), (0...1000).contains(y) else { throw ControlInputError.invalidParameter }
            items = [("mode", "camctrl"), ("type", "touchaf"), ("value", "\(x)/\(y)")]
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
        case .getSetting: return "读取参数"
        case .getInfo: return "读取相机菜单"
        case .setSetting: return "设置参数"
        case .autoFocus: return "单次对焦"
        case .releaseCapture: return "释放快门"
        case .videoStart: return "开始录像"
        case .videoStop: return "停止录像"
        case .playbackMode: return "进入相册"
        case .touchFocus: return "点按对焦"
        }
    }
}

public enum ControlInputError: LocalizedError {
    case invalidParameter
    public var errorDescription: String? { "相机参数或对焦位置无效。" }
}
