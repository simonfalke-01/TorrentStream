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
                    Section { VLCBanner(keeper: keeper) }
                        .listRowBackground(Color.clear)
                        .listRowInsets(EdgeInsets(top: 4, leading: 0, bottom: 4, trailing: 0))
                }
                ForEach(filtered) { item in
                    NavigationLink(value: item.id) {
                        TorrentRow(item: item, artwork: model.artworkURL(item))
                    }
                    .swipeActions(edge: .trailing) {
                        Button(role: .destructive) { pendingRemoval = item } label: { Label("Remove", systemImage: "trash") }
                        if item.status.phase == .ready && !item.status.isComplete {
                            Button { model.togglePause(item.torrent) } label: {
                                item.status.isPaused ? Label("Resume", systemImage: "play.fill") : Label("Pause", systemImage: "pause.fill")
                            }
                            .tint(.orange)
                        }
                    }
                    .contextMenu {
                        TorrentActionsMenu(item: item, onRemove: { pendingRemoval = item })
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if model.items.isEmpty {
                    ContentUnavailableView {
                        Label("Nothing to Watch Yet", systemImage: "play.rectangle.on.rectangle")
                    } description: {
                        Text("Add a magnet link or a .torrent file. Pick a video and it starts playing in seconds, while it downloads.")
                    } actions: {
                        Button { showAdd = true } label: { Label("Add Torrent", systemImage: "plus") }
                            .buttonStyle(.glassProminent)
                            .controlSize(.large)
                    }
                } else if filtered.isEmpty {
                    ContentUnavailableView.search(text: search)
                }
            }
            .searchable(text: $search, prompt: "Search library")
            .navigationTitle("Library")
            .navigationDestination(for: String.self) { hash in TorrentDetailView(infoHash: hash) }
            .toolbar {
                ToolbarItem(placement: .topBarTrailing) {
                    Button { showAdd = true } label: { Label("Add Torrent", systemImage: "plus") }
                        .buttonStyle(.glassProminent)
                }
            }
            .sheet(isPresented: $showAdd) { AddTorrentView() }
            .sheet(item: $export) { e in DocumentExporter(urls: e.urls).ignoresSafeArea() }
            .removeTorrentDialog(item: $pendingRemoval, export: $export)
        }
    }
}

/// Shown while TorrentStream is feeding the VLC app from the background.
struct VLCBanner: View {
    @ObservedObject var keeper: BackgroundKeeper

    var body: some View {
        HStack(spacing: 12) {
            Image(systemName: "dot.radiowaves.left.and.right")
                .symbolEffect(.variableColor.iterative, options: .repeating)
                .foregroundStyle(.orange)
                .font(.title3)
            VStack(alignment: .leading, spacing: 2) {
                Text("Streaming to VLC").font(.subheadline.weight(.semibold))
                Text("Stays active in the background while VLC plays.").font(.caption).foregroundStyle(.secondary)
            }
            Spacer()
            Button("Stop") { keeper.stop() }.buttonStyle(.glass)
        }
        .padding(14)
        .glassEffect(.regular.tint(.orange.opacity(0.15)), in: .rect(cornerRadius: 22))
    }
}

struct TorrentRow: View {
    let item: LibraryItem
    let artwork: URL?

    var body: some View {
        let s = item.status
        HStack(spacing: 14) {
            ArtworkView(hash: item.id, url: artwork, symbol: "film.stack", cornerRadius: 10)
                .frame(width: 54, height: 72)
            VStack(alignment: .leading, spacing: 6) {
                Text(s.name).font(.headline).lineLimit(2)
                statusLine(s)
                if s.phase == .ready && !s.isComplete && s.downloadedBytes > 0 {
                    ProgressView(value: s.progress)
                        .tint(s.isPaused ? .secondary : .accentColor)
                }
            }
        }
        .padding(.vertical, 4)
    }

    @ViewBuilder
    private func statusLine(_ s: TorrentStatus) -> some View {
        Group {
            switch s.phase {
            case .fetchingMetadata:
                Label("Finding peers… \(s.connectedPeers) connected", systemImage: "antenna.radiowaves.left.and.right")
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle.fill").foregroundStyle(.red)
            case .ready:
                if s.isComplete {
                    Label("\(Format.bytes(s.totalLength)) · Downloaded", systemImage: "checkmark.circle.fill")
                        .foregroundStyle(.green)
                } else if s.isPaused {
                    Label("Paused · \(Format.bytes(s.downloadedBytes)) of \(Format.bytes(s.totalLength))", systemImage: "pause.circle.fill")
                } else if s.downloadRate > 0 {
                    Label("\(Format.rate(s.downloadRate)) · \(s.connectedPeers) peers", systemImage: "arrow.down")
                } else {
                    let videos = s.files.filter { $0.file.kind == .video }.count
                    Text("\(Format.bytes(s.totalLength))" + (videos > 0 ? " · \(videos) video\(videos == 1 ? "" : "s")" : ""))
                }
            }
        }
        .font(.caption)
        .foregroundStyle(.secondary)
        .monospacedDigit()
    }
}

/// Pause / download / share / remove actions for a torrent (context menu and detail toolbar).
struct TorrentActionsMenu: View {
    @EnvironmentObject var model: AppModel
    let item: LibraryItem
    let onRemove: () -> Void

    var body: some View {
        let s = item.status
        if s.phase == .ready && !s.isComplete {
            Button { model.togglePause(item.torrent) } label: {
                s.isPaused ? Label("Resume", systemImage: "play.fill") : Label("Pause", systemImage: "pause.fill")
            }
            if s.hasActiveDownloads {
                Button { model.stopAllDownloads(item.torrent) } label: { Label("Stop All Downloads", systemImage: "stop.circle") }
            }
            if s.files.contains(where: { !$0.isComplete && !$0.wanted && !$0.file.isPadding }) {
                Button { model.downloadAll(item.torrent) } label: { Label("Download Everything", systemImage: "arrow.down.circle") }
            }
        }
        Section {
            Button { model.copyMagnet(item.torrent) } label: { Label("Copy Magnet Link", systemImage: "link") }
            ShareLink(item: item.torrent.magnetLink) { Label("Share Magnet Link", systemImage: "square.and.arrow.up") }
        }
        Section {
            Button(role: .destructive, action: onRemove) { Label("Remove Torrent", systemImage: "trash") }
        }
    }
}

extension View {
    /// Confirmation for removing a torrent; offers to save finished files first so nothing is lost.
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
                Button("Save \(saved.count) Downloaded File\(saved.count == 1 ? "" : "s") to Files…") {
                    export = ExportItem(urls: saved)
                }
            }
            Button("Remove and Delete Data", role: .destructive) { model.remove(it.torrent) }
            Button("Cancel", role: .cancel) {}
        } message: { _ in
            if saved.isEmpty {
                Text("Downloaded data for this torrent will be deleted from this device.")
            } else {
                Text("Downloaded data will be deleted from this device. Save finished files to the Files app first to keep them.")
            }
        }
    }
}

struct AddTorrentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var magnet = ""
    @State private var importing = false
    @FocusState private var focused: Bool

    private var isValid: Bool {
        let t = magnet.trimmingCharacters(in: .whitespacesAndNewlines)
        return (try? TorrentDescriptor.parse(magnet: t)) != nil
    }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                        .lineLimit(2...5)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                        .focused($focused)
                        .submitLabel(.go)
                        .onSubmit(add)
                    HStack {
                        PasteButton(payloadType: String.self) { strings in
                            if let s = strings.first { magnet = s.trimmingCharacters(in: .whitespacesAndNewlines) }
                        }
                        .labelStyle(.titleAndIcon)
                        .buttonBorderShape(.capsule)
                        Spacer()
                        if !magnet.isEmpty {
                            Image(systemName: isValid ? "checkmark.circle.fill" : "xmark.circle.fill")
                                .foregroundStyle(isValid ? .green : .red)
                                .transition(.scale.combined(with: .opacity))
                        }
                    }
                } header: {
                    Text("Magnet link")
                } footer: {
                    Text("Tip: tapping a magnet link in Safari opens it here directly.")
                }

                Section {
                    Button { importing = true } label: {
                        Label("Choose a .torrent File", systemImage: "doc.badge.plus")
                    }
                } header: {
                    Text("Torrent file")
                } footer: {
                    Text("You can also share or open .torrent files from Files, Mail or Safari.")
                }
            }
            .animation(.snappy, value: isValid)
            .navigationTitle("Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button(role: .cancel) { dismiss() } label: { Label("Cancel", systemImage: "xmark") }
                }
                ToolbarItem(placement: .confirmationAction) {
                    Button(action: add) { Label("Add", systemImage: "checkmark") }
                        .buttonStyle(.glassProminent)
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
        if model.addMagnet(magnet) { dismiss() }
    }
}
