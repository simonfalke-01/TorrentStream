import SwiftUI
import TorrentKit
import CatalogKit
import SourceKit

// MARK: - Downloads pane

/// The Library's Downloads: what is still coming in, then the shows on the device, then the space they take.
struct DownloadsPane: View {
    @EnvironmentObject var downloads: DownloadsModel

    var body: some View {
        let active = downloads.unfinished
        let shows = downloads.downloadedShows.filter { !downloads.completed(show: $0.id).isEmpty }
        if active.isEmpty && shows.isEmpty {
            ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle",
                                   description: Text("Download episodes from a show’s page to watch them offline."))
        } else {
            List {
                if !active.isEmpty {
                    Section {
                        ForEach(active) { r in
                            NavigationLink(value: Route.download(r.id)) {
                                ActiveDownloadRow(record: r, activity: downloads.activity)
                            }
                            .swipeActions {
                                Button(role: .destructive) { downloads.remove(r.id) } label: {
                                    Label("Cancel", systemImage: "xmark")
                                }
                            }
                            .contextMenu { DownloadActions(record: r) }
                        }
                    } header: {
                        ActiveHeader(records: active, activity: downloads.activity)
                    }
                }
                if !shows.isEmpty {
                    Section("Downloaded") {
                        ForEach(shows) { show in
                            NavigationLink(value: Route.downloads(show)) {
                                DownloadedShowRow(show: show)
                            }
                            .swipeActions {
                                Button(role: .destructive) { downloads.removeAll(show: show) } label: {
                                    Label("Delete", systemImage: "trash")
                                }
                            }
                        }
                    } footer: {
                        StorageFooter()
                    }
                }
            }
            .listStyle(.insetGrouped)
            .animation(Motion.standard, value: active.map(\.id))
        }
    }
}

/// "Downloading" with the combined speed, and one control that pauses or resumes everything.
private struct ActiveHeader: View {
    let records: [DownloadRecord]
    @ObservedObject var activity: DownloadActivity
    @EnvironmentObject var downloads: DownloadsModel

    var body: some View {
        let allPaused = records.allSatisfy { $0.state == .paused || $0.state == .failed }
        HStack {
            Text("Downloading")
            if activity.totalRate > 0 {
                Text("\(Format.bytes(Int64(activity.totalRate)))/s")
                    .monospacedDigit()
                    .foregroundStyle(.secondary)
                    .contentTransition(.numericText())
            }
            Spacer()
            Button(allPaused ? "Resume All" : "Pause All") {
                allPaused ? downloads.resumeAll() : downloads.pauseAll()
            }
            .font(.subheadline)
            .textCase(nil)
        }
    }
}

/// One download still coming in: its still, the episode, a progress bar and one line of what's happening.
private struct ActiveDownloadRow: View {
    let record: DownloadRecord
    @ObservedObject var activity: DownloadActivity
    @EnvironmentObject var downloads: DownloadsModel

    var body: some View {
        HStack(spacing: Space.m) {
            DownloadThumb(record: record)
            VStack(alignment: .leading, spacing: Space.xs) {
                DownloadTitle(record: record)
                ProgressView(value: fraction)
                    .tint(record.state == .paused ? Color.secondary : Color.accentColor)
                    .opacity(record.state == .failed ? 0 : 1)
                Text(DownloadText.status(record, downloads: downloads, stat: stat))
                    .font(.footnote)
                    .foregroundStyle(record.state == .failed ? AnyShapeStyle(.orange) : AnyShapeStyle(.secondary))
                    .monospacedDigit()
                    .lineLimit(1)
            }
            pauseButton
        }
        .padding(.vertical, Space.xxs)
    }

    private var stat: DownloadActivity.Stat? { record.release.flatMap { activity.stats[$0.infoHash] } }

    private var fraction: Double { downloads.fractions[record.id] ?? 0 }

    @ViewBuilder
    private var pauseButton: some View {
        switch record.state {
        case .paused:
            Button { downloads.resume(record.id) } label: { Image(systemName: "play.circle") }
                .accessibilityLabel("Resume")
                .buttonStyle(.borderless)
                .font(.title2)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
        case .failed:
            Button { downloads.retry(record.id) } label: { Image(systemName: "arrow.clockwise.circle") }
                .accessibilityLabel("Try Again")
                .buttonStyle(.borderless)
                .font(.title2)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
        case .completed:
            EmptyView()
        default:
            Button { downloads.pause(record.id) } label: { Image(systemName: "pause.circle") }
                .accessibilityLabel("Pause")
                .buttonStyle(.borderless)
                .font(.title2)
                .foregroundStyle(.secondary)
                .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
        }
    }
}

/// A show with episodes on the device: its poster, the count and the space they take.
private struct DownloadedShowRow: View {
    let show: Show
    @EnvironmentObject var downloads: DownloadsModel
    @EnvironmentObject var shows: ShowsModel

    var body: some View {
        let done = downloads.completed(show: show.id)
        let size = done.reduce(Int64(0)) { $0 + ($1.release?.length ?? 0) }
        HStack(spacing: Space.m) {
            PosterImage(url: show.posterURL, title: show.title, showsTitle: false, cornerRadius: Radius.small / 2)
                .frame(width: Metrics.rowPoster.width * 0.75, height: Metrics.rowPoster.height * 0.75)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(shows.details[show.id]?.show.title ?? show.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                Text(show.isMovie ? Format.bytes(size) : "\(Format.episodes(done.count)), \(Format.bytes(size))")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
            }
        }
    }
}

/// What downloads take, and what's left on the phone.
private struct StorageFooter: View {
    @EnvironmentObject var downloads: DownloadsModel

    var body: some View {
        if let free = downloads.freeBytes, free > 0 {
            Text("Downloads use \(Format.bytes(downloads.storedBytes)). \(Format.bytes(free)) available on this device.")
        } else {
            Text("Downloads use \(Format.bytes(downloads.storedBytes)).")
        }
    }
}

// MARK: - Shared pieces

private struct DownloadThumb: View {
    let record: DownloadRecord
    static let width: CGFloat = 96

    var body: some View {
        PosterImage(url: record.thumbnailURL ?? record.show.bannerURL ?? record.show.posterURL,
                    title: record.show.title, showsTitle: false, cornerRadius: Radius.small)
            .frame(width: Self.width, height: Self.width * 9 / 16)
    }
}

/// The show, then the episode beneath it.
private struct DownloadTitle: View {
    let record: DownloadRecord
    @EnvironmentObject var shows: ShowsModel

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            Text(shows.details[record.show.id]?.show.title ?? record.show.title)
                .font(.subheadline.weight(.semibold))
                .lineLimit(1)
            if let ep = DownloadText.episode(record, details: shows.details[record.show.id]) {
                Text(ep)
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
        }
    }
}

enum DownloadText {
    /// "S1 E5, The Title", or nil for a movie.
    static func episode(_ r: DownloadRecord, details d: ShowDetails?) -> String? {
        if r.isMovie { return nil }
        let label = ShowsModel.shortLabel(d, season: r.season, episode: r.episode)
        guard let t = r.episodeTitle, !t.isEmpty else { return label }
        return "\(label), \(t)"
    }

    /// One line on what a download is doing now.
    @MainActor
    static func status(_ r: DownloadRecord, downloads: DownloadsModel, stat: DownloadActivity.Stat?) -> String {
        let b = downloads.bytes(r)
        let amount = b.total.map { "\(Format.bytes(b.done)) of \(Format.bytes($0))" }
        switch r.state {
        case .queued: return "Waiting"
        case .finding: return "Finding the best version"
        case .paused: return amount.map { "Paused, \($0)" } ?? "Paused"
        case .failed: return r.failure ?? "Didn’t finish"
        case .completed: return b.total.map(Format.bytes) ?? "Downloaded"
        case .downloading:
            guard let stat else { return amount ?? "Starting" }
            if stat.waiting { return "Waiting for the stream to finish" }
            if stat.rate < 1 {
                return stat.peers == 0 ? "Looking for peers" : "Connecting to \(Format.count(stat.peers)) peers"
            }
            var parts = ["\(Format.bytes(Int64(stat.rate)))/s"]
            if let total = b.total, let left = Format.remaining(Double(max(0, total - b.done)) / stat.rate) {
                parts.append(left)
            }
            return parts.joined(separator: ", ")
        }
    }
}

/// Pause, resume, retry and cancel, for menus.
private struct DownloadActions: View {
    let record: DownloadRecord
    @EnvironmentObject var downloads: DownloadsModel

    var body: some View {
        switch record.state {
        case .paused:
            Button { downloads.resume(record.id) } label: { Label("Resume", systemImage: "play") }
        case .failed:
            Button { downloads.retry(record.id) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
        case .completed:
            EmptyView()
        default:
            Button { downloads.pause(record.id) } label: { Label("Pause", systemImage: "pause") }
        }
        Button(role: .destructive) { downloads.remove(record.id) } label: {
            Label(record.state == .completed ? "Delete Download" : "Cancel Download",
                  systemImage: record.state == .completed ? "trash" : "xmark")
        }
    }
}

// MARK: - One download

/// Everything about one download: progress, speed, the release and the peers sending it.
struct DownloadDetailView: View {
    let key: String
    @EnvironmentObject var downloads: DownloadsModel
    @EnvironmentObject var shows: ShowsModel
    @Environment(\.dismiss) private var dismiss
    @State private var peers: [PeerSnapshot] = []
    @State private var versions: EpisodeTarget?
    @State private var launch: EpisodeLaunch?
    @State private var confirmingCancel = false

    var body: some View {
        Group {
            if let r = downloads.record(key) {
                DetailList(record: r, activity: downloads.activity, peers: peers,
                           onPlay: { launch = EpisodeLaunch(show: r.show, seasonID: r.seasonID, episode: r.episode) },
                           onChooseVersion: { Task { await chooseVersion(r) } },
                           onCancel: { confirmingCancel = true })
            } else {
                ContentUnavailableView("Download Removed", systemImage: "arrow.down.circle")
            }
        }
        .navigationTitle("Download")
        .navigationBarTitleDisplayMode(.inline)
        .task {
            while !Task.isCancelled {
                peers = downloads.peers(key)
                try? await Task.sleep(for: .seconds(1))
            }
        }
        .sheet(item: $versions) { t in
            VersionsView(target: t, current: downloads.record(key)?.release?.infoHash, forDownload: true) { source in
                versions = nil
                downloads.download(t.details, t.season, t.episode, version: source)
            }
        }
        .fullScreenCover(item: $launch) { PlaybackLauncher(launch: $0) }
        .confirmationDialog("Cancel this download?", isPresented: $confirmingCancel, titleVisibility: .visible) {
            Button(downloads.record(key)?.state == .completed ? "Delete Download" : "Cancel Download", role: .destructive) {
                downloads.remove(key)
                dismiss()
            }
            Button("Keep", role: .cancel) {}
        }
    }

    private func chooseVersion(_ r: DownloadRecord) async {
        guard let d = try? await shows.loadDetails(r.show), let s = d.season(id: r.seasonID),
              let e = s.episodes.first(where: { $0.number == r.episode }) else { return }
        versions = EpisodeTarget(details: d, season: s, episode: e)
    }
}

private struct DetailList: View {
    let record: DownloadRecord
    @ObservedObject var activity: DownloadActivity
    let peers: [PeerSnapshot]
    let onPlay: () -> Void
    let onChooseVersion: () -> Void
    let onCancel: () -> Void
    @EnvironmentObject var downloads: DownloadsModel
    @EnvironmentObject var shows: ShowsModel

    private var stat: DownloadActivity.Stat? { record.release.flatMap { activity.stats[$0.infoHash] } }

    var body: some View {
        let b = downloads.bytes(record)
        List {
            Section {
                HStack(spacing: Space.m) {
                    DownloadThumb(record: record)
                    DownloadTitle(record: record)
                }
                .listRowSeparator(.hidden)
                if record.state != .completed {
                    VStack(alignment: .leading, spacing: Space.s) {
                        ProgressView(value: downloads.fractions[record.id] ?? 0)
                            .tint(record.state == .paused ? Color.secondary : Color.accentColor)
                        HStack {
                            Text(b.total.map { "\(Format.bytes(b.done)) of \(Format.bytes($0))" } ?? " ")
                            Spacer()
                            Text((downloads.fractions[record.id] ?? 0).formatted(.percent.precision(.fractionLength(0))))
                        }
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .monospacedDigit()
                    }
                }
            }

            Section {
                if record.state == .completed {
                    Button(action: onPlay) { Label("Play", systemImage: "play.fill") }
                } else {
                    primaryAction
                }
                Button(action: onChooseVersion) { Label("Choose Another Version…", systemImage: "square.stack") }
                Button(role: .destructive, action: onCancel) {
                    Label(record.state == .completed ? "Delete Download" : "Cancel Download",
                          systemImage: record.state == .completed ? "trash" : "xmark")
                }
            }

            Section("Details") {
                LabeledContent("Status", value: DownloadText.status(record, downloads: downloads, stat: stat))
                if record.state == .downloading, let stat {
                    LabeledContent("Speed", value: "\(Format.bytes(Int64(stat.rate)))/s")
                    LabeledContent("Peers", value: Format.count(stat.peers))
                }
                if let version = record.choice?.title ?? record.release?.group {
                    LabeledContent("Version") {
                        Text(version).multilineTextAlignment(.trailing).lineLimit(3)
                    }
                }
                if let total = b.total { LabeledContent("Size", value: Format.bytes(total)) }
            }
            .monospacedDigit()

            if record.state == .downloading || record.state == .paused, !peers.isEmpty {
                Section {
                    ForEach(peers.prefix(30), id: \.address) { PeerRow(peer: $0) }
                } header: {
                    Text("Peers")
                } footer: {
                    if peers.count > 30 { Text("The 30 fastest of \(Format.count(peers.count)).") }
                }
            }
        }
        .animation(Motion.standard, value: record.state)
    }

    @ViewBuilder
    private var primaryAction: some View {
        switch record.state {
        case .paused:
            Button { downloads.resume(record.id) } label: { Label("Resume Download", systemImage: "play") }
        case .failed:
            Button { downloads.retry(record.id) } label: { Label("Try Again", systemImage: "arrow.clockwise") }
        default:
            Button { downloads.pause(record.id) } label: { Label("Pause Download", systemImage: "pause") }
        }
    }
}

/// A peer: its software, its address, how much it has and what it sends.
private struct PeerRow: View {
    let peer: PeerSnapshot

    var body: some View {
        HStack(spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(peer.client.isEmpty ? "Unknown Client" : peer.client)
                    .font(.subheadline)
                    .lineLimit(1)
                Text(peer.progress >= 1 ? "\(peer.address), has everything"
                                        : "\(peer.address), has \(peer.progress.formatted(.percent.precision(.fractionLength(0))))")
                    .font(.caption)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
            }
            Spacer(minLength: Space.s)
            Text(peer.downloadRate >= 1024 ? "\(Format.bytes(Int64(peer.downloadRate)))/s" : (peer.isChoking ? "Busy" : "Idle"))
                .font(.subheadline)
                .foregroundStyle(peer.downloadRate >= 1024 ? .primary : .tertiary)
        }
        .monospacedDigit()
        .accessibilityElement(children: .combine)
    }
}

// MARK: - A show's downloads

/// The episodes of one show on the device. Tap to play; swipe or Edit to delete.
struct ShowDownloadsView: View {
    let show: Show
    @EnvironmentObject var downloads: DownloadsModel
    @EnvironmentObject var shows: ShowsModel
    @State private var launch: EpisodeLaunch?
    @State private var selection: Set<String> = []
    @Environment(\.editMode) private var editMode

    var body: some View {
        let list = downloads.completed(show: show.id)
        let title = shows.details[show.id]?.show.title ?? show.title
        Group {
            if list.isEmpty {
                ContentUnavailableView("No Downloads", systemImage: "arrow.down.circle")
            } else {
                List(selection: $selection) {
                    Section {
                        ForEach(list) { r in
                            Button { launch = EpisodeLaunch(show: r.show, seasonID: r.seasonID, episode: r.episode) } label: {
                                HStack(spacing: Space.m) {
                                    DownloadThumb(record: r)
                                    VStack(alignment: .leading, spacing: Space.xxs) {
                                        Text(DownloadText.episode(r, details: shows.details[show.id]) ?? title)
                                            .font(.subheadline.weight(.medium))
                                            .lineLimit(2)
                                        if let len = r.release?.length {
                                            Text(Format.bytes(len))
                                                .font(.footnote)
                                                .foregroundStyle(.secondary)
                                        }
                                    }
                                    Spacer(minLength: 0)
                                }
                                .contentShape(.rect)
                            }
                            .buttonStyle(.plain)
                            .tag(r.id)
                            .contextMenu {
                                Button { launch = EpisodeLaunch(show: r.show, seasonID: r.seasonID, episode: r.episode) } label: {
                                    Label("Play", systemImage: "play")
                                }
                                Button(role: .destructive) { downloads.remove(r.id) } label: {
                                    Label("Delete Download", systemImage: "trash")
                                }
                            }
                        }
                        .onDelete { idx in for i in idx { downloads.remove(list[i].id) } }
                    } footer: {
                        Text("\(Format.episodes(list.count)), \(Format.bytes(list.reduce(Int64(0)) { $0 + ($1.release?.length ?? 0) }))")
                    }
                }
            }
        }
        .navigationTitle(title)
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .topBarTrailing) { EditButton() }
            if editMode?.wrappedValue.isEditing == true {
                ToolbarItem(placement: .bottomBar) {
                    Button("Delete", role: .destructive) {
                        for k in selection { downloads.remove(k) }
                        selection = []
                    }
                    .disabled(selection.isEmpty)
                }
            } else {
                ToolbarItem(placement: .bottomBar) {
                    NavigationLink(value: Route.show(show)) { Text("Go to Show") }
                }
            }
        }
        .fullScreenCover(item: $launch) { PlaybackLauncher(launch: $0) }
    }
}
