import Foundation
import Combine

@MainActor
final class DiagnosticsLog: ObservableObject {
    @Published private(set) var entries: [String] = []
    func append(_ message: String) {
        let time = Date().formatted(date: .omitted, time: .standard)
        entries.append("[\(time)] \(String(message.prefix(512)))")
        if entries.count > 200 { entries.removeFirst(entries.count - 200) }
    }
    var text: String { "GX85 Monitor 诊断记录\n" + entries.joined(separator: "\n") }
}
