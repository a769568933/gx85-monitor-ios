import Foundation
import Combine
import GX85Core

@MainActor
final class CameraSettings: ObservableObject {
    private let defaults: UserDefaults
    @Published var host: String {
        didSet {
            defaults.set(host, forKey: "camera.host")
            if oldValue != host { accessID = "" }
        }
    }
    @Published var portText: String { didSet { defaults.set(portText, forKey: "camera.port") } }
    @Published var accessID: String { didSet { defaults.set(accessID, forKey: "camera.accessID") } }
    let clientID: String

    init(defaults: UserDefaults = .standard) {
        self.defaults = defaults
        host = defaults.string(forKey: "camera.host") ?? "192.168.54.1"
        portText = defaults.string(forKey: "camera.port") ?? "49152"
        accessID = defaults.string(forKey: "camera.accessID") ?? ""
        let stored = defaults.string(forKey: "camera.clientID") ?? UUID().uuidString
        clientID = stored
        defaults.set(stored, forKey: "camera.clientID")
    }

    func endpoint() throws -> CameraEndpoint {
        guard let port = UInt16(portText.trimmingCharacters(in: .whitespacesAndNewlines)) else { throw EndpointError.invalidAddress }
        return try CameraEndpoint(host: host, port: port)
    }
}
