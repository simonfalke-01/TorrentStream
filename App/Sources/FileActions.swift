import SwiftUI
import UIKit
import Photos
import TorrentKit

/// "Save to Files": exports copies of downloaded files through the system document picker.
struct DocumentExporter: UIViewControllerRepresentable {
    let urls: [URL]
    var onComplete: (Bool) -> Void = { _ in }

    func makeCoordinator() -> Coordinator { Coordinator(onComplete: onComplete) }

    func makeUIViewController(context: Context) -> UIDocumentPickerViewController {
        let picker = UIDocumentPickerViewController(forExporting: urls, asCopy: true)
        picker.delegate = context.coordinator
        return picker
    }

    func updateUIViewController(_ vc: UIDocumentPickerViewController, context: Context) {}

    final class Coordinator: NSObject, UIDocumentPickerDelegate {
        let onComplete: (Bool) -> Void
        init(onComplete: @escaping (Bool) -> Void) { self.onComplete = onComplete }
        func documentPicker(_ controller: UIDocumentPickerViewController, didPickDocumentsAt urls: [URL]) { onComplete(true) }
        func documentPickerWasCancelled(_ controller: UIDocumentPickerViewController) { onComplete(false) }
    }
}

/// Files waiting to be exported; drives the `.sheet(item:)` that shows `DocumentExporter`.
struct ExportItem: Identifiable {
    let id = UUID()
    let urls: [URL]
}

enum PhotoSaver {
    enum SaveError: LocalizedError {
        case denied, incompatible
        var errorDescription: String? {
            switch self {
            case .denied: return "TorrentStream isn't allowed to add to your photo library. Enable it in Settings › Privacy › Photos."
            case .incompatible: return "Photos can't import this video format. Use Save to Files instead."
            }
        }
    }

    static func canSave(_ file: TorrentFile) -> Bool {
        ["mp4", "m4v", "mov"].contains(file.fileExtension)
    }

    static func save(_ url: URL) async throws {
        let status = await PHPhotoLibrary.requestAuthorization(for: .addOnly)
        guard status == .authorized || status == .limited else { throw SaveError.denied }
        guard UIVideoAtPathIsCompatibleWithSavedPhotosAlbum(url.path) else { throw SaveError.incompatible }
        try await PHPhotoLibrary.shared().performChanges {
            _ = PHAssetChangeRequest.creationRequestForAssetFromVideo(atFileURL: url)
        }
    }
}
