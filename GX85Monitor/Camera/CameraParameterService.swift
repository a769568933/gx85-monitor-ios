import Foundation
import GX85Core

struct CameraParameterSnapshot: Sendable {
    let options: [ExposureParameter: [CameraParameterOption]]
    let values: [ExposureParameter: String]
    let warnings: [String]
}

actor CameraParameterService {
    private let controls: CameraControlService
    private var cached: CameraCapabilities?
    private var lens: String?
    init(controls: CameraControlService) { self.controls = controls }

    func load(lens: String?, refreshAll: Bool = false) async throws -> CameraParameterSnapshot {
        if cached == nil || self.lens != lens || refreshAll {
            let reply = try await controls.sendExclusive(.getInfo("allmenu"))
            try Task.checkCancellation()
            cached = try CameraCapabilities.parse(data: reply.body)
            self.lens = lens
        }
        guard var all = cached else { throw ResponseError.malformed }
        var lensWarnings: [String] = []
        if all.requiresLensApertureLimits {
            do {
                let lensReply = try await controls.sendExclusive(.getInfo("lens"))
                try Task.checkCancellation()
                all = try all.withLensApertureLimits(data: lensReply.body)
            } catch {
                try Task.checkCancellation()
                lensWarnings.append("镜头光圈范围未确认：\(error.localizedDescription)")
            }
        }
        let current: CameraCapabilities
        var warnings = lensWarnings
        do {
            let reply = try await controls.sendExclusive(.getInfo("curmenu"))
            try Task.checkCancellation()
            current = try all.applyingCurrentMenu(data: reply.body)
        } catch {
            try Task.checkCancellation()
            current = all.disablingOptions(reason: "当前模式未报告可调参数。")
            warnings.append("当前参数菜单：\(error.localizedDescription)")
        }
        warnings += current.diagnostics
        var values: [ExposureParameter: String] = [:]
        for parameter in ExposureParameter.allCases {
            do {
                let reply = try await controls.sendExclusive(.getSetting(parameter.commandType))
                try Task.checkCancellation()
                if let raw = reply.fields[parameter.commandType] ?? reply.fields["value"], !raw.isEmpty {
                    if parameter != .iso, current.manualControlAllowed(for: parameter) == false {
                        values[parameter] = "自动"
                        warnings.append("\(parameter.label)由机身自动控制；不将保留的手动设置 \(raw.prefix(64)) 当作实时曝光。")
                    } else {
                        values[parameter] = all.options(for: parameter).first(where: { $0.rawValue == raw })?.label ?? parameter.displayValue(for: raw) ?? "—"
                    }
                    if values[parameter] == "—" { warnings.append("无法换算\(parameter.label)返回值：\(String(raw.prefix(64)))") }
                }
            } catch {
                try Task.checkCancellation()
                warnings.append("\(parameter.label)：\(error.localizedDescription)")
            }
        }
        return CameraParameterSnapshot(options: Dictionary(uniqueKeysWithValues: ExposureParameter.allCases.map { ($0, current.options(for: $0)) }), values: values, warnings: warnings)
    }
}
