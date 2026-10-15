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
        guard let all = cached else { throw ResponseError.malformed }
        let current: CameraCapabilities
        var warnings = all.diagnostics
        do {
            let reply = try await controls.sendExclusive(.getInfo("curmenu"))
            try Task.checkCancellation()
            current = try all.applyingCurrentMenu(data: reply.body)
        } catch {
            try Task.checkCancellation()
            current = all.disablingOptions(reason: "当前模式未报告可调参数。")
            warnings.append("当前参数菜单：\(error.localizedDescription)")
        }
        var values: [ExposureParameter: String] = [:]
        for parameter in ExposureParameter.allCases {
            do {
                let reply = try await controls.sendExclusive(.getSetting(parameter.commandType))
                try Task.checkCancellation()
                if let raw = reply.fields[parameter.commandType] ?? reply.fields["value"], !raw.isEmpty {
                    values[parameter] = all.options(for: parameter).first(where: { $0.rawValue == raw })?.label ?? String(raw.prefix(32))
                }
            } catch {
                try Task.checkCancellation()
                warnings.append("\(parameter.label)：\(error.localizedDescription)")
            }
        }
        return CameraParameterSnapshot(options: Dictionary(uniqueKeysWithValues: ExposureParameter.allCases.map { ($0, current.options(for: $0)) }), values: values, warnings: warnings)
    }
}
