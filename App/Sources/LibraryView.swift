import SwiftUI
import TorrentKit
import CatalogKit

/// The Library tab: what the viewer saved, and what they watched.
struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @EnvironmentObject var downloads: DownloadsModel
    @AppStorage("librarySort") private var sort = LibrarySort.added.rawValue
    @State private var pane = Pane.list
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?
    @State private var playing: PlaybackRequest?
    @State private var launch: EpisodeLaunch?

    enum Pane: Hashable { case list, downloads, history }

    enum LibrarySort: String, CaseIterable, Identifiable {
        case added, watched, title
        var id: String { rawValue }
        var title: String {
            switch self {
            case .added: return "Recently Added"
            case .watched: return "Recently Watched"
            case .title: return "Title"
            }
        }
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: Space.m, alignment: .top)]

    var body: some View {
        NavigationStack(path: $model.listPath) {
            Group {
                switch pane {
                case .list: listContent
                case .downloads: downloadsContent
                case .history: historyContent
                }
            }
            .navigationTitle("Library")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .principal) {
                    Picker("Library", selection: $pane) {
                        Text("My List").tag(Pane.list)
                        Text("Downloads").tag(Pane.downloads)
                        Text("History").tag(Pane.history)
                    }
                    .pickerStyle(.segmented)
                    .fixedSize()
                }
                if pane == .list {
                    ToolbarItem(placement: .topBarTrailing) {
                        Menu {
                            Picker("Sort By", selection: $sort) {
                                ForEach(LibrarySort.allCases) { Text($0.title).tag($0.rawValue) }
                            }
                        } label: {
                            Label("Sort", systemImage: "arrow.up.arrow.down")
                        }
                    }
                }
            }
            .routeDestinations()
            .task {
                // "New Episode" needs each saved show's episodes.
                shows.refreshMyList()
            }
            .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
            .fullScreenCover(item: $launch) { PlaybackLauncher(launch: $0) }
            .exportSheet($export)
            .removeTitleDialog(item: $pendingRemoval, export: $export)
        }
    }

    // MARK: My List

    private var sortedShows: [Show] {
        let list = shows.myList
        switch LibrarySort(rawValue: sort) ?? .added {
        case .added:
            return list.enumerated().sorted { a, b in
                let da = shows.addedAt[a.element.id], db = shows.addedAt[b.element.id]
                if let da, let db, da != db { return da > db }
                return a.offset < b.offset
            }.map(\.element)
        case .watched:
            let order = Dictionary(shows.history.enumerated().map { ($0.element.show.id, $0.offset) }, uniquingKeysWith: min)
            return list.enumerated().sorted { a, b in
                let oa = order[shows.rootID(a.element)] ?? .max, ob = order[shows.rootID(b.element)] ?? .max
                return oa != ob ? oa < ob : a.offset < b.offset
            }.map(\.element)
        case .title:
            return list.sorted { $0.title.localizedStandardCompare($1.title) == .orderedAscending }
        }
    }

    @ViewBuilder
    private var listContent: some View {
        if shows.myList.isEmpty && model.items.isEmpty {
            ContentUnavailableView("Nothing Saved Yet", systemImage: "plus.square.on.square",
                                   description: Text("Tap + on a show to keep it here."))
        } else {
            ScrollView {
                LazyVGrid(columns: columns, spacing: Space.l) {
                    ForEach(sortedShows) { show in
                        ShowPosterCard(show: show, note: shows.hasNewEpisode(show) ? "New Episode" : nil) {
                            launch = EpisodeLaunch(show: show)
                        }
                    }
                    ForEach(model.items) { item in
                        PosterCard(item: item, onPlay: { play(item) }, onRemove: { pendingRemoval = item })
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
            }
        }
    }

    // MARK: Downloads

    private var downloadsContent: some View { DownloadsPane() }

    // MARK: History

    @ViewBuilder
    private var historyContent: some View {
        if shows.history.isEmpty {
            ContentUnavailableView("No History", systemImage: "clock",
                                   description: Text("Shows you watch appear here."))
        } else {
            List {
                ForEach(shows.history) { entry in
                    NavigationLink(value: Route.show(entry.show)) {
                        HistoryRow(entry: entry)
                    }
                    .swipeActions {
                        Button(role: .destructive) { shows.removeFromContinueWatching(entry.show) } label: {
                            Label("Remove", systemImage: "trash")
                        }
                    }
                    .contextMenu {
                        Button {
                            launch = EpisodeLaunch(show: entry.show, seasonID: entry.seasonID, episode: entry.episode)
                        } label: { Label("Play", systemImage: "play") }
                        Button(role: .destructive) { shows.removeFromContinueWatching(entry.show) } label: {
                            Label("Remove from History", systemImage: "minus.circle")
                        }
                    }
                }
            }
            .listStyle(.plain)
        }
    }

    private func play(_ item: LibraryItem) {
        guard let next = model.upNext(item) else { return }
        playing = model.playbackRequest(torrent: item.torrent, file: next.file)
    }
}

/// The last episode watched of a show: its still, the show, which episode and when.
private struct HistoryRow: View {
    @EnvironmentObject var shows: ShowsModel
    let entry: WatchEntry

    private let thumbWidth: CGFloat = 112

    var body: some View {
        let d = shows.details[entry.show.id]
        let season = d?.season(id: entry.seasonID)
        let episode = season?.episodes.first { $0.number == entry.episode }
        let fraction = shows.progress[ShowsModel.key(entry.show.id, entry.seasonID, entry.episode)]?.fraction
        let isMovie = entry.show.isMovie || d?.show.isMovie == true

        HStack(spacing: Space.m) {
            VStack(spacing: Space.xs) {
                PosterImage(url: episode?.thumbnailURL ?? entry.show.bannerURL ?? entry.show.posterURL,
                            title: entry.show.title, showsTitle: false, cornerRadius: Radius.small)
                    .frame(width: thumbWidth, height: thumbWidth * 9 / 16)
                if let fraction, fraction > 0.02, fraction < 0.9 {
                    WatchedBar(fraction: fraction)
                        .frame(width: thumbWidth)
                }
            }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(d?.show.title ?? entry.show.title)
                    .font(.body.weight(.medium))
                    .lineLimit(2)
                if !isMovie {
                    Text(ShowsModel.shortLabel(d, season: entry.season, episode: entry.episode))
                        .font(.subheadline)
                        .foregroundStyle(.secondary)
                }
                Text(entry.watchedAt, format: .relative(presentation: .named))
                    .font(.footnote)
                    .foregroundStyle(.tertiary)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }
}
