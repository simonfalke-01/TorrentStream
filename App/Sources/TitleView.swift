import SwiftUI
import TorrentKit
import CatalogKit

extension View {
    /// Destinations for `Route`, registered once per navigation stack.
    func routeDestinations() -> some View {
        navigationDestination(for: Route.self) { route in
            switch route {
            case .title(let hash): TitleView(infoHash: hash)
            case .show(let show): ShowView(show: show)
            case .downloads(let show): ShowDownloadsView(show: show)
            case .download(let key): DownloadDetailView(key: key)
            }
        }
    }
}

// MARK: - Title page

/// A show or movie: artwork, one Play button, the synopsis, then its episodes.
struct TitleView: View {
    let infoHash: String
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?
    @State private var groupID: String?
    @State private var synopsisExpanded = false

    var body: some View {
        Group {
            if let item = model.item(infoHash) {
                content(item)
                    .toolbar {
                        ToolbarItem(placement: .primaryAction) {
                            Menu {
                                TitleActionsMenu(item: item, onRemove: { pendingRemoval = item })
                            } label: {
                                Label("More", systemImage: "ellipsis")
                            }
                        }
                    }
            } else {
                ContentUnavailableView("Removed from My List", systemImage: "rectangle.stack.badge.minus")
            }
        }
        .navigationBarTitleDisplayMode(.inline)
        .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
        .exportSheet($export)
        .removeTitleDialog(item: $pendingRemoval, export: $export)
    }

    private func content(_ item: LibraryItem) -> some View {
        let title = model.displayTitle(item)
        let entry = model.entry(for: item)
        let isSeries = model.playlist(item.status).count > 1

        return ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header(item, title: title)
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(title)
                            .font(.title.bold())
                            .accessibilityAddTraits(.isHeader)
                        metadata(item, entry: entry, isSeries: isSeries)
                    }
                    playArea(item, isSeries: isSeries)
                    about(entry)
                    if isSeries && item.status.phase == .ready {
                        episodes(item)
                    }
                    Text(item.status.name)
                        .font(.caption)
                        .foregroundStyle(.tertiary)
                        .textSelection(.enabled)
                        .accessibilityLabel("Release: \(item.status.name)")
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.l)
                .padding(.bottom, Space.xxl)
            }
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
    }

    // MARK: header

    @ViewBuilder
    private func header(_ item: LibraryItem, title: String) -> some View {
        if let backdrop = model.backdropURL(item) {
            PosterImage(url: backdrop, title: title, showsTitle: false, cornerRadius: 0)
                .aspectRatio(16 / 9, contentMode: .fit)
                .frame(maxWidth: .infinity)
        } else if let poster = model.posterURL(item) {
            PosterImage(url: poster, title: title, showsTitle: false, cornerRadius: Radius.medium)
                .frame(width: Metrics.headerPosterWidth, height: Metrics.headerPosterWidth * 1.5)
                .frame(maxWidth: .infinity)
                .padding(.top, Space.s)
        }
    }

    /// Year, episode count and quality, separated by space rather than punctuation.
    @ViewBuilder
    private func metadata(_ item: LibraryItem, entry: CatalogEntry?, isSeries: Bool) -> some View {
        let release = model.release(item.status.name)
        let year = entry?.year ?? release.year
        let count = model.playlist(item.status).count
        if year != nil || isSeries || release.resolution != nil {
            HStack(spacing: Space.m) {
                if let year { Text(String(year)) }
                if isSeries { Text(Format.episodes(count)) }
                if let res = release.resolution { QualityBadge(resolution: res) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    // MARK: play

    @ViewBuilder
    private func playArea(_ item: LibraryItem, isSeries: Bool) -> some View {
        switch item.status.phase {
        case .fetchingMetadata:
            HStack(spacing: Space.m) {
                ProgressView()
                Text("Loading")
                    .foregroundStyle(.secondary)
            }
            .frame(maxWidth: .infinity, minHeight: Metrics.playButtonHeight)
            .accessibilityElement(children: .combine)
        case .failed(let message):
            Label(message, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        case .ready:
            if let next = model.upNext(item) {
                VStack(alignment: .leading, spacing: Space.s) {
                    Button { play(next.file, item: item) } label: {
                        Label(playTitle(next), systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPlayButtonStyle())

                    if let caption = resumeCaption(next) {
                        Text(caption)
                            .font(.footnote)
                            .foregroundStyle(.secondary)
                            .frame(maxWidth: .infinity)
                    }
                }
            } else {
                Text("Nothing in this title can be played.")
                    .foregroundStyle(.secondary)
            }
        }
    }

    /// "Resume Episode 5", "Play Episode 6", or "Play" when the file isn't numbered.
    private func playTitle(_ next: UpNext) -> String {
        let verb = next.resumeAt != nil ? "Resume" : "Play"
        return model.episodeLabel(next.file).map { "\(verb) \($0)" } ?? verb
    }

    /// The episode's name and the time left, under the Play button.
    private func resumeCaption(_ next: UpNext) -> String? {
        let name = model.episodeLabel(next.file) != nil ? model.release(next.file.fileName).episodeTitle : nil
        let left = next.remaining.flatMap(Format.remaining)
        let parts = [name, left].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    // MARK: about

    @ViewBuilder
    private func about(_ entry: CatalogEntry?) -> some View {
        if let entry, entry.overview?.isEmpty == false || !entry.genres.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                if let overview = entry.overview, !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .lineLimit(synopsisExpanded ? nil : 3)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(Motion.standard) { synopsisExpanded.toggle() } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(synopsisExpanded ? "Shows less" : "Shows the full synopsis")
                }
                if !entry.genres.isEmpty {
                    Text(entry.genres.prefix(4).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: episodes

    private func episodes(_ item: LibraryItem) -> some View {
        let groups = model.episodeGroups(item.status)
        let next = model.upNext(item)
        let fallback = groups.first { g in g.files.contains { $0 == next?.file } }?.id ?? groups.first?.id
        let selectedID = groupID.flatMap { id in groups.contains { $0.id == id } ? id : nil } ?? fallback
        let group = groups.first { $0.id == selectedID }
        let files = group?.files ?? []
        let showsNumbers = files.contains { model.release($0.fileName).episode != nil }

        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                if groups.count > 1 {
                    Picker("Season", selection: Binding(get: { selectedID ?? "" }, set: { groupID = $0 })) {
                        ForEach(groups) { g in Text(g.name).tag(g.id) }
                    }
                    .pickerStyle(.menu)
                }
            }

            VStack(alignment: .leading, spacing: Space.xs) {
                ForEach(files, id: \.index) { file in
                    Button { play(file, item: item) } label: {
                        EpisodeRow(item: item, file: file, showsNumber: showsNumbers)
                    }
                    .buttonStyle(.plain)
                    .contextMenu {
                        EpisodeMenu(item: item, file: file, export: $export) { play(file, item: item) }
                    }
                }
            }
        }
    }

    // MARK: actions

    private func play(_ file: TorrentFile, item: LibraryItem) {
        playing = model.playbackRequest(torrent: item.torrent, file: file)
    }
}

// MARK: - Episode row

/// Episode number, title and how much is left. Tap plays; long press for the rest.
struct EpisodeRow: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let file: TorrentFile
    let showsNumber: Bool

    var body: some View {
        let release = model.release(file.fileName)
        let fraction = model.watchedFraction(torrent: item.torrent, file: file)
        let watched = (fraction ?? 0) >= 0.9
        let detail = detailText(fraction: fraction, watched: watched)

        HStack(spacing: Space.m) {
            if showsNumber {
                Text(release.episode.map { String($0) } ?? "")
                    .font(.title3.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                    .frame(width: Metrics.episodeNumber, alignment: .leading)
            }
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(model.episodeTitle(file))
                    .font(.body.weight(.medium))
                    .foregroundStyle(watched ? .secondary : .primary)
                    .lineLimit(2)
                if let detail {
                    Text(detail)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if let fraction, !watched {
                    WatchedBar(fraction: fraction)
                        .frame(maxWidth: Metrics.shelfPoster.width)
                }
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.s)
        .frame(minHeight: Metrics.touchTarget)
        .contentShape(.rect)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays the episode")
    }

    private func detailText(fraction: Double?, watched: Bool) -> String? {
        if watched { return "Watched" }
        let duration = model.knownDuration(torrent: item.torrent, file: file)
        if let fraction, let duration { return Format.remaining(duration * (1 - fraction)) }
        return duration.flatMap(Format.duration)
    }
}

// MARK: - Menus

/// The title page's More menu.
struct TitleActionsMenu: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let onRemove: () -> Void

    var body: some View {
        Section {
            Button { model.copyMagnet(item.torrent) } label: { Label("Copy Magnet Link", systemImage: "link") }
            ShareLink(item: item.torrent.magnetLink) { Label("Share Magnet Link", systemImage: "square.and.arrow.up") }
        }
        Section {
            Button(role: .destructive, action: onRemove) {
                Label("Remove from My List", systemImage: "minus.circle")
            }
        }
    }
}
