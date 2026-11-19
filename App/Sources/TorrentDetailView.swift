import SwiftUI
import TorrentKit

struct TorrentDetailView: View {
    let infoHash: String
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var showAllFiles = false

    var body: some View {
        Group {
            if let item = model.item(infoHash) {
                content(item)
            } else {
                Text("Torrent removed").foregroundStyle(.secondary)
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
    }

    @ViewBuilder
    private func content(_ item: LibraryItem) -> some View {
        let status = item.status
        let visible = status.files.filter { !$0.file.isPadding }
        let media = visible.filter { MediaKind(fileExtension: $0.file.fileExtension).isPlayable }
        let subs = visible.filter { MediaKind(fileExtension: $0.file.fileExtension) == .subtitle }
        let other = visible.filter { MediaKind(fileExtension: $0.file.fileExtension) == .other }

        List {
            Section {
                VStack(alignment: .leading, spacing: 8) {
                    Text(status.name).font(.headline)
                    switch status.phase {
                    case .fetchingMetadata:
                        HStack(spacing: 8) {
                            ProgressView()
                            Text("Getting the file list from peers…")
                        }
                        Text("\(status.connectedPeers) connected · \(status.knownPeers) found · metadata \(Int(status.metadataProgress * 100))%")
                            .font(.caption).foregroundStyle(.secondary)
                    case .failed(let msg):
                        Label(msg, systemImage: "exclamationmark.triangle").foregroundStyle(.red)
                    case .ready:
                        ProgressView(value: status.progress)
                        HStack {
                            Text("\(Format.bytes(status.downloadedBytes)) / \(Format.bytes(status.totalLength))")
                            Spacer()
                            Label("\(status.connectedPeers)", systemImage: "person.2")
                            Label(Format.rate(status.downloadRate), systemImage: "arrow.down")
                        }
                        .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    }
                }
            }

            if !media.isEmpty {
                Section("Play") {
                    ForEach(media) { fs in fileRow(fs, item: item, playable: true) }
                }
            }
            if !subs.isEmpty {
                Section {
                    ForEach(subs) { fs in fileRow(fs, item: item, playable: false) }
                } header: { Text("Subtitles") } footer: {
                    Text("Subtitle files from this torrent are loaded automatically and can be picked from the player's subtitle menu.")
                }
            }
            if !other.isEmpty {
                Section {
                    if showAllFiles || other.count <= 5 {
                        ForEach(other) { fs in fileRow(fs, item: item, playable: false) }
                    } else {
                        Button("Show \(other.count) other files") { showAllFiles = true }
                    }
                } header: { Text("Other files") }
            }
        }
    }

    private func fileRow(_ fs: FileStatus, item: LibraryItem, playable: Bool) -> some View {
        let kind = MediaKind(fileExtension: fs.file.fileExtension)
        return HStack(spacing: 12) {
            Image(systemName: icon(kind)).font(.title3).foregroundStyle(playable ? Color.accentColor : .secondary).frame(width: 28)
            VStack(alignment: .leading, spacing: 4) {
                Text(fs.file.fileName).lineLimit(2)
                if fs.file.path.count > 1 {
                    Text(fs.file.path.dropLast().joined(separator: "/")).font(.caption2).foregroundStyle(.secondary).lineLimit(1)
                }
                HStack(spacing: 6) {
                    Text(Format.bytes(fs.file.length))
                    if fs.downloadedBytes > 0 { Text("· \(Int(fs.progress * 100))%") }
                    if fs.wanted && fs.progress < 1 { Image(systemName: "arrow.down.circle").foregroundStyle(.tint) }
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                if fs.downloadedBytes > 0 && fs.progress < 1 { ProgressView(value: fs.progress).tint(.green) }
            }
            Spacer()
            Menu {
                if playable {
                    Button { play(fs.file, item: item) } label: { Label("Play", systemImage: "play.fill") }
                    Button { openInVLC(fs.file, item: item) } label: { Label("Open in VLC", systemImage: "arrow.up.forward.app") }
                }
                Button {
                    UIPasteboard.general.url = model.client.streamURL(for: item.torrent, fileIndex: fs.file.index, fileName: fs.file.fileName)
                } label: { Label("Copy Stream Link", systemImage: "link") }
                if fs.wanted {
                    Button { model.setWanted(false, torrent: item.torrent, fileIndex: fs.file.index) } label: {
                        Label("Stop Downloading", systemImage: "stop.circle")
                    }
                } else {
                    Button { model.setWanted(true, torrent: item.torrent, fileIndex: fs.file.index) } label: {
                        Label("Download Fully", systemImage: "arrow.down.circle")
                    }
                }
            } label: {
                Image(systemName: "ellipsis.circle").font(.title3)
            }
            if playable {
                Button { openInVLC(fs.file, item: item) } label: {
                    Image(systemName: "arrow.up.forward.app").font(.title3)
                }
                .buttonStyle(.borderless)
                .accessibilityLabel("Open in VLC")
            }
        }
        .contentShape(Rectangle())
        .onTapGesture { if playable { play(fs.file, item: item) } }
    }

    private func icon(_ kind: MediaKind) -> String {
        switch kind {
        case .video: return "play.rectangle.fill"
        case .audio: return "music.note"
        case .subtitle: return "captions.bubble"
        case .other: return "doc"
        }
    }

    private func play(_ file: TorrentFile, item: LibraryItem) {
        playing = model.playbackRequest(torrent: item.torrent, file: file)
    }

    private func openInVLC(_ file: TorrentFile, item: LibraryItem) {
        let req = model.playbackRequest(torrent: item.torrent, file: file)
        ExternalPlayer.openInVLC(req) { error in model.errorMessage = error }
    }
}
