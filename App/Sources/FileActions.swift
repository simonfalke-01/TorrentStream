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

extension View {
    /// Presents the system "Save to Files" picker for `item` and confirms when it finishes.
    func exportSheet(_ item: Binding<ExportItem?>) -> some View {
        modifier(ExportSheet(item: item))
    }
}

private struct ExportSheet: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var item: ExportItem?

    func body(content: Content) -> some View {
        content.sheet(item: $item) { e in
            DocumentExporter(urls: e.urls) { ok in
                if ok { model.showToast(e.urls.count == 1 ? "Saved to Files" : "Saved \(e.urls.count) files to Files", systemImage: "folder") }
            }
            .ignoresSafeArea()
        }
    }
}

/// Per-file actions shared by the torrent screen, Downloads, and the player.
/// Finished files offer save and share; unfinished ones offer download or stop.
struct FileActionsMenu: View {
    @EnvironmentObject var model: AppModel
    let torrent: Torrent
    let status: FileStatus
    @Binding var export: ExportItem?
    /// Shows Play and Open in VLC when set.
    var onPlay: (() -> Void)?
    /// Inside the player the file is always being fetched, so only an explicit download can be stopped.
    var inPlayer = false

    private var file: TorrentFile { status.file }

    var body: some View {
        if let onPlay {
            Section {
                Button(action: onPlay) { Label("Play", systemImage: "play") }
                Button { openInVLC() } label: { Label("Open in VLC", systemImage: "arrow.up.forward.app") }
            }
        }
        if status.isComplete, let url = model.localURL(torrent, file) {
            Section {
                Button { export = ExportItem(urls: [url]) } label: { Label("Save to Files", systemImage: "folder") }
                if PhotoSaver.canSave(file) {
                    Button { model.saveToPhotos(torrent, file) } label: { Label("Save to Photos", systemImage: "photo") }
                }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        } else {
            Section {
                if inPlayer ? model.isOfflineDownload(torrent, fileIndex: file.index) : status.isDownloading {
                    Button { model.stopDownloading(torrent, fileIndex: file.index) } label: {
                        Label("Stop Download", systemImage: "stop.circle")
                    }
                } else {
                    Button { model.download(torrent, fileIndex: file.index) } label: {
                        Label("Download", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        if file.kind.isPlayable {
            Button { model.copyStreamLink(torrent, file) } label: { Label("Copy Stream Link", systemImage: "link") }
        }
    }

    private func openInVLC() {
        let request = model.playbackRequest(torrent: torrent, file: file)
        ExternalPlayer.openInVLC(request) { model.errorMessage = $0 }
    }
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
