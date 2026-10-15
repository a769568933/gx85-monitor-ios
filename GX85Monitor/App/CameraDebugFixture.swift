#if DEBUG && targetEnvironment(simulator)
import SwiftUI
import UIKit
import GX85Core

@MainActor
final class FixtureStatusModel: ObservableObject {
    @Published var focusRequests = 0
}

struct FixtureStatusBadge: View {
    @ObservedObject var model: FixtureStatusModel
    var onNotice: () -> Void = {}
    var body: some View {
        HStack(spacing: 6) {
        Text("模拟画面 · 非相机连接")
            .font(.caption.weight(.semibold)).foregroundStyle(.yellow).padding(6)
            .background(.black.opacity(0.85), in: Capsule())
            .accessibilityElement(children: .ignore)
            .accessibilityLabel("模拟画面 · 非相机连接")
            .accessibilityValue("对焦请求:\(model.focusRequests)")
            .accessibilityIdentifier("fixtureStatus")
            .allowsHitTesting(false)
        Button(action: onNotice) { Image(systemName: "text.bubble").frame(width: 44, height: 44) }
            .foregroundStyle(.yellow).background(.black.opacity(0.8), in: Circle())
            .accessibilityLabel("显示模拟提示").accessibilityIdentifier("fixtureNotice")
        }
    }
}

@MainActor
final class CameraDebugFixture {
    let session: CameraSession
    let status: FixtureStatusModel
    init() {
        let status = FixtureStatusModel()
        self.status = status
        let commands = FixtureCommands(recording: ProcessInfo.processInfo.arguments.contains("--fixture-recording"), onFocus: { [weak status] in
            Task { @MainActor in status?.focusRequests += 1 }
        })
        let settings = CameraSettings(defaults: UserDefaults(suiteName: "GX85-simulator-\(UUID().uuidString)")!)
        settings.accessID = "simulator-fixture"
        let frame = Self.frame()
        FixtureMediaProtocol.frame = frame
        // A single test card and a paused monitor clock keep UI-test idle detection deterministic.
        session = CameraSession(settings: settings, makeClient: { _ in commands }, makeReceiver: { FixtureReceiver(frame: frame) }, sleep: { _ in try await Task.sleep(nanoseconds: 60_000_000_000) }, makeMediaClient: { endpoint in
            let config = URLSessionConfiguration.ephemeral
            config.protocolClasses = [FixtureMediaProtocol.self]
            return CameraMediaClient(endpoint: endpoint, configuration: config)
        })
        session.connect()
    }
    private static func frame() -> Data {
        let size = CGSize(width: 1280, height: 960)
        let format = UIGraphicsImageRendererFormat(); format.scale = 1
        let image = UIGraphicsImageRenderer(size: size, format: format).image { renderer in
            let context = renderer.cgContext
            UIColor(red: 0.08, green: 0.13, blue: 0.17, alpha: 1).setFill()
            context.fill(CGRect(origin: .zero, size: size))
            UIColor(red: 0.22, green: 0.33, blue: 0.36, alpha: 1).setFill()
            context.fill(CGRect(x: 0, y: 480, width: 1280, height: 480))
            context.setStrokeColor(UIColor.white.withAlphaComponent(0.18).cgColor)
            context.setLineWidth(2)
            for x in [426.0, 853.0] { context.move(to: CGPoint(x: x, y: 0)); context.addLine(to: CGPoint(x: x, y: 960)) }
            for y in [320.0, 640.0] { context.move(to: CGPoint(x: 0, y: y)); context.addLine(to: CGPoint(x: 1280, y: y)) }
            context.strokePath()
            UIColor(red: 0.92, green: 0.6, blue: 0.24, alpha: 1).setFill()
            context.fillEllipse(in: CGRect(x: 540, y: 380, width: 200, height: 200))
            let attributes: [NSAttributedString.Key: Any] = [.font: UIFont.monospacedSystemFont(ofSize: 30, weight: .medium), .foregroundColor: UIColor.white]
            ("GX85 MONITOR / SIMULATOR" as NSString).draw(at: CGPoint(x: 56, y: 72), withAttributes: attributes)
            ("4:3  |  TEST CARD" as NSString).draw(at: CGPoint(x: 56, y: 858), withAttributes: attributes)
        }
        return image.jpegData(compressionQuality: 0.85)!
    }
}

private actor FixtureCommands: CommandSending {
    private var recording = false
    private var playback = false
    private var values = ["iso": "100", "focal": "392/256", "shtrspeed": "1780/256", "focusmode": "afs"]
    private let onFocus: @Sendable () -> Void
    init(recording: Bool, onFocus: @escaping @Sendable () -> Void) { self.recording = recording; self.onFocus = onFocus }
    func send(_ command: LumixCommand) async throws -> LumixResponse {
        if command == .getInfo("allmenu") {
            let apertures = [392, 427, 512, 598, 683, 768, 854, 938, 1024, 1110, 1195, 1280, 1366, 1451, 1536, 1622, 1707, 1792, 1878, 1963, 2048, 2134, 2219, 2304].map { code in
                "<item id=\"f\(code)\" cmd_mode=\"setsetting\" cmd_type=\"focal\" cmd_value=\"\(code)/256\" title=\"\(ExposureParameter.aperture.displayValue(for: "\(code)/256") ?? "—")\"/>"
            }.joined()
            let xml = """
            <camrply><result>ok</result><menuset><qmenu>
              <menu id="ss"><item id="ss125" cmd_mode="setsetting" cmd_type="shtrspeed" cmd_value="1780/256" title="1/125"/></menu>
              <menu id="f">\(apertures)</menu>
              <menu id="sensitivity"><item id="iso100" cmd_mode="setsetting" cmd_type="iso" cmd_value="100" title="100"/><item id="iso400" cmd_mode="setsetting" cmd_type="iso" cmd_value="400" title="400"/></menu>
            </qmenu></menuset></camrply>
            """
            return try LumixResponse.parseMenu(data: Data(xml.utf8))
        }
        if command == .getInfo("curmenu") {
            return try LumixResponse.parseMenu(data: Data("<camrply><result>ok</result><menuinfo><photosettings><item id=\"ss\" enable=\"yes\"/><item id=\"f\" enable=\"yes\"/><item id=\"sensitivity\" enable=\"yes\"/></photosettings></menuinfo></camrply>".utf8))
        }
        if case .getSetting(let type) = command { return LumixResponse(status: .success, fields: [type: values[type] ?? ""]) }
        if case .setSetting(let type, let value) = command { values[type] = value }
        if case .touchFocus = command { onFocus() }
        if command == .videoStart { recording = true }
        if command == .videoStop { recording = false }
        if command == .playbackMode { playback = true }
        if command == .recordMode { playback = false }
        return LumixResponse(status: .success, fields: ["cammode": playback ? "playmode" : "recmode", "rec": recording ? "on" : "off", "lens": "simulator-lens", "sdcardstatus": "write_enable", "recremaincapacity": "200"])
    }
}

private final class FixtureMediaProtocol: URLProtocol, @unchecked Sendable {
    private static let lock = NSLock()
    private static var stored = Data()
    static var frame: Data { get { lock.withLock { stored } } set { lock.withLock { stored = newValue } } }
    override class func canInit(with request: URLRequest) -> Bool { request.url?.host == "192.168.54.1" }
    override class func canonicalRequest(for request: URLRequest) -> URLRequest { request }
    override func startLoading() {
        let data: Data
        if request.httpMethod == "POST" {
            let xml = """
            <s:Envelope xmlns:s="http://schemas.xmlsoap.org/soap/envelope/"><s:Body><u:BrowseResponse xmlns:u="urn:schemas-upnp-org:service:ContentDirectory:1"><Result><![CDATA[<DIDL-Lite xmlns:dc="http://purl.org/dc/elements/1.1/" xmlns:upnp="urn:schemas-upnp-org:metadata-1-0/upnp/"><item id="sim-photo"><dc:title>SIM-PHOTO.JPG</dc:title><upnp:class>object.item.imageItem.photo</upnp:class><res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_TN">http://192.168.54.1/thumb.JPG</res><res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_ORG">http://192.168.54.1/photo.JPG</res></item><item id="sim-video"><dc:title>SIM-VIDEO.MP4</dc:title><upnp:class>object.item.videoItem</upnp:class><res protocolInfo="http-get:*:image/jpeg:PANASONIC.COM_PN=CAM_LRGTN">http://192.168.54.1/poster.JPG</res></item></DIDL-Lite>]]></Result><NumberReturned>2</NumberReturned><TotalMatches>2</TotalMatches><UpdateID>simulation</UpdateID></u:BrowseResponse></s:Body></s:Envelope>
            """
            data = Data(xml.utf8)
        } else { data = Self.frame }
        let response = HTTPURLResponse(url: request.url!, statusCode: 200, httpVersion: nil, headerFields: ["Content-Length": String(data.count)])!
        client?.urlProtocol(self, didReceive: response, cacheStoragePolicy: .notAllowed)
        client?.urlProtocol(self, didLoad: data)
        client?.urlProtocolDidFinishLoading(self)
    }
    override func stopLoading() {}
}

private final class FixtureReceiver: LiveViewReceiving {
    private let frame: Data
    private let lock = NSLock()
    private var task: Task<Void, Never>?
    private var stopped = false
    init(frame: Data) { self.frame = frame }
    func start(endpoint: CameraEndpoint, onDatagram: @escaping @Sendable (Data) -> Void) async throws {
        try lock.withLock {
            guard !stopped else { throw CancellationError() }
            let frame = self.frame
            task = Task.detached {
                do {
                    try await Task.sleep(nanoseconds: 100_000_000)
                    try Task.checkCancellation()
                    onDatagram(frame)
                } catch { }
            }
        }
    }
    func stop() { lock.withLock { stopped = true; task?.cancel(); task = nil } }
    deinit { task?.cancel() }
}
#endif
