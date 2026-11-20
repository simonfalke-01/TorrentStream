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
    @ObservedObject private var keeper = BackgroundKeeper.shared
    @State private var showAdd = false
    @State private var showSettings = false
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?
    @State private var playing: PlaybackRequest?
    @State private var launch: EpisodeLaunch?

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
            .sheet(isPresented: $showAdd) { AddLinkView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
            .fullScreenCover(item: $launch) { PlaybackLauncher(launch: $0) }
            .exportSheet($export)
            .removeTitleDialog(item: $pendingRemoval, export: $export)
        }
    }

    private func load(force: Bool = false) async {
        await shows.loadRows(force: force)
        // Continue Watching needs each started show's episodes to know what plays next.
        for h in shows.history.prefix(10) {
            _ = try? await shows.loadDetails(h.show)
        }
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

    private var content: some View {
        let continuing = continuing
        let listCount = shows.myList.count + model.items.count

        return ScrollView {
            VStack(alignment: .leading, spacing: Space.xxl) {
                if keeper.isActive {
                    ExternalStreamBanner(keeper: keeper)
                        .padding(.horizontal, Space.l)
                }

                hero(continuing.first)
                    .frame(maxWidth: Metrics.heroMaxWidth)
                    .padding(.horizontal, Space.l)
                    .frame(maxWidth: .infinity)

                if !continuing.isEmpty {
                    Shelf(title: "Continue Watching") {
                        ForEach(continuing) { continueCard($0) }
                    }
                }

                if listCount > 0 {
                    Shelf(title: "My List", seeAll: listCount > shelfLimit ? .myList : nil) {
                        ForEach(shows.myList.prefix(shelfLimit)) { show in
                            ShowPosterCard(show: show) { launch = EpisodeLaunch(show: show) }
                                .frame(width: Metrics.shelfPoster.width)
                        }
                        ForEach(model.items.prefix(max(0, shelfLimit - shows.myList.count))) { item in
                            PosterCard(item: item, onPlay: { play(item) }, onRemove: { pendingRemoval = item })
                                .frame(width: Metrics.shelfPoster.width)
                        }
                    }
                }

                ForEach(shows.rows) { row in
                    Shelf(title: row.title) {
                        ForEach(row.shows) { show in
                            ShowPosterCard(show: show) { launch = EpisodeLaunch(show: show) }
                                .frame(width: Metrics.shelfPoster.width)
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
    private func hero(_ first: ContinueItem?) -> some View {
        switch first {
        case .show(let entry, let next):
            HeroCard(posterURL: entry.show.posterURL, title: entry.show.title,
                     caption: ShowContinueCard.detail(entry: entry, next: next, details: shows.details[entry.show.id]),
                     playTitle: next?.resumeAt != nil ? "Resume" : "Play",
                     details: .show(entry.show)) {
                launch = EpisodeLaunch(show: entry.show, seasonID: next?.season.id, episode: next?.episode.number)
            }
        case .link(let c, _):
            HeroCard(posterURL: model.posterURL(c.item), title: model.displayTitle(c.item),
                     caption: linkCaption(c.item, c.next),
                     playTitle: c.next.resumeAt != nil ? "Resume" : "Play",
                     isLoading: c.item.status.phase == .fetchingMetadata,
                     details: .title(c.item.id)) {
                play(c.item, file: c.next.file)
            }
        case nil:
            if let show = shows.rows.first?.shows.first {
                HeroCard(posterURL: show.posterURL, title: show.title,
                         caption: show.genres.isEmpty ? nil : show.genres.prefix(3).joined(separator: ", "),
                         playTitle: "Play", canPlay: !show.isUpcoming, details: .show(show)) {
                    launch = EpisodeLaunch(show: show)
                }
            }
        }
    }

    private func linkCaption(_ item: LibraryItem, _ next: UpNext) -> String? {
        guard let remaining = next.remaining, let left = Format.remaining(remaining) else { return nil }
        guard model.playlist(item.status).count > 1 else { return left }
        return "\(model.episodeLabel(next.file) ?? next.file.title), \(left)"
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
    var seeAll: Route? = nil
    @ViewBuilder let content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .firstTextBaseline) {
                Text(title)
                    .font(.title3.bold())
                    .accessibilityAddTraits(.isHeader)
                Spacer(minLength: Space.s)
                if let seeAll {
                    NavigationLink("See All", value: seeAll)
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

/// The title to watch now: a large poster with Play and Details.
struct HeroCard: View {
    @EnvironmentObject var model: AppModel
    let posterURL: URL?
    let title: String
    let caption: String?
    let playTitle: String
    var isLoading = false
    var canPlay = true
    let details: Route
    let onPlay: () -> Void

    var body: some View {
        PosterImage(url: posterURL, title: title, showsTitle: false, cornerRadius: Radius.large)
            .aspectRatio(2 / 3, contentMode: .fit)
            .overlay {
                if isLoading { ProgressView().controlSize(.large) }
            }
            .overlay(alignment: .bottom) {
                VStack(spacing: Space.m) {
                    Text(title)
                        .font(.title2.bold())
                        .multilineTextAlignment(.center)
                        .lineLimit(3)
                        .accessibilityAddTraits(.isHeader)
                    if let caption {
                        Text(caption)
                            .font(.subheadline)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                    HStack(spacing: Space.m) {
                        Button(action: onPlay) {
                            Label(playTitle, systemImage: "play.fill")
                        }
                        .buttonStyle(PrimaryPlayButtonStyle(fullWidth: false))
                        .disabled(!canPlay)

                        NavigationLink(value: details) {
                            Label("Details", systemImage: "info.circle")
                                .frame(minHeight: Metrics.playButtonHeight - Space.l)
                        }
                        .buttonStyle(.glass)
                        .controlSize(.large)
                    }
                }
                .foregroundStyle(.white)
                .padding(.horizontal, Space.l)
                .padding(.top, Space.xxl * 3)
                .padding(.bottom, Space.xl)
                .frame(maxWidth: .infinity)
                .background {
                    // Legibility scrim for the title and buttons over artwork.
                    LinearGradient(colors: [.clear, .black.opacity(0.8)], startPoint: .top, endPoint: .bottom)
                }
            }
            .clipShape(.rect(cornerRadius: Radius.large, style: .continuous))
            .contentShape(.rect(cornerRadius: Radius.large, style: .continuous))
            .onTapGesture { model.navigationPath.append(details) }
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
        let title = model.displayTitle(item)
        let fraction = model.watchedFraction(torrent: item.torrent, file: next.file)

        Button(action: onPlay) {
            VStack(alignment: .leading, spacing: Space.s) {
                PosterImage(url: model.backdropURL(item) ?? model.posterURL(item), title: title,
                            cornerRadius: Radius.medium)
                    .frame(width: Metrics.wideCardWidth, height: Metrics.wideCardWidth * 9 / 16)
                    .overlay {
                        Image(systemName: "play.fill")
                            .font(.title3)
                            .foregroundStyle(.white)
                            .frame(width: Metrics.touchTarget + Space.s, height: Metrics.touchTarget + Space.s)
                            .glassEffect(.clear, in: .circle)
                    }
                WatchedBar(fraction: fraction ?? 0)
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
            .frame(width: Metrics.wideCardWidth, alignment: .leading)
            .contentShape(.rect)
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
    private var detail: String {
        let isSeries = model.playlist(item.status).count > 1
        let left = next.remaining.flatMap(Format.remaining)
        if isSeries {
            let label = model.episodeLabel(next.file) ?? next.file.title
            return left.map { "\(label), \($0)" } ?? label
        }
        return left ?? "Start watching"
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

/// Every show and title in My List.
struct MyListView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?
    @State private var playing: PlaybackRequest?
    @State private var launch: EpisodeLaunch?

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: Space.m, alignment: .top)]

    var body: some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Space.l) {
                ForEach(shows.myList) { show in
                    ShowPosterCard(show: show) { launch = EpisodeLaunch(show: show) }
                }
                ForEach(model.items) { item in
                    PosterCard(item: item, onPlay: { play(item) }, onRemove: { pendingRemoval = item })
                }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .overlay {
            if shows.myList.isEmpty && model.items.isEmpty {
                ContentUnavailableView("My List Is Empty", systemImage: "plus.square.on.square",
                                       description: Text("Add shows from their page to find them here."))
            }
        }
        .navigationTitle("My List")
        .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
        .fullScreenCover(item: $launch) { PlaybackLauncher(launch: $0) }
        .exportSheet($export)
        .removeTitleDialog(item: $pendingRemoval, export: $export)
    }

    private func play(_ item: LibraryItem) {
        guard let next = model.upNext(item) else { return }
        playing = model.playbackRequest(torrent: item.torrent, file: next.file)
    }
}

/// Shown while TorrentStream keeps a stream running for the VLC app.
struct ExternalStreamBanner: View {
    @ObservedObject var keeper: BackgroundKeeper

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "arrow.up.forward.app")
                .font(.title3)
                .foregroundStyle(.tint)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Playing in VLC")
                    .font(.headline)
                Text("The stream keeps running in the background.")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Button("Stop") { keeper.stop() }
                .buttonStyle(.bordered)
        }
        .padding(Space.m)
        .background(.fill.quaternary, in: .rect(cornerRadius: Radius.medium, style: .continuous))
        .accessibilityElement(children: .combine)
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
