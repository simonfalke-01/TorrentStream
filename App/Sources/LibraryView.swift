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
    @State private var showSettings = false
    @State private var pendingDelete: Torrent?

    var body: some View {
        NavigationStack(path: $model.navigationPath) {
            List {
                if keeper.isActive {
                    Section {
                        HStack {
                            Image(systemName: "dot.radiowaves.left.and.right").foregroundStyle(.green)
                            VStack(alignment: .leading) {
                                Text("Streaming to VLC").font(.subheadline.bold())
                                Text("TorrentStream stays active in the background to feed VLC.").font(.caption).foregroundStyle(.secondary)
                            }
                            Spacer()
                            Button("Stop") { keeper.stop() }.buttonStyle(.bordered)
                        }
                    }
                }
                if model.items.isEmpty {
                    Section {
                        VStack(spacing: 12) {
                            Image(systemName: "play.rectangle.on.rectangle").font(.system(size: 44)).foregroundStyle(.tint)
                            Text("No torrents yet").font(.headline)
                            Text("Add a magnet link or a .torrent file, pick a video and it starts playing while it downloads.")
                                .font(.subheadline).foregroundStyle(.secondary).multilineTextAlignment(.center)
                            Button { showAdd = true } label: { Label("Add Torrent", systemImage: "plus") }
                                .buttonStyle(.borderedProminent)
                        }
                        .frame(maxWidth: .infinity)
                        .padding(.vertical, 24)
                    }
                }
                ForEach(model.items) { item in
                    NavigationLink(value: item.id) { TorrentRow(status: item.status) }
                        .swipeActions {
                            Button(role: .destructive) { pendingDelete = item.torrent } label: { Label("Remove", systemImage: "trash") }
                        }
                }
            }
            .navigationTitle("TorrentStream")
            .navigationDestination(for: String.self) { hash in TorrentDetailView(infoHash: hash) }
            .toolbar {
                ToolbarItem(placement: .navigationBarLeading) {
                    Button { showSettings = true } label: { Image(systemName: "gearshape") }
                }
                ToolbarItem(placement: .navigationBarTrailing) {
                    Button { showAdd = true } label: { Image(systemName: "plus") }
                }
            }
            .sheet(isPresented: $showAdd) { AddTorrentView() }
            .sheet(isPresented: $showSettings) { SettingsView() }
            .confirmationDialog("Remove torrent?", isPresented: Binding(get: { pendingDelete != nil }, set: { if !$0 { pendingDelete = nil } }),
                                titleVisibility: .visible) {
                Button("Remove and delete downloaded data", role: .destructive) {
                    if let t = pendingDelete { model.remove(t, deleteData: true) }
                }
                Button("Remove, keep data") { if let t = pendingDelete { model.remove(t, deleteData: false) } }
            }
            .alert("Error", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) {}
            } message: { Text(model.errorMessage ?? "") }
        }
    }
}

struct TorrentRow: View {
    let status: TorrentStatus

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text(status.name).font(.headline).lineLimit(2)
            switch status.phase {
            case .fetchingMetadata:
                Label("Fetching file list… \(status.connectedPeers) peers", systemImage: "magnifyingglass")
                    .font(.caption).foregroundStyle(.secondary)
            case .failed(let msg):
                Label(msg, systemImage: "exclamationmark.triangle").font(.caption).foregroundStyle(.red)
            case .ready:
                ProgressView(value: status.progress)
                HStack {
                    Text("\(Format.bytes(status.downloadedBytes)) of \(Format.bytes(status.totalLength))")
                    Spacer()
                    Image(systemName: "person.2")
                    Text("\(status.connectedPeers)")
                    Image(systemName: "arrow.down")
                    Text(Format.rate(status.downloadRate))
                }
                .font(.caption).foregroundStyle(.secondary).monospacedDigit()
            }
        }
        .padding(.vertical, 4)
    }
}

struct AddTorrentView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var magnet = ""
    @State private var importing = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    TextField("magnet:?xt=urn:btih:…", text: $magnet, axis: .vertical)
                        .lineLimit(3...6)
                        .textInputAutocapitalization(.never)
                        .autocorrectionDisabled()
                        .font(.system(.footnote, design: .monospaced))
                    Button {
                        if let s = UIPasteboard.general.string { magnet = s }
                    } label: { Label("Paste from Clipboard", systemImage: "doc.on.clipboard") }
                    Button {
                        if model.addMagnet(magnet) { dismiss() }
                    } label: { Label("Add Magnet Link", systemImage: "link") }
                        .disabled(magnet.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                } header: { Text("Magnet link") }

                Section {
                    Button { importing = true } label: { Label("Choose .torrent File…", systemImage: "doc.badge.plus") }
                } header: { Text("Torrent file") } footer: {
                    Text("You can also open .torrent files and magnet links directly from Safari, Files or other apps.")
                }
            }
            .navigationTitle("Add Torrent")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .cancellationAction) { Button("Cancel") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.torrent, .data], allowsMultipleSelection: false) { result in
                if case .success(let urls) = result, let url = urls.first {
                    model.addTorrentFile(at: url)
                    if model.errorMessage == nil { dismiss() }
                } else if case .failure(let error) = result {
                    model.errorMessage = error.localizedDescription
                }
            }
            .onAppear {
                if magnet.isEmpty, let s = UIPasteboard.general.string, s.lowercased().hasPrefix("magnet:") { magnet = s }
            }
        }
    }
}

struct SettingsView: View {
    @Environment(\.dismiss) private var dismiss
    @AppStorage("playerEngine") private var engine: String = PlayerEngine.vlc.rawValue

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Built-in player", selection: $engine) {
                        ForEach(PlayerEngine.allCases) { e in Text(e.title).tag(e.rawValue) }
                    }
                    .pickerStyle(.inline)
                    .disabled(!VLCAvailability.isAvailable)
                } header: { Text("Playback") } footer: {
                    if VLCAvailability.isAvailable {
                        Text("VLC plays MKV, AVI, WebM, HEVC and more, and lets you switch audio tracks and subtitles. AVPlayer supports embedded tracks of MP4/MOV files only.")
                    } else {
                        Text("This build was made without MobileVLCKit, so only AVPlayer is available. Use “Open in VLC” for other formats.")
                    }
                }
                Section("About") {
                    LabeledContent("Engine", value: "TorrentKit (BitTorrent v1, DHT, PEX, ut_metadata)")
                    LabeledContent("Streaming port", value: "127.0.0.1")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
        }
    }
}

enum Format {
    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }
    static func rate(_ v: Double) -> String { bytes(Int64(v)) + "/s" }
    static func time(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }
}
