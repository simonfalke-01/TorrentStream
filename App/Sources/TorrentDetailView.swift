import SwiftUI
import TorrentKit

extension View {
    /// Destinations for `Route`, registered once per navigation stack.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .torrent(let hash): TorrentDetailView(infoHash: hash)
            case .folder(let hash, let folder): FolderView(infoHash: hash, folderID: folder)
            case .nyaa(let result): NyaaResultView(result: result)
            }
        }
    }
}

/// The playable part of a torrent as a folder hierarchy.
private func mediaTree(_ status: TorrentStatus) -> FileFolder {
    FileTree.build(status.files.map(\.file)) { $0.kind.isPlayable }
}

private func statusIndex(_ status: TorrentStatus) -> [Int: FileStatus] {
    Dictionary(status.files.map { ($0.file.index, $0) }, uniquingKeysWith: { a, _ in a })
}

// MARK: - Torrent screen

struct TorrentDetailView: View {
    let infoHash: String
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var showAllSubtitles = false
    @State private var showAllOther = false
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?

    private let collapsedCount = 4

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

    @ViewBuilder
    private func content(_ item: LibraryItem) -> some View {
        let status = item.status
        let tree = mediaTree(status)
        let statuses = statusIndex(status)
        let visible = status.files.filter { !$0.file.isPadding }
            .sorted { FileTree.naturalOrder($0.file.displayPath, $1.file.displayPath) }
        let subtitles = visible.filter { $0.file.kind == .subtitle }
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

            if !tree.allFiles.isEmpty {
                Section(sectionTitle(tree.allFiles)) {
                    MediaFolderRows(item: item, folder: tree, statuses: statuses, export: $export, onPlay: { play($0, item: item) })
                }
            }
            if !subtitles.isEmpty {
                Section {
                    ForEach(showAllSubtitles ? subtitles : Array(subtitles.prefix(collapsedCount))) { fs in
                        PlainFileRow(item: item, status: fs, export: $export)
                    }
                    if subtitles.count > collapsedCount && !showAllSubtitles {
                        Button("Show All \(subtitles.count)") { showAllSubtitles = true }
                    }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text("Available in the player’s subtitle menu.")
                }
            }
            if !other.isEmpty {
                Section("Other Files") {
                    ForEach(showAllOther ? other : Array(other.prefix(collapsedCount))) { fs in
                        PlainFileRow(item: item, status: fs, export: $export)
                    }
                    if other.count > collapsedCount && !showAllOther {
                        Button("Show All \(other.count)") { showAllOther = true }
                    }
                }
            }
        }
        .listStyle(.insetGrouped)
    }

    private func sectionTitle(_ media: [TorrentFile]) -> String {
        let hasAudio = media.contains { $0.kind == .audio }
        let hasVideo = media.contains { $0.kind == .video }
        if hasAudio && hasVideo { return "Media" }
        if hasAudio { return media.count == 1 ? "Audio" : "Tracks" }
        return media.count == 1 ? "Video" : "Videos"
    }

    // MARK: header

    private func header(_ item: LibraryItem) -> some View {
        let s = item.status
        let next = model.upNext(item)
        let isSeries = model.playlist(s).count > 1
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

            if let next {
                VStack(alignment: .leading, spacing: Space.s) {
                    HStack(spacing: Space.m) {
                        Button { play(next.file, item: item) } label: {
                            Label(next.resumeAt != nil ? "Resume" : "Play", systemImage: "play.fill")
                                .frame(maxWidth: .infinity)
                        }
                        .buttonStyle(.borderedProminent)
                        .accessibilityHint(isSeries ? next.file.title : "")
                        Button { openInVLC(next.file, item: item) } label: {
                            Label("VLC", systemImage: "arrow.up.forward.app")
                        }
                        .buttonStyle(.bordered)
                        .accessibilityLabel("Open in VLC")
                    }
                    .controlSize(.large)
                    .font(.body.weight(.semibold))

                    if isSeries {
                        Text(upNextCaption(next))
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .lineLimit(1)
                            .truncationMode(.middle)
                            .accessibilityHidden(true)
                    }
                }
            }
        }
        .padding(.vertical, Space.s)
    }

    /// Names the episode the Play button starts when the torrent has several.
    private func upNextCaption(_ next: UpNext) -> String {
        if let remaining = next.remaining, let left = Format.duration(remaining) {
            return "\(next.file.title), \(left) left"
        }
        return next.file.title
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

// MARK: - Folder screen

/// One folder of a torrent with several folders of videos (seasons, specials, extras).
struct FolderView: View {
    let infoHash: String
    let folderID: String
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var export: ExportItem?

    var body: some View {
        Group {
            if let item = model.item(infoHash), let folder = mediaTree(item.status).folder(id: folderID) {
                List {
                    Section {
                        MediaFolderRows(item: item, folder: folder, statuses: statusIndex(item.status), export: $export) { file in
                            playing = model.playbackRequest(torrent: item.torrent, file: file)
                        }
                    } header: {
                        Text(Format.videos(folder.allFiles.count).capitalized)
                    }
                }
                .listStyle(.insetGrouped)
                .navigationTitle(folder.name)
                .toolbar {
                    if FolderActionsMenu.hasActions(folder: folder, statuses: statusIndex(item.status)) {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                FolderActionsMenu(item: item, folder: folder, statuses: statusIndex(item.status))
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
                }
            } else {
                ContentUnavailableView("Folder Unavailable", systemImage: "folder")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
        .exportSheet($export)
    }
}

/// Download or stop every video in a folder.
struct FolderActionsMenu: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let folder: FileFolder
    let statuses: [Int: FileStatus]

    static func hasActions(folder: FileFolder, statuses: [Int: FileStatus]) -> Bool {
        folder.allFiles.compactMap { statuses[$0.index] }.contains { !$0.isComplete }
    }

    var body: some View {
        let files = folder.allFiles.compactMap { statuses[$0.index] }
        let missing = files.filter { !$0.isComplete }
        if missing.contains(where: { !$0.wanted }) {
            Button { model.download(item.torrent, fileIndices: missing.map(\.file.index)) } label: {
                Label("Download Folder", systemImage: "arrow.down.circle")
            }
        }
        if missing.contains(where: \.isDownloading) {
            Button { model.stopDownloading(item.torrent, fileIndices: missing.map(\.file.index)) } label: {
                Label("Stop Downloading Folder", systemImage: "stop.circle")
            }
        }
    }
}

// MARK: - Rows

/// The videos directly in `folder`, then its subfolders as navigation rows.
struct MediaFolderRows: View {
    let item: LibraryItem
    let folder: FileFolder
    let statuses: [Int: FileStatus]
    @Binding var export: ExportItem?
    let onPlay: (TorrentFile) -> Void

    var body: some View {
        ForEach(folder.files) { file in
            if let fs = statuses[file.index] {
                MediaFileRow(item: item, status: fs, export: $export) { onPlay(file) }
            }
        }
        ForEach(folder.folders) { sub in
            NavigationLink(value: Route.folder(hash: item.id, folder: sub.id)) {
                FolderRow(item: item, folder: sub, statuses: statuses)
            }
            .contextMenu {
                FolderActionsMenu(item: item, folder: sub, statuses: statuses)
            }
        }
    }
}

struct FolderRow: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let folder: FileFolder
    let statuses: [Int: FileStatus]

    var body: some View {
        let files = folder.allFiles
        let fileStatuses = files.compactMap { statuses[$0.index] }
        let watched = files.filter { model.isWatched(torrent: item.torrent, file: $0) }.count
        let bytes = files.reduce(Int64(0)) { $0 + $1.length }
        let downloaded = fileStatuses.reduce(Int64(0)) { $0 + $1.downloadedBytes }

        HStack(spacing: Space.m) {
            Image(systemName: "folder")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: Metrics.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(folder.name)
                    .foregroundStyle(.primary)
                    .lineLimit(2)
                Text(Format.folderSummary(videos: files.count, watched: watched, bytes: bytes))
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            Spacer(minLength: Space.s)
            StateIndicator(
                isComplete: !fileStatuses.isEmpty && fileStatuses.allSatisfy(\.isComplete),
                isDownloading: fileStatuses.contains(where: \.isDownloading),
                progress: bytes > 0 ? Double(downloaded) / Double(bytes) : 0,
                paused: item.status.isPaused
            )
        }
        .accessibilityElement(children: .combine)
    }
}

/// A video or audio file: tap to play, menu for everything else.
struct MediaFileRow: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let status: FileStatus
    @Binding var export: ExportItem?
    let onPlay: () -> Void

    var body: some View {
        let file = status.file
        let fraction = model.watchedFraction(torrent: item.torrent, file: file)
        let watched = (fraction ?? 0) >= 0.9

        HStack(spacing: Space.s) {
            Button(action: onPlay) {
                HStack(spacing: Space.m) {
                    Image(systemName: file.kind == .audio ? "music.note" : "play.rectangle")
                        .font(.title3)
                        .foregroundStyle(watched ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tint))
                        .frame(width: Metrics.rowIcon)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(file.title)
                            .foregroundStyle(watched ? .secondary : .primary)
                            .lineLimit(2)
                        Text(status.detailText(watched: watched))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                        if let fraction, !watched {
                            ProgressView(value: fraction)
                                .tint(.secondary)
                                .frame(maxWidth: Metrics.watchedBar)
                        }
                    }
                    Spacer(minLength: Space.s)
                    FileStateIndicator(status: status, paused: item.status.isPaused)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityLabel(file.title)
            .accessibilityValue(accessibilityValue(fraction: fraction, watched: watched))
            .accessibilityHint("Plays the file")

            FileRowMenu(item: item, status: status, export: $export, onPlay: onPlay)
        }
        .contextMenu {
            FileActionsMenu(torrent: item.torrent, status: status, export: $export, onPlay: onPlay)
        }
    }

    private func accessibilityValue(fraction: Double?, watched: Bool) -> String {
        var parts = [status.detailText, status.accessibilityState]
        if watched { parts.append("Watched") } else if let fraction { parts.append("Watched \(Format.percent(fraction))") }
        return parts.joined(separator: ", ")
    }
}

/// Subtitles and other files: no playback, just save, share, download.
struct PlainFileRow: View {
    let item: LibraryItem
    let status: FileStatus
    @Binding var export: ExportItem?

    var body: some View {
        let file = status.file
        HStack(spacing: Space.m) {
            Image(systemName: file.kind.symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(file.fileName).lineLimit(2)
                if let folder = file.folderPath {
                    Text(folder)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                        .truncationMode(.middle)
                }
                Text(status.detailText)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
            .accessibilityElement(children: .combine)
            .accessibilityValue(status.accessibilityState)
            Spacer(minLength: Space.s)
            FileStateIndicator(status: status, paused: item.status.isPaused)
            FileRowMenu(item: item, status: status, export: $export, onPlay: nil)
        }
        .contextMenu {
            FileActionsMenu(torrent: item.torrent, status: status, export: $export)
        }
    }
}

/// The trailing ellipsis button of a file row.
struct FileRowMenu: View {
    let item: LibraryItem
    let status: FileStatus
    @Binding var export: ExportItem?
    let onPlay: (() -> Void)?

    var body: some View {
        Menu {
            FileActionsMenu(torrent: item.torrent, status: status, export: $export, onPlay: onPlay)
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .foregroundStyle(.secondary)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                .contentShape(.rect)
        }
        .buttonStyle(.borderless)
        .accessibilityLabel("Actions for \(status.file.title)")
    }
}
