import SwiftUI
import TorrentKit

struct TorrentDetailView: View {
    let infoHash: String
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var showAllOther = false
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?

    var body: some View {
        Group {
            if let item = model.item(infoHash) {
                content(item)
                    .toolbar {
                        ToolbarItem(placement: .topBarTrailing) {
                            Menu {
                                TorrentActionsMenu(item: item, onRemove: { pendingRemoval = item })
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
            } else {
                ContentUnavailableView("Torrent Removed", systemImage: "trash")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
        .sheet(item: $export) { e in DocumentExporter(urls: e.urls) { ok in if ok { model.showToast("Saved to Files") } }.ignoresSafeArea() }
        .removeTorrentDialog(item: $pendingRemoval, export: $export)
    }

    // MARK: layout

    @ViewBuilder
    private func content(_ item: LibraryItem) -> some View {
        let status = item.status
        let visible = status.files.filter { !$0.file.isPadding }
        let media = visible.filter { $0.file.kind.isPlayable }
            .sorted { $0.file.displayPath.localizedStandardCompare($1.file.displayPath) == .orderedAscending }
        let subs = visible.filter { $0.file.kind == .subtitle }
        let other = visible.filter { $0.file.kind == .other && !$0.file.isImage }

        List {
            Section {
                header(item)
                    .listRowBackground(Color.clear)
                    .listRowInsets(EdgeInsets())
            }

            if status.phase == .fetchingMetadata {
                Section {
                    HStack(spacing: 14) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: 2) {
                            Text("Getting the file list from peers…").font(.subheadline)
                            Text("\(status.connectedPeers) connected · \(status.knownPeers) found")
                                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
                        }
                    }
                    .padding(.vertical, 6)
                }
            }

            if !media.isEmpty {
                Section(media.count == 1 ? "Video" : "Videos & Audio") {
                    ForEach(media) { fs in mediaRow(fs, item: item) }
                }
            }
            if !subs.isEmpty {
                Section {
                    ForEach(subs) { fs in plainRow(fs, item: item) }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("Loaded automatically when you play a video. Choose them from the player's subtitle menu.")
                }
            }
            if !other.isEmpty {
                Section("Other Files") {
                    ForEach(showAllOther ? other : Array(other.prefix(4))) { fs in plainRow(fs, item: item) }
                    if other.count > 4 && !showAllOther {
                        Button("Show All \(other.count) Files") { withAnimation { showAllOther = true } }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func header(_ item: LibraryItem) -> some View {
        let s = item.status
        let main = model.mainPlayable(s)
        return VStack(spacing: 16) {
            HStack(alignment: .top, spacing: 16) {
                ArtworkView(hash: item.id, url: model.artworkURL(item), symbol: "film.stack", cornerRadius: 14)
                    .frame(width: 96, height: 136)
                    .shadow(color: .black.opacity(0.2), radius: 10, y: 6)
                VStack(alignment: .leading, spacing: 8) {
                    Text(s.name).font(.title3.weight(.bold)).lineLimit(4)
                    if s.phase == .ready {
                        Text(summary(s)).font(.subheadline).foregroundStyle(.secondary).monospacedDigit()
                    }
                    if case .failed(let msg) = s.phase {
                        Label(msg, systemImage: "exclamationmark.triangle.fill").font(.caption).foregroundStyle(.red)
                    }
                }
                Spacer(minLength: 0)
            }

            if s.phase == .ready {
                GlassEffectContainer(spacing: 10) {
                    HStack(spacing: 10) {
                        StatChip(systemImage: "person.2.fill", text: "\(s.connectedPeers)")
                        StatChip(systemImage: "arrow.down", text: s.isPaused ? "Paused" : Format.rate(s.downloadRate))
                        StatChip(systemImage: s.isComplete ? "checkmark.circle.fill" : "internaldrive",
                                 text: s.isComplete ? "Complete" : "\(Int(s.progress * 100))%")
                        Spacer(minLength: 0)
                    }
                }
            }

            if let main {
                let resume = model.savedPosition(torrent: item.torrent, file: main.file)
                GlassEffectContainer(spacing: 12) {
                    HStack(spacing: 12) {
                        Button { play(main.file, item: item) } label: {
                            Label(resume != nil ? "Resume" : "Play", systemImage: "play.fill")
                                .font(.headline)
                                .frame(maxWidth: .infinity)
                                .padding(.vertical, 6)
                        }
                        .buttonStyle(.glassProminent)
                        Button { openInVLC(main.file, item: item) } label: {
                            Label("VLC", systemImage: "arrow.up.forward.app")
                                .font(.headline)
                                .padding(.vertical, 6)
                                .padding(.horizontal, 6)
                        }
                        .buttonStyle(.glass)
                    }
                }
                .controlSize(.large)
            }
        }
        .padding(.vertical, 8)
    }

    private func summary(_ s: TorrentStatus) -> String {
        if s.isComplete { return "\(Format.bytes(s.totalLength)) · Downloaded" }
        var parts = ["\(Format.bytes(s.downloadedBytes)) of \(Format.bytes(s.totalLength))"]
        if s.hasActiveDownloads && !s.isPaused {
            let remaining = s.files.filter { $0.isDownloading }.reduce(Int64(0)) { $0 + $1.file.length - $1.downloadedBytes }
            if let eta = Format.eta(remaining: remaining, rate: s.downloadRate) { parts.append(eta) }
        }
        return parts.joined(separator: " · ")
    }

    // MARK: rows

    private func mediaRow(_ fs: FileStatus, item: LibraryItem) -> some View {
        let watched = model.watchedFraction(torrent: item.torrent, file: fs.file)
        return Button { play(fs.file, item: item) } label: {
            HStack(spacing: 14) {
                ZStack {
                    RoundedRectangle(cornerRadius: 10, style: .continuous).fill(torrentTint(for: item.id).gradient)
                    Image(systemName: fs.file.kind == .audio ? "music.note" : "play.fill")
                        .font(.headline).foregroundStyle(.white)
                }
                .frame(width: 44, height: 44)
                VStack(alignment: .leading, spacing: 4) {
                    Text(fs.file.fileName).font(.body).foregroundStyle(.primary).lineLimit(2)
                    Text(fs.stateText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
                    if let watched {
                        ProgressView(value: watched).tint(.orange).frame(maxWidth: 140)
                    }
                }
                Spacer(minLength: 8)
                FileStateIndicator(status: fs)
                fileMenu(fs, item: item, playable: true)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
        .contextMenu { fileMenuItems(fs, item: item, playable: true) }
    }

    private func plainRow(_ fs: FileStatus, item: LibraryItem) -> some View {
        HStack(spacing: 14) {
            Image(systemName: fs.file.kind.symbol)
                .font(.title3).foregroundStyle(.secondary).frame(width: 44)
            VStack(alignment: .leading, spacing: 4) {
                Text(fs.file.fileName).lineLimit(2)
                Text(fs.stateText).font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer(minLength: 8)
            FileStateIndicator(status: fs)
            fileMenu(fs, item: item, playable: false)
        }
        .contextMenu { fileMenuItems(fs, item: item, playable: false) }
    }

    private func fileMenu(_ fs: FileStatus, item: LibraryItem, playable: Bool) -> some View {
        Menu {
            fileMenuItems(fs, item: item, playable: playable)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: 32, height: 32)
                .contentShape(Rectangle())
        }
        .buttonStyle(.glass)
        .buttonBorderShape(.circle)
        .accessibilityLabel("Actions for \(fs.file.fileName)")
    }

    /// Actions depend on the file's state: finished files can be saved/shared, unfinished ones downloaded or stopped.
    @ViewBuilder
    private func fileMenuItems(_ fs: FileStatus, item: LibraryItem, playable: Bool) -> some View {
        if playable {
            Section {
                Button { play(fs.file, item: item) } label: { Label("Play", systemImage: "play.fill") }
                Button { openInVLC(fs.file, item: item) } label: { Label("Open in VLC", systemImage: "arrow.up.forward.app") }
            }
        }
        if fs.isComplete, let url = model.localURL(item.torrent, fs.file) {
            Section {
                Button { export = ExportItem(urls: [url]) } label: { Label("Save to Files", systemImage: "folder") }
                if PhotoSaver.canSave(fs.file) {
                    Button { model.saveToPhotos(item.torrent, fs.file) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                }
                ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
            }
        } else {
            Section {
                if fs.isDownloading {
                    Button { model.stopDownloading(item.torrent, fileIndex: fs.file.index) } label: {
                        Label("Stop Downloading", systemImage: "stop.circle")
                    }
                } else {
                    Button { model.download(item.torrent, fileIndex: fs.file.index) } label: {
                        Label("Download for Offline", systemImage: "arrow.down.circle")
                    }
                }
            }
        }
        if playable {
            Button { model.copyStreamLink(item.torrent, fs.file) } label: { Label("Copy Stream Link", systemImage: "link") }
        }
    }

    // MARK: actions

    private func play(_ file: TorrentFile, item: LibraryItem) {
        playing = model.playbackRequest(torrent: item.torrent, file: file)
    }

    private func openInVLC(_ file: TorrentFile, item: LibraryItem) {
        let req = model.playbackRequest(torrent: item.torrent, file: file)
        ExternalPlayer.openInVLC(req) { error in model.errorMessage = error }
    }
}
