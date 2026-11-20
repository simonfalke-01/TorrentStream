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
                        ToolbarItem(placement: .primaryAction) {
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
        .exportSheet($export)
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
            }

            if status.phase == .fetchingMetadata {
                Section {
                    HStack(spacing: Space.m) {
                        ProgressView()
                        VStack(alignment: .leading, spacing: Space.xxs) {
                            Text("Fetching file list")
                            Text(status.connectedPeers > 0
                                 ? "Connected to \(Format.peers(status.connectedPeers))"
                                 : "Looking for peers")
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    .accessibilityElement(children: .combine)
                }
            }

            if !media.isEmpty {
                Section(sectionTitle(media)) {
                    ForEach(media) { fs in mediaRow(fs, item: item) }
                }
            }
            if !subs.isEmpty {
                Section {
                    ForEach(subs) { fs in fileRow(fs, item: item) }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("Available in the player’s subtitle menu.")
                }
            }
            if !other.isEmpty {
                Section("Other Files") {
                    ForEach(showAllOther ? other : Array(other.prefix(4))) { fs in fileRow(fs, item: item) }
                    if other.count > 4 && !showAllOther {
                        Button("Show All \(other.count)") { showAllOther = true }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sectionTitle(_ media: [FileStatus]) -> String {
        let hasAudio = media.contains { $0.file.kind == .audio }
        let hasVideo = media.contains { $0.file.kind == .video }
        if hasAudio && hasVideo { return "Media" }
        if hasAudio { return media.count == 1 ? "Audio" : "Tracks" }
        return media.count == 1 ? "Video" : "Videos"
    }

    private func header(_ item: LibraryItem) -> some View {
        let s = item.status
        let main = model.mainPlayable(s)
        return VStack(alignment: .leading, spacing: Space.l) {
            HStack(alignment: .top, spacing: Space.l) {
                ArtworkView(url: model.artworkURL(item), symbol: "film", cornerRadius: Radius.medium)
                    .frame(width: Metrics.headerArtwork.width, height: Metrics.headerArtwork.height)
                VStack(alignment: .leading, spacing: Space.xs) {
                    Text(s.name)
                        .font(.title3.weight(.bold))
                        .lineLimit(4)
                        .accessibilityAddTraits(.isHeader)
                    if s.phase == .ready {
                        Text(s.sizeText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let activity = s.activityText {
                            Text(activity)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .monospacedDigit()
                        }
                    }
                    if case .failed(let message) = s.phase {
                        Label(message, systemImage: "exclamationmark.triangle.fill")
                            .font(.subheadline)
                            .foregroundStyle(.red)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }

            if s.showsProgress {
                ProgressView(value: s.progress)
                    .tint(s.isPaused ? .secondary : .accentColor)
                    .accessibilityLabel("Download progress")
                    .accessibilityValue(Format.percent(s.progress))
            }

            if let main {
                let resume = model.savedPosition(torrent: item.torrent, file: main.file)
                HStack(spacing: Space.m) {
                    Button { play(main.file, item: item) } label: {
                        Label(resume != nil ? "Resume" : "Play", systemImage: "play.fill")
                            .frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.borderedProminent)
                    Button { openInVLC(main.file, item: item) } label: {
                        Label("VLC", systemImage: "arrow.up.forward.app")
                    }
                    .buttonStyle(.bordered)
                    .accessibilityLabel("Open in VLC")
                }
                .controlSize(.large)
                .font(.body.weight(.semibold))
            }
        }
        .padding(.vertical, Space.s)
    }

    // MARK: rows

    private func mediaRow(_ fs: FileStatus, item: LibraryItem) -> some View {
        let watched = model.watchedFraction(torrent: item.torrent, file: fs.file)
        return HStack(spacing: Space.s) {
            Button { play(fs.file, item: item) } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: fs.file.kind == .audio ? "music.note" : "play.rectangle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: Metrics.rowIcon)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(fs.file.fileName)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(fs.detailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let watched {
                            ProgressView(value: watched)
                                .tint(.secondary)
                                .frame(maxWidth: Metrics.watchedBar)
                        }
                    }
                    Spacer(minLength: Space.s)
                    FileStateIndicator(status: fs, paused: item.status.isPaused)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(fs.file.fileName)
            .accessibilityValue(rowAccessibilityValue(fs, watched: watched))
            .accessibilityHint("Plays the file")

            rowMenu(fs, item: item, playable: true)
        }
        .contextMenu {
            FileActionsMenu(torrent: item.torrent, status: fs, export: $export, onPlay: { play(fs.file, item: item) })
        }
    }

    private func fileRow(_ fs: FileStatus, item: LibraryItem) -> some View {
        HStack(spacing: Space.m) {
            Image(systemName: fs.file.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(fs.file.fileName).lineLimit(2)
                Text(fs.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(fs.accessibilityState)
            Spacer(minLength: Space.s)
            FileStateIndicator(status: fs, paused: item.status.isPaused)
            rowMenu(fs, item: item, playable: false)
        }
        .contextMenu {
            FileActionsMenu(torrent: item.torrent, status: fs, export: $export)
        }
    }

    private func rowMenu(_ fs: FileStatus, item: LibraryItem, playable: Bool) -> some View {
        Menu {
            FileActionsMenu(torrent: item.torrent, status: fs, export: $export,
                            onPlay: playable ? { play(fs.file, item: item) } : nil)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Actions for \(fs.file.fileName)")
    }

    private func rowAccessibilityValue(_ fs: FileStatus, watched: Double?) -> String {
        var parts = [fs.detailText, fs.accessibilityState]
        if let watched { parts.append("Watched \(Format.percent(watched))") }
        return parts.joined(separator: ", ")
    }

    // MARK: actions

    private func play(_ file: TorrentFile, item: LibraryItem) {
        playing = model.playbackRequest(torrent: item.torrent, file: file)
    }

    private func openInVLC(_ file: TorrentFile, item: LibraryItem) {
        let req = model.playbackRequest(torrent: item.torrent, file: file)
        ExternalPlayer.openInVLC(req) { model.errorMessage = $0 }
    }
}
