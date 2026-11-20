import SwiftUI
import CatalogKit

// MARK: - Search screen

/// Find a show or movie by name. Results are posters; tapping one opens the show.
struct SearchView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @State private var text = ""
    @State private var phase: Phase = .idle
    @State private var launch: EpisodeLaunch?
    @State private var retry = 0
    @AppStorage(SettingsKey.recentSearches) private var recentsData = Data()
    /// Results already fetched this session, so going back and forth costs nothing.
    @State private var cache: [String: [Show]] = [:]

    enum Phase: Equatable {
        case idle
        case loading
        case loaded(query: String, shows: [Show])
        case failed(String)
    }

    private let columns = [GridItem(.adaptive(minimum: 104, maximum: 160), spacing: Space.m, alignment: .top)]
    private var query: String { text.trimmingCharacters(in: .whitespacesAndNewlines) }

    var body: some View {
        NavigationStack(path: $model.searchPath) {
            content
                .navigationTitle("Search")
                .searchable(text: $text, prompt: "Shows and Movies")
                .searchSuggestions { suggestions }
                .onSubmit(of: .search) { remember(query) }
                .onChange(of: model.searchPath.count) { old, new in
                    // Opening a result is what makes a search worth remembering.
                    if new > old, old == 0 { remember(query) }
                }
                .task(id: "\(query)#\(retry)") { await run(query) }
                .task { await shows.loadRows() }
                .fullScreenCover(item: $launch) { PlaybackLauncher(launch: $0) }
                .routeDestinations()
        }
    }

    // MARK: content

    @ViewBuilder
    private var content: some View {
        switch phase {
        case .idle:
            browse
        case .loading:
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        case .failed(let message):
            ContentUnavailableView {
                Label("Can’t Search Right Now", systemImage: "wifi.exclamationmark")
            } description: {
                Text(message)
            } actions: {
                Button("Try Again") { retry += 1 }
                    .buttonStyle(.bordered)
            }
        case .loaded(let q, let list) where list.isEmpty:
            ContentUnavailableView.search(text: q)
        case .loaded(_, let list):
            grid(list, captions: true)
        }
    }

    /// Before typing: what's popular, so there's always something to pick.
    @ViewBuilder
    private var browse: some View {
        if let row = shows.rows.first(where: { $0.id == "popular" }) ?? shows.rows.first {
            ScrollView {
                VStack(alignment: .leading, spacing: Space.m) {
                    Text(row.id == "popular" ? "Popular Shows" : row.title)
                        .font(.title3.bold())
                        .accessibilityAddTraits(.isHeader)
                        .padding(.horizontal, Space.l)
                    LazyVGrid(columns: columns, spacing: Space.l) {
                        ForEach(row.shows) { card($0, captions: false) }
                    }
                    .padding(.horizontal, Space.l)
                }
                .padding(.vertical, Space.s)
            }
        } else if shows.rowsFailed {
            ContentUnavailableView {
                Label("Search for Shows and Movies", systemImage: "magnifyingglass")
            } description: {
                Text("Type a name to find something to watch.")
            }
        } else {
            ProgressView()
                .controlSize(.large)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    private func grid(_ list: [Show], captions: Bool) -> some View {
        ScrollView {
            LazyVGrid(columns: columns, spacing: Space.l) {
                ForEach(list) { card($0, captions: captions) }
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .scrollDismissesKeyboard(.immediately)
    }

    private func card(_ show: Show, captions: Bool) -> some View {
        ShowPosterCard(show: show, showsCaption: captions) {
            remember(query)
            launch = EpisodeLaunch(show: show)
        }
    }

    @ViewBuilder
    private var suggestions: some View {
        if query.isEmpty {
            ForEach(recents, id: \.self) { term in
                Label(term, systemImage: "clock.arrow.circlepath")
                    .searchCompletion(term)
            }
        }
    }

    // MARK: searching

    private func run(_ q: String) async {
        guard q.count >= 2 else {
            phase = .idle
            return
        }
        if let hit = cache[q.lowercased()] {
            phase = .loaded(query: q, shows: hit)
            return
        }
        // Wait for typing to pause; the catalog limits how often it can be asked.
        try? await Task.sleep(for: .milliseconds(400))
        guard !Task.isCancelled else { return }
        if case .loaded = phase {} else { phase = .loading }
        do {
            let found = try await shows.search(q)
            guard !Task.isCancelled else { return }
            cache[q.lowercased()] = found
            phase = .loaded(query: q, shows: found)
        } catch {
            guard !Task.isCancelled else { return }
            phase = .failed(PlaybackLauncher.message(for: error))
        }
    }

    // MARK: recent searches

    private var recents: [String] {
        (try? JSONDecoder().decode([String].self, from: recentsData)) ?? []
    }

    private func remember(_ term: String) {
        guard term.count >= 2 else { return }
        var list = recents.filter { $0.caseInsensitiveCompare(term) != .orderedSame }
        list.insert(term, at: 0)
        recentsData = (try? JSONEncoder().encode(Array(list.prefix(8)))) ?? Data()
    }
}
