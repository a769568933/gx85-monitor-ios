import SwiftUI
import GX85Core

struct CameraParameterBar: View {
    @ObservedObject var session: CameraSession
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ExposureParameter.allCases, id: \.self) { parameter in
                Menu {
                    let options = session.parameterOptions[parameter] ?? []
                    if options.isEmpty { Text("由机身控制或未提供调节范围") }
                    else if !options.contains(where: { $0.enabled }) { Text("当前模式由相机控制") }
                    ForEach(options) { option in
                        Button(option.label) { session.updateParameter(parameter, option: option) }
                            .disabled(!option.enabled)
                    }
                } label: {
                    VStack(spacing: 2) {
                        Text(parameter.label).font(.caption2).foregroundStyle(.white.opacity(0.7))
                        Text(session.parameterValues[parameter] ?? "—").font(.caption.monospacedDigit().weight(.medium))
                            .lineLimit(1).minimumScaleFactor(0.7)
                    }
                    .foregroundStyle(.white).frame(maxWidth: .infinity, minHeight: 44)
                    .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 10))
                }
                .disabled(!session.isActive || session.actionInProgress)
                .accessibilityIdentifier("parameter-\(parameter.rawValue)")
                .accessibilityLabel("\(parameter.label)，\(session.parameterValues[parameter] ?? "未读取")")
            }
        }
    }
}
