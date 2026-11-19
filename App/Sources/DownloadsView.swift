import SwiftUI
import TorrentKit

/// Everything being downloaded for offline use, and everything that's ready to watch.
struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var export: ExportItem?

    private struct Entry: Identifiable {
        let item: LibraryItem
        let file: FileStatus
        var id: String { "\(item.id)#\(file.file.index)" }
    }

    private var downloading: [Entry] {
        model.items.flatMap { item in
            item.status.files.filter { $0.isDownloading && !$0.file.isPadding && $0.file.kind != .subtitle }
                .map { Entry(item: item, file: $0) }
        }
    }

    private var ready: [Entry] {
        model.items.flatMap { item in
            item.status.files.filter { $0.isComplete && $0.file.kind.isPlayable }
                .map { Entry(item: item, file: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                Section {
                    HStack(spacing: 14) {
                        Image(systemName: "internaldrive.fill").font(.title2).foregroundStyle(.tint)
                        VStack(alignment: .leading, spacing: 2) {
                            Text(Format.bytes(model.storageUsed)).font(.headline).monospacedDigit()
                            Text("Used by TorrentStream on this device").font(.caption).foregroundStyle(.secondary)
                        }
                    }
                    .padding(.vertical, 4)
                }

                if !downloading.isEmpty {
                    Section("Downloading") {
                        ForEach(downloading) { e in downloadingRow(e) }
                    }
                }
                if !ready.isEmpty {
                    Section {
                        ForEach(ready) { e in readyRow(e) }
                    } header: {
                        Text("Ready to Watch")
                    } footer: {
                        Text("Saved on this device. Use Save to Files to keep a copy after removing the torrent.")
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if downloading.isEmpty && ready.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Choose “Download for Offline” on any video to keep it on this device. Videos you stream keep downloading in the background too.")
                    }
                }
            }
            .navigationTitle("Downloads")
            .refreshable { model.refreshStorage() }
            .onAppear { model.refreshStorage() }
            .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
            .sheet(item: $export) { e in DocumentExporter(urls: e.urls) { ok in if ok { model.showToast("Saved to Files") } }.ignoresSafeArea() }
        }
    }

    private func downloadingRow(_ e: Entry) -> some View {
        let s = e.item.status
        return HStack(spacing: 14) {
            ProgressRing(progress: e.file.progress, lineWidth: 4, tint: s.isPaused ? .secondary : .accentColor)
                .frame(width: 36, height: 36)
                .overlay {
                    Image(systemName: s.isPaused ? "pause.fill" : "arrow.down")
                        .font(.caption.bold())
                        .foregroundStyle(s.isPaused ? Color.secondary : Color.accentColor)
                }
            VStack(alignment: .leading, spacing: 3) {
                Text(e.file.file.fileName).lineLimit(1)
                Text(rowDetail(e)).font(.caption).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
            }
            Spacer()
            Button { model.togglePause(e.item.torrent) } label: {
                Image(systemName: s.isPaused ? "play.fill" : "pause.fill").frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel(s.isPaused ? "Resume" : "Pause")
        }
        .contentShape(Rectangle())
        .onTapGesture { if e.file.file.kind.isPlayable { playing = model.playbackRequest(torrent: e.item.torrent, file: e.file.file) } }
        .swipeActions {
            Button(role: .destructive) { model.stopDownloading(e.item.torrent, fileIndex: e.file.file.index) } label: {
                Label("Stop", systemImage: "stop.fill")
            }
        }
    }

    private func rowDetail(_ e: Entry) -> String {
        let s = e.item.status
        var parts = ["\(Format.bytes(e.file.downloadedBytes)) of \(Format.bytes(e.file.file.length))"]
        if s.isPaused { parts.append("Paused") }
        else if let eta = Format.eta(remaining: e.file.file.length - e.file.downloadedBytes, rate: s.downloadRate) { parts.append(eta) }
        else if s.connectedPeers == 0 { parts.append("Waiting for peers") }
        return parts.joined(separator: " · ")
    }

    private func readyRow(_ e: Entry) -> some View {
        let url = model.localURL(e.item.torrent, e.file.file)
        return HStack(spacing: 14) {
            ZStack {
                RoundedRectangle(cornerRadius: 10, style: .continuous).fill(torrentTint(for: e.item.id).gradient)
                Image(systemName: e.file.file.kind == .audio ? "music.note" : "play.fill").foregroundStyle(.white)
            }
            .frame(width: 44, height: 44)
            VStack(alignment: .leading, spacing: 3) {
                Text(e.file.file.fileName).lineLimit(2)
                Text("\(Format.bytes(e.file.file.length)) · \(e.item.status.name)")
                    .font(.caption).foregroundStyle(.secondary).lineLimit(1)
            }
            Spacer()
            Menu {
                Button { playing = model.playbackRequest(torrent: e.item.torrent, file: e.file.file) } label: { Label("Play", systemImage: "play.fill") }
                if let url {
                    Button { export = ExportItem(urls: [url]) } label: { Label("Save to Files", systemImage: "folder") }
                    if PhotoSaver.canSave(e.file.file) {
                        Button { model.saveToPhotos(e.item.torrent, e.file.file) } label: { Label("Save to Photos", systemImage: "photo.on.rectangle") }
                    }
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                }
            } label: {
                Image(systemName: "square.and.arrow.down").frame(width: 28, height: 28)
            }
            .buttonStyle(.glass)
            .buttonBorderShape(.circle)
            .accessibilityLabel("Save or share")
        }
        .contentShape(Rectangle())
        .onTapGesture { playing = model.playbackRequest(torrent: e.item.torrent, file: e.file.file) }
    }
}

struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @AppStorage(SettingsKey.playerEngine) private var engine: String = PlayerEngine.vlc.rawValue
    @AppStorage(SettingsKey.keepDownloading) private var keepDownloading = true
    @AppStorage(SettingsKey.resumePlayback) private var resumePlayback = true
    @AppStorage(SettingsKey.autoPlayNext) private var autoPlayNext = true
    @AppStorage(SettingsKey.useDHT) private var useDHT = true
    @AppStorage(SettingsKey.publicTrackers) private var publicTrackers = true
    @State private var confirmClear = false

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    Picker("Player", selection: $engine) {
                        ForEach(PlayerEngine.allCases) { e in
                            VStack(alignment: .leading) {
                                Text(e.title)
                                Text(e.detail).font(.caption).foregroundStyle(.secondary)
                            }
                            .tag(e.rawValue)
                        }
                    }
                    .pickerStyle(.inline)
                    .disabled(!VLCAvailability.isAvailable)
                    Toggle("Resume Where You Left Off", isOn: $resumePlayback)
                    Toggle("Play Next Episode Automatically", isOn: $autoPlayNext)
                } header: {
                    Text("Playback")
                } footer: {
                    Text("VLC plays MKV, AVI, WebM, HEVC and more, with audio track and subtitle selection.")
                }

                Section {
                    Toggle("Keep Downloading After Playback", isOn: $keepDownloading)
                } footer: {
                    Text("When on, a video you start streaming keeps downloading in the background so it's ready offline. When off, only what you watch is downloaded, unless you choose “Download for Offline”.")
                }

                Section {
                    Toggle("DHT (Trackerless Peers)", isOn: $useDHT)
                    Toggle("Add Public Trackers", isOn: $publicTrackers)
                } header: {
                    Text("Network")
                } footer: {
                    Text("Helps magnet links find peers faster. Changes apply the next time the app launches.")
                }

                Section("Storage") {
                    LabeledContent("Downloaded Data", value: Format.bytes(model.storageUsed))
                    Button("Remove All Torrents and Data", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                }

                Section("About") {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "1.0")
                    LabeledContent("Engine", value: "TorrentKit")
                    LabeledContent("Player", value: VLCAvailability.isAvailable ? "VLC + AVPlayer" : "AVPlayer")
                }
            }
            .navigationTitle("Settings")
            .onAppear { model.refreshStorage() }
            .confirmationDialog("Remove all torrents?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove All and Delete Data", role: .destructive) { model.removeAll() }
            } message: {
                Text("This deletes every torrent and all downloaded files from this device. Save anything you want to keep to Files first.")
            }
        }
    }
}
