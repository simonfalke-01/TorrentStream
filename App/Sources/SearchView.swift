import SwiftUI
import NyaaKit
import TorrentKit
import CatalogKit

// MARK: - Vocabulary

extension NyaaSort {
    /// Sorts offered in the menu. Leechers and comments say nothing about watching, so they're left out.
    static let visible: [NyaaSort] = [.date, .seeders, .downloads, .size]

    var title: String {
        switch self {
        case .date: return "Upload Date"
        case .seeders, .leechers: return "Availability"
        case .downloads, .comments: return "Popularity"
        case .size: return "Size"
        }
    }

    func orderTitle(ascending: Bool) -> String {
        switch self {
        case .date: return ascending ? "Oldest First" : "Newest First"
        case .seeders, .leechers: return ascending ? "Slowest First" : "Fastest First"
        case .downloads, .comments: return ascending ? "Least Popular First" : "Most Popular First"
        case .size: return ascending ? "Smallest First" : "Largest First"
        }
    }
}

extension NyaaFilter {
    var title: String {
        switch self {
        case .all: return "All Uploads"
        case .noRemakes: return "Hide Remakes"
        case .trustedOnly: return "Trusted Only"
        }
    }
}

extension NyaaCategory {
    /// "Anime (English-translated)" for subcategories, the plain title otherwise.
    var displayName: String {
        guard !isBroad, let group = NyaaCategory.groups.first(where: { $0.contains(self) }) else { return title }
        return "\(group[0].title) (\(title))"
    }
}

// MARK: - Model

@MainActor
final class SearchModel: ObservableObject {
    enum Phase: Equatable {
        case idle, loading, loaded
        case failed(String)
    }

    @Published private(set) var phase: Phase = .idle
    @Published private(set) var results: [NyaaResult] = []
    @Published private(set) var hasMore = false
    @Published private(set) var loadingMore = false
    @Published private(set) var loadMoreFailed = false
    @Published private(set) var query: NyaaQuery?
    @Published private(set) var recents: [String]

    private var page = 1
    private var generation = 0
    private var task: Task<Void, Never>?
    private let maxRecents = 8

    init() {
        recents = UserDefaults.standard.stringArray(forKey: SettingsKey.recentSearches) ?? []
    }

    func search(_ q: NyaaQuery, client: NyaaClient) {
        task?.cancel()
        generation += 1
        let gen = generation
        query = q
        page = 1
        results = []
        hasMore = false
        loadingMore = false
        loadMoreFailed = false
        phase = .loading
        remember(q.text)
        task = Task {
            do {
                let p = try await client.search(q, page: 1)
                guard gen == generation else { return }
                results = p.results
                hasMore = p.hasNextPage
                phase = .loaded
            } catch {
                guard gen == generation, !Task.isCancelled else { return }
                phase = .failed(SearchModel.message(for: error))
            }
        }
    }

    /// Fetches the next page. Results already shown are skipped, since new uploads shift pages.
    func loadMore(client: NyaaClient) {
        guard let q = query, hasMore, !loadingMore, phase == .loaded else { return }
        loadingMore = true
        loadMoreFailed = false
        let gen = generation, next = page + 1
        Task {
            do {
                let p = try await client.search(q, page: next)
                guard gen == generation else { return }
                let seen = Set(results.map(\.id))
                results += p.results.filter { !seen.contains($0.id) }
                page = next
                hasMore = p.hasNextPage
            } catch {
                guard gen == generation else { return }
                loadMoreFailed = true
            }
            if gen == generation { loadingMore = false }
        }
    }

    func reset() {
        task?.cancel()
        generation += 1
        query = nil
        results = []
        hasMore = false
        loadingMore = false
        loadMoreFailed = false
        phase = .idle
    }

    // MARK: recent searches

    private func remember(_ text: String) {
        let t = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !t.isEmpty else { return }
        recents.removeAll { $0.caseInsensitiveCompare(t) == .orderedSame }
        recents.insert(t, at: 0)
        recents = Array(recents.prefix(maxRecents))
        saveRecents()
    }

    func forget(at offsets: IndexSet) {
        recents.remove(atOffsets: offsets)
        saveRecents()
    }

    func clearRecents() {
        recents = []
        saveRecents()
    }

    private func saveRecents() {
        UserDefaults.standard.set(recents, forKey: SettingsKey.recentSearches)
    }

    static func message(for error: Error) -> String {
        if let e = error as? URLError {
            switch e.code {
            case .notConnectedToInternet, .networkConnectionLost: return "You’re offline."
            case .timedOut: return "Nyaa took too long to respond."
            case .cannotFindHost, .cannotConnectToHost, .dnsLookupFailed, .secureConnectionFailed:
                return "Nyaa can’t be reached from this network. You can set a mirror in Settings."
            default: break
            }
        }
        return error.localizedDescription
    }
}

// MARK: - Search screen

struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @StateObject private var search = SearchModel()
    @State private var text = ""
    @AppStorage(SettingsKey.searchSort) private var sort: NyaaSort = .seeders
    @AppStorage(SettingsKey.searchAscending) private var ascending = false
    @AppStorage(SettingsKey.searchCategory) private var categoryID = NyaaCategory.all.id
    @AppStorage(SettingsKey.searchFilter) private var filter: NyaaFilter = .all

    private var category: NyaaCategory { NyaaCategory.find(categoryID) }
    private var isFiltered: Bool { category != .all || filter != .all }

    var body: some View {
        NavigationStack(path: $model.searchPath) {
            list
                .overlay { overlay }
                .navigationTitle("Search")
                .searchable(text: $text, prompt: "Shows and Movies")
                .onSubmit(of: .search) { submit() }
                .onAppear {
                    if !NyaaSort.visible.contains(sort) { sort = .seeders }
                }
                .onChange(of: search.results.count) { requestCatalog() }
                .onChange(of: text) { _, new in
                    if new.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty { search.reset() }
                }
                .onChange(of: sort) { rerun() }
                .onChange(of: ascending) { rerun() }
                .onChange(of: categoryID) { rerun() }
                .onChange(of: filter) { rerun() }
                .toolbar {
                    ToolbarItemGroup(placement: .primaryAction) {
                        sortMenu
                        filterMenu
                    }
                }
                .routeDestinations()
        }
    }

    // MARK: content

    private var list: some View {
        List {
            switch search.phase {
            case .idle:
                if !search.recents.isEmpty { recentsSection }
            case .loaded where !search.results.isEmpty:
                Section {
                    ForEach(search.results) { r in
                        resultRow(r)
                            .onAppear { if r.id == search.results.last?.id { search.loadMore(client: model.nyaa) } }
                    }
                    if search.hasMore { loadMoreRow }
                } header: {
                    if isFiltered { Text(filterSummary) }
                }
            default:
                EmptyView()
            }
        }
        .listStyle(.plain)
    }

    @ViewBuilder
    private var overlay: some View {
        switch search.phase {
        case .idle where search.recents.isEmpty:
            ContentUnavailableView {
                Label("Search for shows and movies", systemImage: "magnifyingglass")
            } description: {
                Text("Tap a result to start watching.")
            }
        case .loading:
            ProgressView()
                .controlSize(.large)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Reach Nyaa", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { rerun() }
                    .buttonStyle(.bordered)
            }
        case .loaded where search.results.isEmpty:
            ContentUnavailableView {
                Label("No Results", systemImage: "magnifyingglass")
            } description: {
                Text(isFiltered
                     ? "Nothing matches “\(search.query?.text ?? "")” with the current filters."
                     : "Nothing matches “\(search.query?.text ?? "")”. Check the spelling or try fewer words.")
            } actions: {
                if isFiltered {
                    Button("Clear Filters") {
                        categoryID = NyaaCategory.all.id
                        filter = .all
                    }
                    .buttonStyle(.bordered)
                }
            }
        default:
            EmptyView()
        }
    }

    private var recentsSection: some View {
        Section {
            ForEach(search.recents, id: \.self) { term in
                Button {
                    text = term
                    submit()
                } label: {
                    Label {
                        Text(term).foregroundStyle(.primary)
                    } icon: {
                        Image(systemName: "clock.arrow.circlepath").foregroundStyle(.secondary)
                    }
                }
            }
            .onDelete { search.forget(at: $0) }
        } header: {
            HStack {
                Text("Recent Searches")
                Spacer()
                Button("Clear") { search.clearRecents() }
                    .font(.subheadline)
            }
        }
    }

    private func resultRow(_ r: NyaaResult) -> some View {
        NavigationLink(value: Route.nyaa(r)) {
            SearchResultRow(result: r,
                            release: model.release(r.title),
                            title: model.displayTitle(name: r.title),
                            posterURL: model.entry(name: r.title)?.posterURL,
                            sort: search.query?.sort ?? sort,
                            inMyList: r.infoHash.map { model.item($0) != nil } ?? false)
        }
        .contextMenu {
            if let magnet = r.magnet {
                Button {
                    UIPasteboard.general.string = magnet
                    model.showToast("Magnet link copied", systemImage: "link")
                } label: {
                    Label("Copy Magnet Link", systemImage: "link")
                }
                ShareLink(item: magnet) { Label("Share Magnet Link", systemImage: "square.and.arrow.up") }
            }
            Link(destination: r.pageURL) { Label("Open on Nyaa", systemImage: "safari") }
        }
    }

    private var loadMoreRow: some View {
        Group {
            if search.loadMoreFailed {
                Button("Load More Results") { search.loadMore(client: model.nyaa) }
            } else {
                ProgressView()
                    .onAppear { search.loadMore(client: model.nyaa) }
            }
        }
        .frame(maxWidth: .infinity)
        .listRowSeparator(.hidden)
    }

    // MARK: toolbar

    private var sortMenu: some View {
        Menu {
            Picker("Sort By", selection: $sort) {
                ForEach(NyaaSort.visible) { s in Text(s.title).tag(s) }
            }
            .pickerStyle(.inline)
            Picker("Order", selection: $ascending) {
                Text(sort.orderTitle(ascending: false)).tag(false)
                Text(sort.orderTitle(ascending: true)).tag(true)
            }
            .pickerStyle(.inline)
        } label: {
            Label("Sort", systemImage: "arrow.up.arrow.down")
        }
        .accessibilityValue("\(sort.title), \(sort.orderTitle(ascending: ascending))")
    }

    private var filterMenu: some View {
        Menu {
            Picker(selection: $categoryID) {
                Text(NyaaCategory.all.title).tag(NyaaCategory.all.id)
                ForEach(NyaaCategory.groups, id: \.self) { group in
                    Section(group[0].title) {
                        Text("All \(group[0].title)").tag(group[0].id)
                        ForEach(group.dropFirst()) { c in Text(c.title).tag(c.id) }
                    }
                }
            } label: {
                Label("Category", systemImage: "square.grid.2x2")
                Text(category.displayName)
            }
            .pickerStyle(.menu)
            Picker("Uploads", selection: $filter) {
                ForEach(NyaaFilter.allCases) { f in Text(f.title).tag(f) }
            }
            .pickerStyle(.inline)
            if isFiltered {
                Section {
                    Button("Clear Filters", role: .destructive) {
                        categoryID = NyaaCategory.all.id
                        filter = .all
                    }
                }
            }
        } label: {
            Label("Filter", systemImage: isFiltered ? "line.3.horizontal.decrease.circle.fill" : "line.3.horizontal.decrease")
        }
        .accessibilityValue(isFiltered ? filterSummary : "None")
    }

    private var filterSummary: String {
        var parts: [String] = []
        if category != .all { parts.append(category.displayName) }
        if filter != .all { parts.append(filter.title) }
        return parts.joined(separator: ", ")
    }

    // MARK: actions

    private func submit() {
        let q = text.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !q.isEmpty else { return }
        search.search(NyaaQuery(text: q, category: category, filter: filter, sort: sort, ascending: ascending),
                      client: model.nyaa)
    }

    /// Sorting and filtering happen on the server, so changing them runs the search again from page 1.
    private func rerun() {
        guard search.query != nil else { return }
        submit()
    }

    private func requestCatalog() {
        model.requestCatalog(search.results.compactMap { r in
            model.catalogQuery(name: r.title,
                               prefersAnime: r.category.id.hasPrefix("1_") || model.release(r.title).isAnimeStyle)
        })
    }
}

// MARK: - Result row

/// A result reads like a title: artwork, the show's name, which episode and quality, then how well it will stream.
struct SearchResultRow: View {
    let result: NyaaResult
    let release: ReleaseInfo
    let title: String
    let posterURL: URL?
    let sort: NyaaSort
    let inMyList: Bool

    var body: some View {
        HStack(alignment: .top, spacing: Space.m) {
            PosterImage(url: posterURL, title: title, showsTitle: false)
                .frame(width: Metrics.rowPoster.width, height: Metrics.rowPoster.height)

            VStack(alignment: .leading, spacing: Space.xs) {
                Text(title)
                    .font(.headline)
                    .foregroundStyle(.primary)
                    .lineLimit(2)

                if episodeText != nil || release.resolution != nil {
                    HStack(spacing: Space.s) {
                        if let episodeText { Text(episodeText) }
                        if let res = release.resolution { QualityBadge(resolution: res) }
                    }
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
                }

                if release.group != nil || result.trust != .normal {
                    source
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                }

                details
                    .font(.footnote)
                    .foregroundStyle(.secondary)
                    .monospacedDigit()

                if inMyList {
                    Label("In My List", systemImage: "checkmark")
                        .labelStyle(CompactLabelStyle())
                        .font(.footnote.weight(.medium))
                        .foregroundStyle(.tint)
                }
            }
            .lineLimit(1)
            .frame(maxWidth: .infinity, alignment: .leading)
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .ignore)
        .accessibilityLabel(title)
        .accessibilityValue(accessibilityValue)
    }

    /// "Episode 5", "Episodes 1–12", "Season 2". Nil for a movie or an unparsed name.
    private var episodeText: String? {
        let seasonPrefix = release.season.map { $0 > 1 ? "S\($0) " : "" } ?? ""
        if let first = release.episode, let last = release.lastEpisode, last > first {
            return seasonPrefix.isEmpty ? "Episodes \(first)–\(last)" : "\(seasonPrefix)E\(first)–\(last)"
        }
        if let e = release.episode {
            return seasonPrefix.isEmpty ? "Episode \(e)" : "\(seasonPrefix)E\(e)"
        }
        if let s = release.season { return "Season \(s)" }
        if release.isBatch { return "Multiple Episodes" }
        if let y = release.year { return String(y) }
        return nil
    }

    @ViewBuilder
    private var source: some View {
        HStack(spacing: Space.xs) {
            if let group = release.group { Text(group) }
            switch result.trust {
            case .trusted:
                Image(systemName: "checkmark.seal.fill")
                    .imageScale(.small)
                    .foregroundStyle(.green)
            case .remake:
                Text("Remake").foregroundStyle(.orange)
            case .normal:
                EmptyView()
            }
        }
    }

    private var details: some View {
        HStack(spacing: Space.m) {
            AvailabilityLabel(seeders: result.seeders)
            Text(Format.age(result.date))
            if sort == .size { Text(Format.bytes(result.size)) }
            if sort == .downloads {
                Label(Format.count(result.downloads), systemImage: "person.2")
                    .labelStyle(CompactLabelStyle())
            }
        }
    }

    private var accessibilityValue: String {
        var parts: [String] = []
        if let episodeText { parts.append(episodeText) }
        if let res = release.resolution { parts.append(res == "2160p" ? "4K" : res) }
        if let group = release.group { parts.append("from \(group)") }
        if result.trust == .trusted { parts.append("Trusted uploader") }
        if result.trust == .remake { parts.append("Remake") }
        parts.append(Format.age(result.date))
        if sort == .size { parts.append(Format.bytes(result.size)) }
        if sort == .downloads { parts.append("Popularity \(Format.count(result.downloads))") }
        if inMyList { parts.append("In My List") }
        return parts.joined(separator: ", ")
    }
}

// MARK: - Opening a result

/// Pushed when a result is tapped: fetches the title's file list, adds it to My List, then shows the title page in place.
struct NyaaResultView: View {
    let result: NyaaResult
    @EnvironmentObject var model: AppModel
    @State private var hash: String?
    @State private var failure: String?

    private var existing: String? {
        guard let h = result.infoHash, model.item(h) != nil else { return nil }
        return h
    }

    var body: some View {
        Group {
            if let h = hash ?? existing {
                TitleView(infoHash: h)
            } else if let failure {
                ContentUnavailableView {
                    Label("Couldn’t Open", systemImage: "exclamationmark.triangle")
                } description: {
                    Text(failure)
                } actions: {
                    Button("Try Again") { Task { await load() } }
                        .buttonStyle(.bordered)
                    Link("Open on Nyaa", destination: result.pageURL)
                }
                .navigationBarTitleDisplayMode(.inline)
            } else {
                loading
            }
        }
        .task { await load() }
    }

    private var loading: some View {
        let title = model.displayTitle(name: result.title)
        return VStack(spacing: Space.l) {
            PosterImage(url: model.entry(name: result.title)?.posterURL, title: title,
                        cornerRadius: Radius.medium, titleFont: .headline)
                .frame(width: Metrics.shelfPoster.width, height: Metrics.shelfPoster.height)
            Text(title)
                .font(.title3.weight(.semibold))
                .multilineTextAlignment(.center)
                .lineLimit(2)
            ProgressView()
                .accessibilityLabel("Loading")
        }
        .padding(Space.xl)
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .navigationBarTitleDisplayMode(.inline)
    }

    private func load() async {
        guard hash == nil, existing == nil else { return }
        failure = nil
        do {
            let data = try await model.nyaa.torrentData(for: result)
            if let h = model.addTorrent(data: data, reportErrors: false) { hash = h; return }
        } catch {
            // Fall back to the magnet link below.
        }
        if let magnet = result.magnet, let h = model.addTorrent(magnet: magnet, reportErrors: false) {
            hash = h
            return
        }
        failure = "This title couldn’t be loaded. Check your connection and try again."
    }
}
