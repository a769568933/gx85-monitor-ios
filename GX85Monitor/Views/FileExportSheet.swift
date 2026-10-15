import SwiftUI
import UIKit

struct FileExportSheet: UIViewControllerRepresentable {
    let urls: [URL]
    let onFinish: @MainActor (Bool) -> Void
    func makeCoordinator() -> Coordinator { Coordinator(onFinish) }
    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }
    func updateUIViewController(_ uiViewController: UIDocumentPickerViewController, context: Context) { }
    static func dismantleUIViewController(_ uiViewController: UIDocumentPickerViewController, coordinator: Coordinator) {
        coordinator.finish(false)
    }
    @MainActor final class Coordinator: NSObject, UIDocumentPickerDelegate {
        private let onFinish: @MainActor (Bool) -> Void
        private var finished = false
        init(_ onFinish: @escaping @MainActor (Bool) -> Void) { self.onFinish = onFinish }
        func finish(_ success: Bool) { guard !finished else { return }; finished = true; onFinish(success) }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { finish(!urls.isEmpty) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { finish(false) }
    }
}
