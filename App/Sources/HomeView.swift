import SwiftUI
import UniformTypeIdentifiers
import TorrentKit
import CatalogKit

extension UTType {
    static let torrent = UTType(importedAs: "org.bittorrent.torrent")
}

/// A show or a title added by link that the viewer started and didn't finish.
enum ContinueItem: Identifiable {
    case show(WatchEntry, ShowUpNext?)
    case link(ContinueEntry, Date)

    var id: String {
        switch self {
        case .show(let e, _): return "show.\(e.show.id)"
        case .link(let c, _): return "link.\(c.id)"
        }
    }

    var date: Date {
        switch self {
        case .show(let e, _): return e.watchedAt
        case .link(_, let at): return at
        }
    }
}

// MARK: - Home

/// What to watch: the show to pick up, what's been started, My List, then shelves from the catalog.
struct HomeView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?
    @State private var playing: PlaybackRequest?
    @State private var launch: EpisodeLaunch?
    @Environment(\.displayScale) private var displayScale

    /// Shelves show this many posters before offering See All.
    private let shelfLimit = 12

    private var continuing: [ContinueItem] {
        let fromShows = shows.continueWatching.map { ContinueItem.show($0.entry, $0.next) }
        let fromLinks = model.continueWatching.map { ContinueItem.link($0, model.watchedAt($0.item.id) ?? .distantPast) }
        return (fromShows + fromLinks).sorted { $0.date > $1.date }
    }

    private var isEmpty: Bool {
        shows.rows.isEmpty && shows.history.isEmpty && shows.myList.isEmpty && model.items.isEmpty
    }

    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            Group {
                if isEmpty {
                    emptyState
                } else {
                    content
                }
            }
            .navigationTitle("Home")
            .routeDestinations()
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Label("Add by Link", systemImage: "plus") }
                }
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showSettings = true } label: { Label("Settings", systemImage: "gearshape") }
                }
            }
            .task { await load() }
            .onDisappear { shows.stopWarmingHome() }
            .sheet(isPresented: $showAdd) { AddLinkView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $playing, onDismiss: { shows.warmHome() }) { req in PlayerScreen(request: req) }
            .fullScreenCover(item: $launch, onDismiss: { shows.warmHome() }) { PlaybackLauncher(launch: $0) }
            .exportSheet($export)
            .removeTitleDialog(item: $pendingRemoval, export: $export)
        }
    }

    /// Everything on screen comes from disk first; the catalog rows and the started shows' episodes are then
    /// brought up to date together, and what the viewer is likely to open or play next is fetched ahead.
    private func load(force: Bool = false) async {
        let shows = self.shows
        let started = Date()
        PlaybackTrace.shared.launch("home shown (\(shows.rows.count) rows, \(shows.history.count) started on disk)")
        // The front of Continue Watching is the likeliest next play; have it ready.
        shows.warmHome()
        prefetchArtwork()
        async let rows: Void = shows.loadRows(force: force)
        async let startedShows: Void = shows.refreshContinueWatching()
        _ = await (rows, startedShows)
        PlaybackTrace.shared.timing("home rows and Continue Watching up to date", since: started)
        PlaybackTrace.shared.launch("home up to date")
        shows.warmHome()
        prefetchArtwork()
        shows.planContinueWatching()
        // Shows likely to be opened next: the start of My List and of the first shelf.
        var likely: [Show] = shows.myList.prefix(3).map { $0 }
        likely += shows.rows.first?.shows.prefix(4) ?? []
        shows.prefetchDetails(likely)
        await shows.adoptLinkedTitles()
    }

    /// Downloads the hero and Continue Watching artwork, and decodes the posters of the first screen of each
    /// shelf, so they appear on their first frame.
    private func prefetchArtwork() {
        let pipeline = ImagePipeline.shared
        var wide: [URL] = []
        for c in continuing.prefix(6) {
            switch c {
            case .show(let entry, let next):
                if let u = next?.episode.thumbnailURL ?? entry.show.bannerURL ?? entry.show.posterURL { wide.append(u) }
            case .link(let entry, _):
                if let u = model.backdropURL(entry.item) ?? model.posterURL(entry.item) { wide.append(u) }
            }
        }
        if continuing.isEmpty, let show = shows.rows.first?.shows.first, let u = show.bannerURL ?? show.posterURL {
            wide.append(u)
        }
        pipeline.prefetch(wide)
        let poster = CGSize(width: Metrics.shelfPoster.width * displayScale, height: Metrics.shelfPoster.height * displayScale)
        var posters = shows.myList.prefix(4).compactMap(\.posterURL)
        for row in shows.rows { posters += row.shows.prefix(4).compactMap(\.posterURL) }
        pipeline.prefetch(posters, pixels: poster)
    }

    @ViewBuilder
    private var emptyState: some View {
        if shows.rowsFailed {
            ContentUnavailableView {
                Label("Can’t Load Shows", systemImage: "wifi.exclamationmark")
            } description: {
                Text("Check your connection and try again.")
            } actions: {
                Button("Try Again") { Task { await load(force: true) } }
                    .buttonStyle(.borderedProminent)
                Button("Add by Link") { showAdd = true }
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Each show or title appears once above the catalog rows: the hero, then the rest of what's started, then
    /// the rest of My List.
    private var content: some View {
        let continuing = continuing
        let featured = continuing.first
        let started = Array(continuing.dropFirst())
        let shownShows = Set(continuing.compactMap { c -> Int? in if case .show(let e, _) = c { return e.show.id } else { return nil } })
        let shownLinks = Set(continuing.compactMap { c -> String? in if case .link(let e, _) = c { return e.item.id } else { return nil } })
        let listShows = shows.myList.filter { !shownShows.contains(shows.rootID($0)) && !shownShows.contains($0.id) }
        let listItems = model.items.filter { !shownLinks.contains($0.id) }
        let listTotal = shows.myList.count + model.items.count
        let trendingHero = featured == nil ? shows.rows.first?.shows.first : nil

        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                hero(featured, trending: trendingHero)
                    .frame(maxWidth: Metrics.heroMaxWidth)
                    .padding(.horizontal, Space.l)
                    .frame(maxWidth: .infinity)

                if !started.isEmpty {
                    Shelf(title: "Continue Watching") {
                        ForEach(started) { continueCard($0) }
                    }
                }

                if !listShows.isEmpty || !listItems.isEmpty {
                    Shelf(title: "My List", onSeeAll: listTotal > min(shelfLimit, listShows.count + listItems.count)
                          ? { model.selectedTab = .library } : nil) {
                        ForEach(listShows.prefix(shelfLimit)) { show in
                            ShowPosterCard(show: show) { launch = EpisodeLaunch(show: show) }
                                .frame(width: Metrics.shelfPoster.width)
                        }
                        ForEach(listItems.prefix(max(0, shelfLimit - listShows.count))) { item in
                            PosterCard(item: item, onPlay: { play(item) }, onRemove: { pendingRemoval = item })
                                .frame(width: Metrics.shelfPoster.width)
                        }
                    }
                }

                ForEach(shows.rows) { row in
                    let list = row.shows.filter { $0.id != trendingHero?.id }
                    if !list.isEmpty {
                        Shelf(title: row.title) {
                            ForEach(list) { show in
                                ShowPosterCard(show: show) { launch = EpisodeLaunch(show: show) }
                                    .frame(width: Metrics.shelfPoster.width)
                            }
                        }
                    }
                }

                if shows.rows.isEmpty && shows.rowsFailed {
                    VStack(alignment: .leading, spacing: Space.s) {
                        Text("Shows couldn’t be loaded.")
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                        Button("Try Again") { Task { await load(force: true) } }
                            .buttonStyle(.bordered)
                    }
                    .padding(.horizontal, Space.l)
                }
            }
            .padding(.top, Space.s)
            .padding(.bottom, Space.xxl)
        }
        .refreshable { await load(force: true) }
    }

    // MARK: hero

    /// The show to pick up, else the first trending one.
    @ViewBuilder
    private func hero(_ first: ContinueItem?, trending: Show?) -> some View {
        switch first {
        case .show(let entry, let next):
            let d = shows.details[entry.show.id]
            let isMovie = entry.show.isMovie || d?.show.isMovie == true
            let label = next.map { ShowsModel.shortLabel(d, season: $0.season.number, episode: $0.episode.number) }
                ?? ShowsModel.shortLabel(d, season: entry.season, episode: entry.episode)
            let name = next?.episode.title
            HeroCard(imageURL: next?.episode.thumbnailURL ?? entry.show.bannerURL ?? entry.show.posterURL,
                     title: d?.show.title ?? entry.show.title,
                     subtitle: isMovie ? nil : [label, name].compactMap { $0 }.joined(separator: ": "),
                     detail: next?.remaining.flatMap(Format.remaining),
                     progress: next.flatMap { shows.progress(entry.show, $0.season, $0.episode)?.fraction },
                     playTitle: next?.resumeAt != nil ? "Resume" : "Play",
                     details: .show(entry.show)) {
                launch = EpisodeLaunch(show: entry.show, seasonID: next?.season.id, episode: next?.episode.number)
            }
        case .link(let c, _):
            HeroCard(imageURL: model.backdropURL(c.item) ?? model.posterURL(c.item), title: model.displayTitle(c.item),
                     subtitle: model.episodeLabel(c.next.file),
                     detail: c.next.remaining.flatMap(Format.remaining),
                     progress: model.watchedFraction(torrent: c.item.torrent, file: c.next.file),
                     playTitle: c.next.resumeAt != nil ? "Resume" : "Play",
                     isLoading: c.item.status.phase == .fetchingMetadata,
                     details: .title(c.item.id)) {
                play(c.item, file: c.next.file)
            }
        case nil:
            if let show = trending {
                HeroCard(imageURL: show.bannerURL ?? show.posterURL, title: show.title,
                         subtitle: nil,
                         detail: show.genres.isEmpty ? nil : show.genres.prefix(3).joined(separator: ", "),
                         progress: nil,
                         playTitle: "Play", canPlay: !show.isUpcoming, details: .show(show)) {
                    launch = EpisodeLaunch(show: show)
                }
            }
        }
    }

    @ViewBuilder
    private func continueCard(_ c: ContinueItem) -> some View {
        switch c {
        case .show(let entry, let next):
            ShowContinueCard(entry: entry, next: next) {
                launch = EpisodeLaunch(show: entry.show, seasonID: next?.season.id, episode: next?.episode.number)
            }
        case .link(let entry, _):
            ContinueCard(item: entry.item, next: entry.next,
                         onPlay: { play(entry.item, file: entry.next.file) },
                         onRemove: { pendingRemoval = entry.item })
        }
    }

    private func play(_ item: LibraryItem) {
        guard let next = model.upNext(item) else {
            model.navigationPath.append(.title(item.id))
            return
        }
        play(item, file: next.file)
    }

    private func play(_ item: LibraryItem, file: TorrentFile) {
        playing = model.playbackRequest(torrent: item.torrent, file: file)
    }
}

// MARK: - Shelves

/// A titled row of cards that scrolls sideways.
struct Shelf<Content: View>: View {
    let title: String
    var onSeeAll: (() -> Void)? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                if let onSeeAll {
                    Button("See All", action: onSeeAll)
                        .font(.subheadline)
                }
            }
            .padding(.horizontal, Space.l)

            ScrollView(.horizontal) {
                LazyHStack(alignment: .top, spacing: Space.m) { content }
                    .padding(.horizontal, Space.l)
            }
            .scrollIndicators(.hidden)
            .scrollClipDisabled()
        }
    }
}

/// The one thing to watch now: wide artwork with how far along, the title and episode, then Play.
/// Tapping the artwork or title opens the show.
struct HeroCard: View {
    let imageURL: URL?
    let title: String
    /// "S1 E3: The Name".
    let subtitle: String?
    /// "12 min left", or genres for a show not started.
    let detail: String?
    let progress: Double?
    let playTitle: String
    var isLoading = false
    var canPlay = true
    let details: Route
    let onPlay: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.l) {
            NavigationLink(value: details) {
                VStack(alignment: .leading, spacing: Space.m) {
                    PosterImage(url: imageURL, title: title, showsTitle: imageURL == nil, cornerRadius: Radius.medium,
                                titleFont: .title3.weight(.semibold))
                        .aspectRatio(16 / 9, contentMode: .fit)
                        .overlay {
                            if isLoading { ProgressView().controlSize(.large) }
                        }
                        .overlay(alignment: .bottom) {
                            if let progress, progress > 0.02 {
                                WatchedBar(fraction: progress, onArtwork: true)
                                    .padding(Space.m)
                            }
                        }
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(title)
                            .font(.title2.bold())
                            .lineLimit(2)
                            .multilineTextAlignment(.leading)
                            .accessibilityAddTraits(.isHeader)
                        if let subtitle, !subtitle.isEmpty {
                            Text(subtitle)
                                .font(.subheadline.weight(.medium))
                                .lineLimit(1)
                        }
                        if let detail {
                            Text(detail)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                    }
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .accessibilityElement(children: .combine)
            .accessibilityHint("Opens details")

            Button(action: onPlay) {
                Label(playTitle, systemImage: "play.fill")
            }
            .buttonStyle(PrimaryPlayButtonStyle())
            .disabled(!canPlay)
        }
    }
}

/// A started title added by link: wide artwork, watched progress, and what plays next.
struct ContinueCard: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let next: UpNext
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        Button(action: onPlay) {
            ContinueCardLabel(imageURL: model.backdropURL(item) ?? model.posterURL(item), title: model.displayTitle(item),
                              detail: detail, progress: model.watchedFraction(torrent: item.torrent, file: next.file),
                              isLoading: item.status.phase == .fetchingMetadata)
        }
        .buttonStyle(.plain)
        .accessibilityElement(children: .combine)
        .accessibilityHint("Plays")
        .contextMenu {
            Button(action: onPlay) { Label(next.resumeAt != nil ? "Resume" : "Play", systemImage: "play") }
            Button { model.navigationPath.append(.title(item.id)) } label: {
                Label("Details", systemImage: "info.circle")
            }
            Button(role: .destructive, action: onRemove) { Label("Remove from My List", systemImage: "minus.circle") }
        }
    }

    /// "Episode 5, 12 min left", "Episode 6", or "12 min left" for a movie.
    private var detail: String? {
        let left = next.remaining.flatMap(Format.remaining)
        let label = model.episodeLabel(next.file)
            ?? (model.playlist(item.status).count > 1 ? next.file.title : nil)
        let parts = [label, left].compactMap { $0 }
        return parts.isEmpty ? nil : parts.joined(separator: ", ")
    }
}

/// A title added by link in My List. Tap opens the title page.
struct PosterCard: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let onPlay: () -> Void
    let onRemove: () -> Void

    var body: some View {
        let title = model.displayTitle(item)

        NavigationLink(value: Route.title(item.id)) {
            VStack(alignment: .leading, spacing: Space.s) {
                PosterImage(url: model.posterURL(item), title: title)
                    .aspectRatio(2 / 3, contentMode: .fit)
                    .overlay { stateOverlay }
                Text(title)
                    .font(.footnote.weight(.medium))
                    .lineLimit(2, reservesSpace: true)
                    .multilineTextAlignment(.leading)
            }
            .contentShape(.rect)
        }
        .buttonStyle(.plain)
        .contextMenu {
            if model.upNext(item) != nil {
                Button(action: onPlay) { Label("Play", systemImage: "play") }
            }
            Button(role: .destructive, action: onRemove) { Label("Remove from My List", systemImage: "minus.circle") }
        }
    }

    @ViewBuilder
    private var stateOverlay: some View {
        switch item.status.phase {
        case .fetchingMetadata:
            ProgressView()
                .accessibilityLabel("Loading")
        case .failed:
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.title2)
                .foregroundStyle(.yellow)
                .accessibilityLabel("Can’t load this title")
        case .ready:
            EmptyView()
        }
    }
}

// MARK: - Removing

extension View {
    /// Confirms removing a title and offers to save its finished episodes first.
    func removeTitleDialog(item: Binding<LibraryItem?>, export: Binding<ExportItem?>) -> some View {
        modifier(RemoveTitleDialog(item: item, export: export))
    }
}

private struct RemoveTitleDialog: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var item: LibraryItem?
    @Binding var export: ExportItem?

    func body(content: Content) -> some View {
        content.confirmationDialog(
            "Remove “\(item.map { model.displayTitle($0) } ?? "")” from My List?",
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            titleVisibility: .visible,
            presenting: item
        ) { it in
            Button("Remove", role: .destructive) { model.remove(it.torrent) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text("You can add it again with its magnet link or torrent file.")
        }
    }
}

// MARK: - Add by link

struct AddLinkView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var magnet = ""
    @State private var importing = false
    @FocusState private var focused: Bool

    private var trimmed: String { magnet.trimmingCharacters(in: .whitespacesAndNewlines) }
    private var isValid: Bool { (try? TorrentDescriptor.parse(magnet: trimmed)) != nil }
    private var showsInvalid: Bool { !trimmed.isEmpty && !isValid && !focused }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .keyboardType(.URL)
                        .focused($focused)
                        .submitLabel(.done)
                        .onSubmit { focused = false }
                    PasteButton(payloadType: String.self) { strings in
                        if let s = strings.first { magnet = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                    }
                    .labelStyle(.titleAndIcon)
                } header: {
                    Text("Magnet Link")
                } footer: {
                    if showsInvalid {
                        Label("This isn’t a valid magnet link.", systemImage: "exclamationmark.circle")
                            .foregroundStyle(.red)
                    }
                }

                Section {
                    Button { importing = true } label: {
                        Label("Choose Torrent File…", systemImage: "doc")
                    }
                } footer: {
                    Text("Magnet links in Safari and .torrent files in Files open here too.")
                }
            }
            .navigationTitle("Add by Link")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .close) { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button("Add", role: .confirm, action: add)
                        .disabled(!isValid)
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.torrent, .data], allowsMultipleSelection: false) { result in
                switch result {
                case .success(let urls):
                    if let url = urls.first, model.addTorrentFile(at: url) { dismiss() }
                case .failure(let error):
                    model.errorMessage = error.localizedDescription
                }
            }
        }
        .presentationDetents([.medium, .large])
    }

    private func add() {
        guard isValid else { return }
        if model.addMagnet(trimmed) { dismiss() }
    }
}
