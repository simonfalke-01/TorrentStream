import SwiftUI
import UniformTypeIdentifiers
import TorrentKit

extension UTType {
    static let torrent = UTType(importedAs: "org.bittorrent.torrent")
}

struct LibraryView: View {
    @EnvironmentObject var model: AppModel
    @ObservedObject private var keeper = BackgroundKeeper.shared
    @State private var showAdd = false
    @State private var search = ""
    @State private var pendingRemoval: LibraryItem?
    @State private var export: ExportItem?

    private var filtered: [LibraryItem] {
        let q = search.trimmingCharacters(in: .whitespaces)
        guard !q.isEmpty else { return model.items }
        return model.items.filter { $0.status.name.localizedCaseInsensitiveContains(q) }
    }

    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            List {
                if keeper.isActive {
                    Section { ExternalStreamRow(keeper: keeper) }
                }
                Section {
                    ForEach(filtered) { item in
                        NavigationLink(value: Route.torrent(item.id)) {
                            TorrentRow(item: item, artwork: model.artworkURL(item))
                        }
                        .swipeActions(edge: .trailing) {
                            Button(role: .destructive) { pendingRemoval = item } label: {
                                Label("Remove", systemImage: "trash")
                            }
                            if item.status.phase == .ready && !item.status.isComplete {
                                Button { model.togglePause(item.torrent) } label: {
                                    item.status.isPaused
                                        ? Label("Resume", systemImage: "play")
                                        : Label("Pause", systemImage: "pause")
                                }
                            }
                        }
                        .contextMenu {
                            TorrentActionsMenu(item: item, onRemove: { pendingRemoval = item })
                        }
                    }
                }
            }
            .listStyle(.plain)
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView {
                        Label("No Torrents", systemImage: "play.rectangle.on.rectangle")
                    } description: {
                        Text("Search Nyaa, or add a magnet link or .torrent file.")
                    } actions: {
                        Button("Search Nyaa") { model.selectedTab = .search }
                            .buttonStyle(.borderedProminent)
                        Button("Add Magnet Link or File") { showAdd = true }
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Filter Library")
            .navigationTitle("Library")
            .routeDestinations()
            .toolbar {
                ToolbarItem(placement: .primaryAction) {
                    Button { showAdd = true } label: { Label("Add Torrent", systemImage: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTorrentView() }
            .exportSheet($export)
            .removeTorrentDialog(item: $pendingRemoval, export: $export)
        }
    }
}

/// Shown while TorrentStream keeps serving a stream to the VLC app from the background.
struct ExternalStreamRow: View {
    @ObservedObject var keeper: BackgroundKeeper

    var body: some View {
        HStack(spacing: Space.m) {
            Image(systemName: "arrow.up.forward.app")
                .font(.title3)
                .foregroundStyle(.tint)
                .frame(width: Metrics.rowIcon)
                .accessibilityHidden(true)
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Streaming to VLC")
                    .font(.body.weight(.semibold))
                Text("Keeps running in the background")
                    .font(.subheadline)
                    .foregroundStyle(.secondary)
            }
            Spacer(minLength: Space.s)
            Button("Stop") { keeper.stop() }
                .buttonStyle(.bordered)
        }
        .accessibilityElement(children: .combine)
    }
}

struct TorrentRow: View {
    let item: LibraryItem
    let artwork: URL?

    var body: some View {
        let s = item.status
        HStack(spacing: Space.m) {
            ArtworkView(url: artwork, symbol: "film")
                .frame(width: Metrics.rowArtwork.width, height: Metrics.rowArtwork.height)
            VStack(alignment: .leading, spacing: Space.xs) {
                Text(s.name)
                    .font(.body.weight(.semibold))
                    .lineLimit(2)
                statusLine(s)
                if s.showsProgress {
                    ProgressView(value: s.progress)
                        .tint(s.isPaused ? .secondary : .accentColor)
                        .accessibilityHidden(true)
                }
            }
        }
        .padding(.vertical, Space.xs)
        .accessibilityElement(children: .combine)
    }

    @ViewBuilder
    private func statusLine(_ s: TorrentStatus) -> some View {
        if case .failed = s.phase {
            Label(s.summaryText, systemImage: "exclamationmark.triangle.fill")
                .font(.subheadline)
                .foregroundStyle(.red)
        } else {
            Text(s.summaryText)
                .font(.subheadline)
                .foregroundStyle(.secondary)
                .monospacedDigit()
        }
    }
}

/// Torrent-level actions, shared by the row context menu and the detail toolbar.
struct TorrentActionsMenu: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let onRemove: () -> Void

    var body: some View {
        let s = item.status
        if s.phase == .ready && !s.isComplete {
            Section {
                Button { model.togglePause(item.torrent) } label: {
                    s.isPaused ? Label("Resume", systemImage: "play") : Label("Pause", systemImage: "pause")
                }
                if s.files.contains(where: { !$0.isComplete && !$0.wanted && !$0.file.isPadding }) {
                    Button { model.downloadAll(item.torrent) } label: {
                        Label("Download All Files", systemImage: "arrow.down.circle")
                    }
                }
                if s.hasActiveDownloads {
                    Button { model.stopAllDownloads(item.torrent) } label: {
                        Label("Stop All Downloads", systemImage: "stop.circle")
                    }
                }
            }
        }
        Section {
            Button { model.copyMagnet(item.torrent) } label: { Label("Copy Magnet Link", systemImage: "link") }
            ShareLink(item: item.torrent.magnetLink) { Label("Share Magnet Link", systemImage: "square.and.arrow.up") }
        }
        Section {
            Button(role: .destructive, action: onRemove) { Label("Remove", systemImage: "trash") }
        }
    }
}

extension View {
    /// Confirms removing a torrent and offers to save finished files first.
    func removeTorrentDialog(item: Binding<LibraryItem?>, export: Binding<ExportItem?>) -> some View {
        modifier(RemoveTorrentDialog(item: item, export: export))
    }
}

private struct RemoveTorrentDialog: ViewModifier {
    @EnvironmentObject var model: AppModel
    @Binding var item: LibraryItem?
    @Binding var export: ExportItem?

    func body(content: Content) -> some View {
        let saved = item.map { model.completedMediaURLs($0) } ?? []
        content.confirmationDialog(
            "Remove “\(item?.status.name ?? "")”?",
            isPresented: Binding(get: { item != nil }, set: { if !$0 { item = nil } }),
            titleVisibility: .visible,
            presenting: item
        ) { it in
            if !saved.isEmpty {
                Button(saved.count == 1 ? "Save Downloaded File…" : "Save \(saved.count) Downloaded Files…") {
                    export = ExportItem(urls: saved)
                }
            }
            Button("Remove and Delete Files", role: .destructive) { model.remove(it.torrent) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            Text(saved.isEmpty
                 ? "Its downloaded data will be deleted from this iPhone."
                 : "Its downloaded data will be deleted from this iPhone. Save finished files to Files to keep them.")
        }
    }
}

struct AddTorrentView: View {
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
                        Label("This isn't a valid magnet link.", systemImage: "exclamationmark.circle")
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
            .navigationTitle("Add Torrent")
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
