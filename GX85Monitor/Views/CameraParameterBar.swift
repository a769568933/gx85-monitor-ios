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
            ParameterWheelPanel(session: session, parameter: selected.parameter) { selection = nil }
        }
    }
}

private struct ParameterWheelPanel: View {
    @ObservedObject var session: CameraSession
    let parameter: ExposureParameter
    let close: () -> Void
    @State private var draft: String
    @State private var pending: Task<Void, Never>?

    init(session: CameraSession, parameter: ExposureParameter, close: @escaping () -> Void) {
        self.session = session; self.parameter = parameter; self.close = close
        let options = session.parameterOptions[parameter] ?? []
        let initial = options.first { $0.label == session.parameterValues[parameter] } ?? options.first { $0.enabled }
        _draft = State(initialValue: initial?.rawValue ?? "")
    }
    private var options: [CameraParameterOption] { session.parameterOptions[parameter] ?? [] }
    private var enabled: [CameraParameterOption] { options.filter(\.enabled) }

    var body: some View {
        NavigationStack {
            GeometryReader { geometry in
                VStack(spacing: 8) {
                    if enabled.isEmpty {
                        Spacer()
                        Text("当前参数由机身控制，或镜头未提供可用范围。")
                            .foregroundStyle(.secondary).multilineTextAlignment(.center)
                        Text("请切换至允许调节的模式；M 档可调快门和光圈。")
                            .font(.footnote).foregroundStyle(.secondary)
                        Spacer()
                    } else {
                        Picker(parameter.label, selection: $draft) {
                            ForEach(enabled) { option in
                                Text(option.label)
                                    .font(.system(size: option.rawValue == draft ? 28 : 22, weight: option.rawValue == draft ? .bold : .regular, design: .rounded).monospacedDigit())
                                    .foregroundStyle(option.rawValue == draft ? Color.yellow : Color.white.opacity(0.55))
                                    .tag(option.rawValue)
                            }
                        }
                        .pickerStyle(.wheel).labelsHidden()
                        .frame(height: max(96, min(216, geometry.size.height - 110)))
                        .clipped()
                        .overlay {
                            RoundedRectangle(cornerRadius: 10).stroke(.yellow.opacity(0.7), lineWidth: 1)
                                .frame(height: 40).allowsHitTesting(false)
                        }
                        .accessibilityIdentifier("parameter-wheel")
                        HStack(spacing: 8) {
                            if session.actionInProgress { ProgressView().controlSize(.small) }
                            Text("相机：\(session.parameterValues[parameter] ?? "—")")
                                .font(.callout.monospacedDigit()).foregroundStyle(.white)
                        }
                        Text("滑动停稳后自动应用").font(.caption).foregroundStyle(.secondary)
                        #if DEBUG && targetEnvironment(simulator)
                        if let status = session.fixtureStatus { FixtureParameterWriteBadge(model: status) }
                        #endif
                        if let notice = session.notice {
                            Text(notice).font(.footnote).foregroundStyle(.yellow).lineLimit(3)
                        }
                        Spacer(minLength: 0)
                    }
                }
                .frame(maxWidth: .infinity).padding(.horizontal, 20)
            }
            .navigationTitle(parameter.label).navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("完成", action: close) } }
        }
        .preferredColorScheme(.dark)
        .presentationDetents([.medium, .large])
        .presentationDragIndicator(.visible)
        .onChange(of: draft) { value in applyAfterSettling(value) }
        .onDisappear { pending?.cancel(); pending = nil }
    }

    private func applyAfterSettling(_ value: String) {
        pending?.cancel()
        let connection = session.connectionIdentity
        pending = Task { @MainActor in
            do {
                try await Task.sleep(nanoseconds: 350_000_000)
                // Retain only the latest settled choice while a previous write finishes.
                while session.actionInProgress {
                    guard session.connectionIdentity == connection else { return }
                    try await Task.sleep(nanoseconds: 50_000_000)
                }
                try Task.checkCancellation()
                guard draft == value, session.connectionIdentity == connection, session.canCapture,
                      let option = enabled.first(where: { $0.rawValue == value }) else { return }
                if session.parameterValues[parameter] != option.label {
                    session.updateParameter(parameter, option: option)
                }
            } catch { }
        }
    }
}
