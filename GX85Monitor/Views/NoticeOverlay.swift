import SwiftUI

struct NoticeOverlay: View {
    let message: String
    let onDismiss: () -> Void
    @State private var expanded = false

    var body: some View {
        HStack(alignment: .top, spacing: 4) {
            Button { expanded.toggle() } label: {
                VStack(alignment: .leading, spacing: 3) {
                    Text(message).font(.footnote).lineLimit(expanded ? nil : 3)
                        .fixedSize(horizontal: false, vertical: true)
                    if !expanded { Text("点按展开").font(.caption2).foregroundStyle(.white.opacity(0.7)) }
                }
                .foregroundStyle(.yellow).frame(maxWidth: .infinity, alignment: .leading)
                .padding(12)
            }
            .buttonStyle(.plain)
            Button(action: onDismiss) {
                Image(systemName: "xmark").frame(width: 44, height: 44).contentShape(Rectangle())
            }
            .buttonStyle(.plain).foregroundStyle(.white).accessibilityLabel("关闭提示")
        }
        .background(.black.opacity(0.85), in: RoundedRectangle(cornerRadius: 14))
        .accessibilityIdentifier("cameraNotice")
        .task(id: message) {
            expanded = false
            do { try await Task.sleep(nanoseconds: 6_000_000_000) } catch { return }
            guard !Task.isCancelled, !expanded else { return }
            onDismiss()
        }
    }
}
