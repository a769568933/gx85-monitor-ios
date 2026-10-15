import SwiftUI
import GX85Core

struct CameraParameterBar: View {
    @ObservedObject var session: CameraSession
    @State private var selection: ParameterSelection?
    private struct ParameterSelection: Identifiable {
        let parameter: ExposureParameter
        var id: String { parameter.rawValue }
    }
    var body: some View {
        HStack(spacing: 8) {
            ForEach(ExposureParameter.allCases, id: \.self) { parameter in
                Button { selection = ParameterSelection(parameter: parameter) } label: {
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
        .sheet(item: $selection) { selected in
            NavigationStack {
                List {
                    let parameter = selected.parameter
                    let options = session.parameterOptions[parameter] ?? []
                    if options.isEmpty {
                        Text("当前模式由机身控制，或镜头未提供可用范围。")
                            .font(.footnote).foregroundStyle(.secondary)
                    } else {
                        if !options.contains(where: { $0.enabled }) {
                            Text("当前模式由机身自动控制。请切换到 M 档；快门也可在 S 档调节。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                        ForEach(options) { option in
                            Button {
                                session.updateParameter(parameter, option: option)
                                selection = nil
                            } label: {
                                HStack {
                                    Text(option.label).font(.body.monospacedDigit())
                                    Spacer(minLength: 16)
                                    if session.parameterValues[parameter] == option.label {
                                        Image(systemName: "checkmark").foregroundStyle(.yellow)
                                    }
                                }
                                .frame(maxWidth: .infinity, minHeight: 48, alignment: .leading)
                                .contentShape(Rectangle())
                            }
                            .buttonStyle(.plain)
                            .disabled(!option.enabled || session.actionInProgress || !session.isActive)
                            .accessibilityLabel(option.label)
                        }
                        if parameter == .shutter {
                            Text("机械快门与电子快门支持的速度范围不同，以机身确认值为准。")
                                .font(.footnote).foregroundStyle(.secondary)
                        }
                    }
                }
                .accessibilityIdentifier("parameter-options")
                .navigationTitle(selected.parameter.label).navigationBarTitleDisplayMode(.inline)
                .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成") { selection = nil } } }
            }
            .preferredColorScheme(.dark)
            .presentationDetents([.medium, .large])
            .presentationDragIndicator(.visible)
        }
    }
}
