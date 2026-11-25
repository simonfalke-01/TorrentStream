import SwiftUI
import TorrentKit
import CatalogKit
import SourceKit

/// One episode of a loaded show, for sheets and menus.
struct EpisodeTarget: Identifiable {
    let details: ShowDetails
    let season: ShowSeason
    let episode: ShowEpisode
    var id: String { ShowsModel.key(details.show.id, season.id, episode.number) }
}

extension Show {
    /// "2023" or "Movie, 2016", to tell same-named entries apart.
    var caption: String? {
        let year = year.map(String.init)
        switch format {
        case "MOVIE": return ["Movie", year].compactMap { $0 }.joined(separator: ", ")
        case "OVA", "SPECIAL": return ["Special", year].compactMap { $0 }.joined(separator: ", ")
        default: return year
        }
    }
}

// MARK: - Show page

/// A show or movie: artwork, one Play button, the synopsis, then seasons and episodes.
struct ShowView: View {
    let show: Show
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @EnvironmentObject var downloads: DownloadsModel
    @State private var seasonID: Int?
    @State private var launch: EpisodeLaunch?
    @State private var versions: EpisodeTarget?
    /// An episode whose download version is being picked.
    @State private var downloadVersions: EpisodeTarget?
    @State private var loadError: String?
    @State private var synopsisExpanded = false
    @State private var confirmingRemoval = false

    private var details: ShowDetails? { shows.details[shows.rootID(show)] }
    /// The first season once loaded, which names the show.
    private var main: Show { details?.show ?? show }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 0) {
                header
                VStack(alignment: .leading, spacing: Space.xl) {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text(main.title)
                            .font(.title.bold())
                            .accessibilityAddTraits(.isHeader)
                        metadata
                    }
                    playArea
                    about
                    if let d = details, !d.show.isMovie {
                        episodes(d)
                    } else if details == nil, let loadError {
                        loadFailure(loadError)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.top, Space.l)
                .padding(.bottom, Space.xxl)

                moreLikeThis
                    .padding(.bottom, Space.xxl)
            }
            .frame(maxWidth: Metrics.contentMaxWidth)
            .frame(maxWidth: .infinity)
        }
        .navigationBarTitleDisplayMode(.inline)
        .toolbar {
            ToolbarItem(placement: .primaryAction) {
                Menu { moreMenu } label: { Label("More", systemImage: "ellipsis") }
            }
        }
        .task { await load() }
        .task { await shows.loadRecommendations(show) }
        .refreshable { await load(force: true) }
        // What this page readied goes quiet once it's left; back from the player, it's readied again.
        .onDisappear { if let d = details { shows.stopWarming(d) } }
        .fullScreenCover(item: $launch, onDismiss: { if let d = details { shows.warm(d) } }) { PlaybackLauncher(launch: $0) }
        .sheet(item: $versions) { target in
            VersionsView(target: target, current: shows.currentVersion(target.details, target.season, target.episode)) { source in
                // Chosen, not played: Play uses it next.
                versions = nil
                shows.choose(source, target.details, target.season, target.episode)
            }
        }
        .sheet(item: $downloadVersions) { target in
            let key = ShowsModel.key(target.details.show.id, target.season.id, target.episode.number)
            VersionsView(target: target, current: downloads.record(key)?.release?.infoHash, forDownload: true) { source in
                downloadVersions = nil
                downloads.download(target.details, target.season, target.episode, version: source)
            }
        }
        .confirmationDialog(main.isMovie ? "Remove the download of \(main.title)?" : "Remove every download of \(main.title)?",
                            isPresented: $confirmingRemoval, titleVisibility: .visible) {
            Button(main.isMovie ? "Remove Download" : "Remove Downloads", role: .destructive) {
                downloads.removeAll(show: details?.show ?? main)
            }
            Button("Cancel", role: .cancel) {}
        } message: {
            Text("It streams again when you play it.")
        }
    }

    private func load(force: Bool = false) async {
        do {
            let d = try await shows.loadDetails(show, force: force)
            loadError = nil
            shows.warm(d)
            // Opened from a later season: start there.
            if seasonID == nil, d.season(id: show.id) != nil, show.id != d.show.id { seasonID = show.id }
        } catch {
            loadError = "Episodes couldn’t be loaded. Check your connection and try again."
        }
    }

    // MARK: header

    @ViewBuilder
    private var header: some View {
        PosterImage(url: show.posterURL ?? main.posterURL, title: main.title, showsTitle: false, cornerRadius: Radius.medium)
            .frame(width: Metrics.headerPosterWidth, height: Metrics.headerPosterWidth * 1.5)
            .frame(maxWidth: .infinity)
            .padding(.top, Space.s)
    }

    /// Year, length and genre, set apart by space rather than punctuation.
    @ViewBuilder
    private var metadata: some View {
        let parts = metadataParts
        if !parts.isEmpty {
            HStack(spacing: Space.m) {
                ForEach(parts, id: \.self) { Text($0) }
            }
            .font(.subheadline)
            .foregroundStyle(.secondary)
            .accessibilityElement(children: .combine)
        }
    }

    private var metadataParts: [String] {
        var out: [String] = []
        if let y = main.year { out.append(String(y)) }
        if let d = details {
            if d.show.isMovie {
                if let m = d.show.duration, let t = Format.duration(Double(m * 60)) { out.append(t) }
            } else if d.seasons.count > 1 {
                out.append("\(d.seasons.count) Seasons")
            } else if let s = d.seasons.first, !s.episodes.isEmpty {
                out.append(Format.episodes(s.media.episodes ?? s.episodes.count))
            }
            if d.seasons.last?.media.isAiring == true { out.append("New Episodes") }
        } else if main.isMovie, let m = main.duration, let t = Format.duration(Double(m * 60)) {
            out.append(t)
        }
        return out
    }

    // MARK: play

    /// Play fills the row; My List sits beside it as a circle, so the one action that matters reads first.
    @ViewBuilder
    private var playArea: some View {
        let next = details.flatMap(shows.upNext)
        let inList = shows.isInMyList(show)
        VStack(spacing: Space.s) {
            HStack(spacing: Space.s) {
                if details != nil && next == nil {
                    Text(comingText)
                        .font(.headline)
                        .frame(maxWidth: .infinity, minHeight: Metrics.playButtonHeight)
                        .background(.fill.tertiary, in: .capsule)
                } else {
                    Button { play(next) } label: {
                        Label(playTitle(next), systemImage: "play.fill")
                    }
                    .buttonStyle(PrimaryPlayButtonStyle())
                }

                Button { shows.toggleMyList(show) } label: {
                    Image(systemName: inList ? "checkmark" : "plus")
                        .font(.title3.weight(.semibold))
                        .contentTransition(.symbolEffect(.replace))
                        .frame(width: Metrics.playButtonHeight, height: Metrics.playButtonHeight)
                        .background(.fill.tertiary, in: .circle)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .accessibilityLabel(inList ? "Remove from My List" : "Add to My List")
                .sensoryFeedback(.selection, trigger: inList)

                // A movie downloads from here; a show's episodes each have their own button.
                if let d = details, d.show.isMovie, let key = downloads.movieKey(d) {
                    DownloadControl(status: downloads.status(key), prominent: true,
                                    onDownload: { downloads.downloadMovie(d) },
                                    onRemove: { downloads.remove(key) },
                                    onRetry: { downloads.retry(key) },
                                    onPause: { downloads.pause(key) },
                                    onResume: { downloads.resume(key) },
                                    onChooseVersion: {
                                        if let s = d.seasons.first, let e = s.episodes.first(where: \.isAired) {
                                            downloadVersions = EpisodeTarget(details: d, season: s, episode: e)
                                        }
                                    })
                }
            }

            if let caption = resumeCaption(next) {
                Text(caption)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(1)
                    .frame(maxWidth: .infinity, alignment: .leading)
                    .padding(.horizontal, Space.l)
            }
        }
    }

    /// "Resume S1 E3", "Play Episode 1", or "Play" for a movie: the button names what it starts.
    private func playTitle(_ next: ShowUpNext?) -> String {
        let verb = next?.resumeAt != nil ? "Resume" : "Play"
        guard let next, let d = details, !d.show.isMovie else { return verb }
        return "\(verb) \(ShowsModel.episodeLabel(d, next.season, next.episode))"
    }

    /// The episode's name and the time left, under the Play button.
    private func resumeCaption(_ next: ShowUpNext?) -> String? {
        guard let next, let d = details else { return nil }
        let left = next.remaining.flatMap(Format.remaining)
        if d.show.isMovie { return left }
        let parts = [next.episode.title, left].compactMap { $0 }.filter { !$0.isEmpty }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }

    private var comingText: String {
        if let at = main.nextAiringAt { return "Coming \(at.formatted(.dateTime.month(.abbreviated).day()))" }
        return "Coming Soon"
    }

    private func play(_ next: ShowUpNext?) {
        guard let d = details, let next else {
            launch = EpisodeLaunch(show: show)
            return
        }
        launch = EpisodeLaunch(show: d.show, seasonID: next.season.id, episode: next.episode.number)
    }

    // MARK: about

    @ViewBuilder
    private var about: some View {
        let overview = (show.overview?.isEmpty == false ? show.overview : main.overview) ?? ""
        let genres = main.genres.isEmpty ? show.genres : main.genres
        if !overview.isEmpty || !genres.isEmpty {
            VStack(alignment: .leading, spacing: Space.s) {
                if !overview.isEmpty {
                    Text(overview)
                        .font(.subheadline)
                        .lineLimit(synopsisExpanded ? nil : 3)
                        .contentShape(.rect)
                        .onTapGesture { withAnimation(Motion.standard) { synopsisExpanded.toggle() } }
                        .accessibilityAddTraits(.isButton)
                        .accessibilityHint(synopsisExpanded ? "Shows less" : "Shows the full synopsis")
                }
                if !genres.isEmpty {
                    Text(genres.prefix(4).joined(separator: ", "))
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }
            }
        }
    }

    // MARK: episodes

    private func episodes(_ d: ShowDetails) -> some View {
        let selected = selectedSeason(d)

        return VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text("Episodes")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                if d.seasons.count > 1 {
                    Picker("Season", selection: Binding(get: { selected?.id ?? 0 }, set: { seasonID = $0 })) {
                        ForEach(d.seasons) { s in Text("Season \(s.number)").tag(s.id) }
                    }
                    .pickerStyle(.menu)
                }
            }

            if let season = selected {
                if d.seasons.count > 1, season.media.title != d.show.title {
                    Text(season.media.title)
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                if season.episodes.isEmpty {
                    Text(season.media.nextAiringAt.map { "Starts \($0.formatted(date: .abbreviated, time: .omitted))" }
                         ?? "Episodes aren’t out yet.")
                        .foregroundStyle(.secondary)
                } else {
                    LazyVStack(alignment: .leading, spacing: Space.xs) {
                        ForEach(season.episodes) { e in
                            episodeButton(d, season, e)
                        }
                    }
                }
            }
        }
    }

    /// The season picked, else the one the Play button is in.
    private func selectedSeason(_ d: ShowDetails) -> ShowSeason? {
        let fallback = shows.upNext(d)?.season.id ?? d.seasons.first?.id
        return seasonID.flatMap(d.season(id:)) ?? fallback.flatMap(d.season(id:))
    }

    private func episodeButton(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) -> some View {
        let p = shows.progress(d.show, s, e)
        let key = ShowsModel.key(d.show.id, s.id, e.number)
        let download = downloads.status(key)
        return Button {
            launch = EpisodeLaunch(show: d.show, seasonID: s.id, episode: e.number)
        } label: {
            ShowEpisodeRow(episode: e, minutes: s.media.duration, progress: p,
                           trailingInset: e.isAired ? Metrics.indicator + Space.m : 0)
        }
        // The finger landing is a strong hint: start on that episode before the tap completes.
        .buttonStyle(TouchDownButtonStyle { shows.warmTouched(d, s, e) })
        .disabled(!e.isAired)
        // Centred on the still, its symbol's edge lined up with the page margin.
        .overlay(alignment: .topTrailing) {
            if e.isAired {
                DownloadControl(status: download,
                                onDownload: { downloads.download(d, s, e) },
                                onRemove: { downloads.remove(key) },
                                onRetry: { downloads.retry(key) },
                                onPause: { downloads.pause(key) },
                                onResume: { downloads.resume(key) },
                                onChooseVersion: { downloadVersions = EpisodeTarget(details: d, season: s, episode: e) })
                    .padding(.top, Space.s + (ShowEpisodeRow.thumbHeight - Metrics.touchTarget) / 2)
                    .offset(x: (Metrics.touchTarget - Metrics.indicator) / 2)
            }
        }
        .contextMenu {
            if e.isAired {
                Button { launch = EpisodeLaunch(show: d.show, seasonID: s.id, episode: e.number) } label: {
                    Label(p.map { $0.position > 20 && !$0.isWatched } == true ? "Resume" : "Play", systemImage: "play")
                }
                Button { versions = EpisodeTarget(details: d, season: s, episode: e) } label: {
                    Label("Choose Version…", systemImage: "slider.horizontal.3")
                }
                Section {
                    switch download {
                    case .notDownloaded:
                        Button { downloads.download(d, s, e) } label: {
                            Label("Download Episode", systemImage: "arrow.down.circle")
                        }
                        Button { downloadVersions = EpisodeTarget(details: d, season: s, episode: e) } label: {
                            Label("Download a Version…", systemImage: "square.stack")
                        }
                    case .completed:
                        Button { downloadVersions = EpisodeTarget(details: d, season: s, episode: e) } label: {
                            Label("Download Another Version…", systemImage: "square.stack")
                        }
                        Button(role: .destructive) { downloads.remove(key) } label: {
                            Label("Remove Download", systemImage: "trash")
                        }
                    case .paused:
                        Button { downloads.resume(key) } label: { Label("Resume Download", systemImage: "play") }
                        Button(role: .destructive) { downloads.remove(key) } label: {
                            Label("Cancel Download", systemImage: "xmark")
                        }
                    default:
                        Button { downloads.pause(key) } label: { Label("Pause Download", systemImage: "pause") }
                        Button(role: .destructive) { downloads.remove(key) } label: {
                            Label("Cancel Download", systemImage: "xmark")
                        }
                    }
                }
                Section {
                    if p?.isWatched == true {
                        Button { shows.setWatched(false, show: d.show, season: s, episode: e) } label: {
                            Label("Mark as Unwatched", systemImage: "eye.slash")
                        }
                    } else {
                        Button { shows.setWatched(true, show: d.show, season: s, episode: e) } label: {
                            Label("Mark as Watched", systemImage: "eye")
                        }
                    }
                }
            }
        }
    }

    private func loadFailure(_ message: String) -> some View {
        VStack(alignment: .leading, spacing: Space.s) {
            Text(message)
                .font(.subheadline)
                .foregroundStyle(.secondary)
            Button("Try Again") { Task { await load(force: true) } }
                .buttonStyle(.bordered)
        }
    }

    // MARK: more like this

    @ViewBuilder
    private var moreLikeThis: some View {
        if let list = shows.recommendations[shows.rootID(show)], !list.isEmpty {
            VStack(alignment: .leading, spacing: Space.m) {
                Text("More Like This")
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                    .padding(.horizontal, Space.l)
                ScrollView(.horizontal) {
                    LazyHStack(alignment: .top, spacing: Space.m) {
                        ForEach(list.prefix(15)) { s in
                            ShowPosterCard(show: s) { launch = EpisodeLaunch(show: s) }
                                .frame(width: Metrics.shelfPoster.width)
                        }
                    }
                    .scrollTargetLayout()
                    .padding(.horizontal, Space.l)
                }
                .scrollIndicators(.hidden)
                .scrollTargetBehavior(.viewAligned)
            }
        }
    }

    // MARK: menu

    @ViewBuilder
    private var moreMenu: some View {
        if let d = details, let next = shows.upNext(d) {
            Section {
                Button { versions = EpisodeTarget(details: d, season: next.season, episode: next.episode) } label: {
                    Label("Choose Version…", systemImage: "slider.horizontal.3")
                }
            }
        }
        if let d = details {
            downloadsMenu(d)
        }
        if shows.history.contains(where: { $0.show.id == shows.rootID(show) }) {
            Button { shows.removeFromContinueWatching(show) } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        }
        if let url = URL(string: "https://anilist.co/anime/\(main.id)") {
            ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
        }
    }

    /// Download the season shown or the whole show, and remove what's downloaded.
    @ViewBuilder
    private func downloadsMenu(_ d: ShowDetails) -> some View {
        let toFetch: (ShowSeason) -> Int = { s in
            s.episodes.filter { e in
                guard e.isAired else { return false }
                let status = downloads.status(d, s, e)
                if case .failed = status { return true }
                return status == .notDownloaded
            }.count
        }
        let season = selectedSeason(d)
        let others = d.seasons.filter { $0.id != season?.id }.contains { toFetch($0) > 0 }
        let hasDownloads = !downloads.summary(d.show).isEmpty
        Section {
            if !d.show.isMovie {
                if let season, toFetch(season) > 0 {
                    Button { started(downloads.download(season: season, of: d)) } label: {
                        Label(d.seasons.count > 1 ? "Download Season \(season.number)" : "Download All Episodes",
                              systemImage: "arrow.down.circle")
                    }
                }
                if d.seasons.count > 1, others {
                    Button { started(downloads.downloadAll(d)) } label: {
                        Label("Download All Episodes", systemImage: "arrow.down.circle")
                    }
                }
            }
            if hasDownloads {
                Button(role: .destructive) { confirmingRemoval = true } label: {
                    Label(d.show.isMovie ? "Remove Download" : "Remove Downloads", systemImage: "trash")
                }
            }
        }
    }

    private func started(_ count: Int) {
        guard count > 0 else { return }
        model.showToast("Downloading \(Format.episodes(count))", systemImage: "arrow.down.circle.fill")
    }
}

// MARK: - Episode row

/// Still, number and name, then how much is left. Episodes not out yet say when they air.
struct ShowEpisodeRow: View {
    let episode: ShowEpisode
    let minutes: Int?
    let progress: EpisodeProgress?
    /// Room kept clear on the right of the name, for a button laid over the row.
    var trailingInset: CGFloat = 0

    static let thumbWidth: CGFloat = 128
    static let thumbHeight: CGFloat = thumbWidth * 9 / 16
    private var thumbWidth: CGFloat { Self.thumbWidth }

    var body: some View {
        let watched = progress?.isWatched == true
        let named = episode.title.map { !$0.isEmpty } ?? false
        // Without a still the tile carries the number, so the line above the name isn't needed.
        let eyebrow = named && episode.thumbnailURL != nil
        VStack(alignment: .leading, spacing: Space.s) {
            HStack(alignment: .top, spacing: Space.m) {
                VStack(spacing: Space.xs) {
                    PosterImage(url: episode.thumbnailURL, title: String(episode.number),
                                showsTitle: episode.thumbnailURL == nil, titleFont: .title3.weight(.semibold))
                        .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                    if let p = progress, p.fraction > 0.02, !watched {
                        WatchedBar(fraction: p.fraction)
                            .frame(width: thumbWidth)
                    }
                }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    if eyebrow {
                        Text("Episode \(episode.number)")
                            .font(.footnote.weight(.semibold))
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Text(named ? episode.title ?? "" : "Episode \(episode.number)")
                        .font(.body.weight(.medium))
                        .foregroundStyle(watched || !episode.isAired ? .secondary : .primary)
                        .lineLimit(2)
                    if let detail {
                        Text(detail)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                }
                .padding(.top, Space.xxs)
                .padding(.trailing, trailingInset)
                Spacer(minLength: 0)
            }
            // The synopsis spans the row's full width, under the still, as a quieter third tier.
            if let overview = episode.overview, !overview.isEmpty {
                Text(overview)
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .lineLimit(3)
                    .frame(maxWidth: .infinity, alignment: .leading)
            }
        }
        .padding(.vertical, Space.s)
        .frame(minHeight: Metrics.touchTarget)
        .contentShape(.rect)
        .opacity(episode.isAired ? 1 : 0.6)
        .accessibilityElement(children: .combine)
        .accessibilityHint(episode.isAired ? "Plays the episode" : "")
    }

    private var detail: String? {
        if !episode.isAired {
            return episode.airsAt.map { "Airs \($0.formatted(.dateTime.weekday(.wide).month(.abbreviated).day()))" } ?? "Not out yet"
        }
        if progress?.isWatched == true { return "Watched" }
        if let p = progress, p.duration > 0, p.position > 20 { return Format.remaining(p.duration - p.position) }
        return (episode.runtime ?? minutes).flatMap { Format.duration(Double($0 * 60)) }
    }
}

// MARK: - Cards

/// A catalog poster. Tap opens the show; long press plays or adds it to My List.
struct ShowPosterCard: View {
    @EnvironmentObject var shows: ShowsModel
    let show: Show
    var showsCaption = false
    /// A short line under the title in the accent color, such as "New Episode".
    var note: String? = nil
    /// A quieter line under the title, such as "3 Episodes".
    var detail: String? = nil
    let onPlay: () -> Void

    var body: some View {
        NavigationLink(value: Route.show(show)) {
            VStack(alignment: .leading, spacing: Space.s) {
                PosterImage(url: show.posterURL, title: show.title)
                    .aspectRatio(2 / 3, contentMode: .fit)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(show.title)
                        .font(.footnote.weight(.medium))
                        .lineLimit(2, reservesSpace: !showsCaption && note == nil && detail == nil)
                        .multilineTextAlignment(.leading)
                    if let note {
                        Text(note)
                            .font(.caption.weight(.semibold))
                            .foregroundStyle(.tint)
                    } else if let detail {
                        Text(detail)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    } else if showsCaption, let caption = show.caption {
                        Text(caption)
                            .font(.caption)
                            .foregroundStyle(.secondary)
                    }
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if !show.isUpcoming {
                Button(action: onPlay) { Label("Play", systemImage: "play") }
            }
            Button { shows.toggleMyList(show) } label: {
                if shows.isInMyList(show) {
                    Label("Remove from My List", systemImage: "minus.circle")
                } else {
                    Label("Add to My List", systemImage: "plus")
                }
            }
        } preview: {
            PosterImage(url: show.posterURL, title: show.title)
                .frame(width: 240, height: 360)
        }
    }
}

/// A show in progress: the episode's still, how far along, and what plays.
struct ShowContinueCard: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    let entry: WatchEntry
    let next: ShowUpNext?
    let onPlay: () -> Void

    var body: some View {
        let d = shows.details[entry.show.id]
        let fraction = next.flatMap { n in shows.progress(entry.show, n.season, n.episode)?.fraction }
        let still = next?.episode.thumbnailURL ?? entry.show.bannerURL ?? entry.show.posterURL

        Button(action: onPlay) {
            ContinueCardLabel(imageURL: still, title: d?.show.title ?? entry.show.title,
                              detail: Self.detail(entry: entry, next: next, details: d), progress: fraction)
        }
        .buttonStyle(TouchDownButtonStyle { shows.warmTouched(entry, next: next) })
        .accessibilityElement(children: .combine)
        .accessibilityHint(next?.resumeAt != nil ? "Resumes" : "Plays")
        .contextMenu {
            Button(action: onPlay) { Label(next?.resumeAt != nil ? "Resume" : "Play", systemImage: "play") }
            Button { model.navigationPath.append(.show(entry.show)) } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button(role: .destructive) { shows.removeFromContinueWatching(entry.show) } label: {
                Label("Remove from Continue Watching", systemImage: "minus.circle")
            }
        }
    }

    /// "S1 E5, 12 min left", "Episode 6", or "12 min left" for a movie.
    static func detail(entry: WatchEntry, next: ShowUpNext?, details d: ShowDetails?) -> String? {
        let left = next?.remaining.flatMap(Format.remaining)
        if entry.show.isMovie || d?.show.isMovie == true { return left }
        let label = next.map { ShowsModel.shortLabel(d, season: $0.season.number, episode: $0.episode.number) }
            ?? ShowsModel.shortLabel(d, season: entry.season, episode: entry.episode)
        return left.map { "\(label), \($0)" } ?? label
    }
}

// MARK: - Versions

/// Every release found for an episode, grouped by resolution. Tapping one plays it.
struct VersionsView: View {
    let target: EpisodeTarget
    /// Info hash of the release playing now.
    var current: String? = nil
    /// Picking what to download rather than what to play.
    var forDownload = false
    let onSelect: (EpisodeSource) -> Void

    @EnvironmentObject var shows: ShowsModel
    @Environment(\.dismiss) private var dismiss
    @State private var phase: Phase = .loading

    enum Phase {
        case loading
        case loaded([EpisodeSource])
        case failed(String)
    }

    var body: some View {
        NavigationStack {
            content
                .navigationTitle(forDownload ? "Download a Version" : "Versions")
                .navigationBarTitleDisplayMode(.inline)
                .toolbar {
                    ToolbarItem(placement: .cancellationAction) {
                        Button(role: .close) { dismiss() }
                    }
                }
                .task { await load() }
        }
        .presentationDetents([.medium, .large])
    }

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Find Versions", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { Task { await load(refresh: true) } }
                    .buttonStyle(.bordered)
            }
        case .loaded(let list) where list.isEmpty:
            ContentUnavailableView("No Versions Available", systemImage: "film.stack",
                                   description: Text("No one is sharing this episode right now."))
        case .loaded(let list):
            List {
                Section {
                    row(list[0])
                } header: {
                    Text(heading)
                } footer: {
                    Text(forDownload ? "Tap a version to download it. It replaces any download of this episode."
                                     : "Picked for you from the fastest versions. The one you tap plays next time.")
                }
                ForEach(groups(Array(list.dropFirst())), id: \.title) { group in
                    Section(group.title) {
                        ForEach(group.sources) { row($0) }
                    }
                }
            }
        }
    }

    private var heading: String {
        let d = target.details
        if d.show.isMovie { return "Best Match" }
        return "\(ShowsModel.episodeLabel(d, target.season, target.episode)), Best Match"
    }

    private func groups(_ list: [EpisodeSource]) -> [(title: String, sources: [EpisodeSource])] {
        let order: [(String, (Int?) -> Bool)] = [
            ("4K", { ($0 ?? 0) >= 2160 }),
            ("1080p", { $0 == 1080 }),
            ("720p", { $0 == 720 }),
            ("480p", { ($0 ?? 0) > 0 && ($0 ?? 0) < 720 }),
            ("Other", { $0 == nil }),
        ]
        return order.compactMap { title, test in
            let matching = list.filter { test($0.traits.resolution) }
            return matching.isEmpty ? nil : (title, matching)
        }
    }

    private func row(_ s: EpisodeSource) -> some View {
        Button {
            onSelect(s)
        } label: {
            HStack(alignment: .top, spacing: Space.m) {
                VStack(alignment: .leading, spacing: Space.xs) {
                    HStack(spacing: Space.s) {
                        Text(s.group ?? "Unknown Group")
                            .font(.body.weight(.semibold))
                        if let r = s.traits.resolutionLabel { QualityBadge(resolution: r == "4K" ? "2160p" : r) }
                    }
                    if !s.traits.labels.isEmpty {
                        Text(s.traits.labels.joined(separator: ", "))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                    }
                    HStack(spacing: Space.m) {
                        AvailabilityLabel(seeders: s.result.seeders)
                        Text(Format.bytes(s.result.size))
                        if s.isBatch { Text("Full Season") }
                    }
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()
                }
                Spacer(minLength: Space.s)
                if s.result.infoHash == current {
                    Image(systemName: "checkmark")
                        .font(.body.weight(.semibold))
                        .foregroundStyle(.tint)
                        .accessibilityLabel(forDownload ? "Downloaded" : "Playing")
                }
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if let magnet = s.result.magnet {
                Button { UIPasteboard.general.string = magnet } label: { Label("Copy Magnet Link", systemImage: "link") }
            }
            Link(destination: s.result.pageURL) { Label("Open on Nyaa", systemImage: "safari") }
        } preview: {
            Text(s.result.title)
                .font(.subheadline)
                .padding(Space.l)
                .frame(width: 320, alignment: .leading)
        }
    }

    private func load(refresh: Bool = false) async {
        if case .loaded = phase, !refresh { return }
        phase = .loading
        do {
            phase = .loaded(try await shows.sources(target.details, target.season, target.episode, refresh: refresh))
        } catch {
            phase = .failed(PlaybackLauncher.message(for: error))
        }
    }
}

// MARK: - Starting playback

/// Full-screen stand-in while an episode's release is found and opened, then the player itself.
struct PlaybackLauncher: View {
    let launch: EpisodeLaunch
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var request: PlaybackRequest?
    @State private var status = "Loading"
    @State private var failure: String?
    @State private var target: EpisodeTarget?
    @State private var choosing: EpisodeTarget?
    @State private var chosen: EpisodeSource?
    @State private var attempt = 0

    var body: some View {
        Group {
            if let request {
                PlayerScreen(request: request)
            } else {
                waiting
            }
        }
        .task(id: attempt) { await start() }
    }

    private var waiting: some View {
        GeometryReader { geo in
            let compact = geo.size.width < PlayerMetrics.compactWidth
            ZStack {
                // The same still the player holds until its first frame, in the same place, so opening is one
                // continuous picture rather than a page, then black, then video.
                PlaybackPoster(stillURL: target?.episode.thumbnailURL, posterURL: target?.details.show.posterURL ?? launch.show.posterURL)

                if let failure {
                    failurePanel(failure)
                        .padding(Space.xl)
                        .frame(maxWidth: 420)
                        .background(.black.opacity(0.55), in: .rect(cornerRadius: Radius.medium))
                        .transition(.opacity)
                } else {
                    // Most episodes open within a beat; only a longer wait says what it's doing.
                    AfterDelay(delay: 0.4) {
                        VStack(spacing: Space.s) {
                            ProgressView().controlSize(.large).tint(.white)
                            Text(status)
                                .font(.footnote)
                                .foregroundStyle(.white.opacity(0.8))
                                .contentTransition(.opacity)
                        }
                        .shadow(color: .black.opacity(0.4), radius: PlayerMetrics.glyphShadow)
                        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: status)
                        .accessibilityElement(children: .combine)
                    }
                    .id(attempt)
                }

                VStack(alignment: .leading, spacing: 0) {
                    PlayerIconButton(systemImage: "xmark", label: "Close") { dismiss() }
                    Spacer(minLength: 0)
                    titleBlock
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.horizontal, compact ? Space.l : PlayerMetrics.wideMargin)
                .padding(.vertical, Space.s)
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .preferredColorScheme(.dark)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: failure)
        .sheet(item: $choosing) { t in
            VersionsView(target: t) { source in
                choosing = nil
                chosen = source
                attempt += 1
            }
        }
    }

    /// Where the player's title will be: the show over the episode.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if let label = episodeLabel {
                Text(target?.details.show.title ?? launch.show.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(label)
                    .font(.headline)
            } else {
                Text(target?.details.show.title ?? launch.show.title)
                    .font(.headline)
            }
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.4), radius: PlayerMetrics.glyphShadow)
        .accessibilityElement(children: .combine)
        .padding(.bottom, Space.l)
    }

    private var episodeLabel: String? {
        guard let t = target, !t.details.show.isMovie else { return nil }
        let label = ShowsModel.episodeLabel(t.details, t.season, t.episode)
        return t.episode.title.map { "\(label): \($0)" } ?? label
    }

    private func failurePanel(_ message: String) -> some View {
        VStack(spacing: Space.m) {
            Text(message)
                .font(.subheadline)
                .multilineTextAlignment(.center)
            VStack(spacing: Space.s) {
                if let target, target.episode.isAired {
                    Button { choosing = target } label: {
                        Text("Choose Another Version").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button { chosen = nil; attempt += 1 } label: {
                    Text("Try Again").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(.top, Space.s)
    }

    private func start() async {
        failure = nil
        status = "Loading"
        // Warm-ups being let go wait while this opens, so its torrent isn't paused under it.
        shows.launchBegan()
        defer { shows.launchEnded() }
        PlaybackEngine.prepareLibrary()
        let trace = PlaybackTrace.shared
        trace.begin("Play \(launch.show.title)" + (launch.episode.map { " episode \($0)" } ?? ""))
        do {
            let d = try await launchDetails()
            trace.mark("details loaded")
            let t = try pick(d)
            target = t
            let req = try await shows.request(d, t.season, t.episode, source: chosen ?? launch.source, resumeAt: nil) {
                status = $0
                trace.mark("status: \($0)")
            }
            guard !Task.isCancelled else { return }
            trace.mark("player opening")
            request = req
        } catch {
            guard !Task.isCancelled else { return }
            trace.mark("failed: \(error.localizedDescription)")
            failure = Self.message(for: error)
        }
    }

    /// The show's episodes. A copy on disk that has the chosen episode starts it without waiting on the catalog,
    /// even when newer episodes have aired since; it is brought up to date alongside.
    private func launchDetails() async throws -> ShowDetails {
        if let id = launch.seasonID, let number = launch.episode, let d = shows.cachedDetails(launch.show),
           d.season(id: id)?.episodes.contains(where: { $0.number == number && $0.isAired }) == true {
            if ShowsModel.hasAiredSinceFetch(d) { shows.refreshDetails(launch.show) }
            return d
        }
        return try await shows.loadDetails(launch.show)
    }

    private func pick(_ d: ShowDetails) throws -> EpisodeTarget {
        if let id = launch.seasonID, let s = d.season(id: id),
           let e = s.episodes.first(where: { $0.number == launch.episode }) {
            return EpisodeTarget(details: d, season: s, episode: e)
        }
        guard let next = shows.upNext(d) else { throw ShowError.notAired }
        return EpisodeTarget(details: d, season: next.season, episode: next.episode)
    }

    static func message(for error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You’re offline."
            case .timedOut: return "The server took too long to respond."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
                return "Nyaa can’t be reached from this network. You can set a mirror in Settings."
            default: break
            }
        }
        return error.localizedDescription
    }
}
