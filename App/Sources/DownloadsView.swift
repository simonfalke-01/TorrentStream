import SwiftUI
import TorrentKit

/// Files being downloaded and files already on this device.
struct DownloadsView: View {
    @EnvironmentObject var model: AppModel
    @State private var playing: PlaybackRequest?
    @State private var export: ExportItem?

    private struct Entry: Identifiable {
        let item: LibraryItem
        let file: FileStatus
        var id: String { "\(item.id)#\(file.file.index)" }
        /// The torrent name only adds information when it differs from the file's title.
        var source: String? {
            let base = (file.file.fileName as NSString).deletingPathExtension
            let name = item.status.name
            return name == file.file.fileName || name == base || name == file.file.title ? nil : name
        }
    }

    private var downloading: [Entry] {
        model.items.flatMap { item in
            item.status.files.filter { $0.isDownloading && !$0.file.isPadding && $0.file.kind != .subtitle }
                .map { Entry(item: item, file: $0) }
        }
    }

    private var downloaded: [Entry] {
        model.items.flatMap { item in
            item.status.files.filter { $0.isComplete && $0.file.kind.isPlayable }
                .map { Entry(item: item, file: $0) }
        }
    }

    var body: some View {
        NavigationStack {
            List {
                if !downloading.isEmpty {
                    Section("Downloading") {
                        ForEach(downloading) { e in downloadingRow(e) }
                    }
                }
                if !downloaded.isEmpty {
                    Section("Downloaded") {
                        ForEach(downloaded) { e in downloadedRow(e) }
                    }
                }
            }
            .listStyle(.insetGrouped)
            .overlay {
                if downloading.isEmpty && downloaded.isEmpty {
                    ContentUnavailableView {
                        Label("No Downloads", systemImage: "arrow.down.circle")
                    } description: {
                        Text("Videos you download or stream appear here.")
                    }
                }
            }
            .navigationTitle("Downloads")
            .fullScreenCover(item: $playing) { req in PlayerScreen(request: req) }
            .exportSheet($export)
        }
    }

    private func downloadingRow(_ e: Entry) -> some View {
        let s = e.item.status
        return HStack(spacing: Space.s) {
            Button { play(e) } label: {
                HStack(spacing: Space.m) {
                    ProgressRing(progress: e.file.progress, lineWidth: 3, tint: s.isPaused ? .secondary : .accentColor)
                        .frame(width: Metrics.rowIcon, height: Metrics.rowIcon)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(e.file.file.title)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        Text(progressText(e))
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: Space.s)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)
            .disabled(!e.file.file.kind.isPlayable)
            .accessibilityValue(Format.percent(e.file.progress))

            Button { model.togglePause(e.item.torrent) } label: {
                Image(systemName: s.isPaused ? "play.fill" : "pause.fill")
                    .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel(s.isPaused ? "Resume" : "Pause")
        }
        .swipeActions {
            Button(role: .destructive) { model.stopDownloading(e.item.torrent, fileIndex: e.file.file.index) } label: {
                Label("Stop Download", systemImage: "stop")
            }
        }
        .contextMenu {
            FileActionsMenu(torrent: e.item.torrent, status: e.file, export: $export,
                            onPlay: e.file.file.kind.isPlayable ? { play(e) } : nil)
        }
    }

    private func progressText(_ e: Entry) -> String {
        let s = e.item.status
        let amount = e.file.detailText
        if s.isPaused { return "\(amount), paused" }
        if s.connectedPeers == 0 { return "\(amount), waiting for peers" }
        if let eta = Format.eta(remaining: e.file.file.length - e.file.downloadedBytes, rate: s.downloadRate) {
            return "\(amount), \(eta)"
        }
        return amount
    }

    private func downloadedRow(_ e: Entry) -> some View {
        HStack(spacing: Space.s) {
            Button { play(e) } label: {
                HStack(spacing: Space.m) {
                    Image(systemName: e.file.file.kind == .audio ? "music.note" : "play.rectangle")
                        .font(.title3)
                        .foregroundStyle(.tint)
                        .frame(width: Metrics.rowIcon)
                    VStack(alignment: .leading, spacing: Space.xs) {
                        Text(e.file.file.title)
                            .foregroundStyle(.primary)
                            .lineLimit(2)
                        if let source = e.source {
                            Text(source)
                                .font(.subheadline)
                                .foregroundStyle(.secondary)
                                .lineLimit(1)
                        }
                        Text(e.file.detailText)
                            .font(.subheadline)
                            .foregroundStyle(.secondary)
                            .monospacedDigit()
                    }
                    Spacer(minLength: Space.s)
                }
                .contentShape(.rect)
            }
            .buttonStyle(.plain)

            Menu {
                FileActionsMenu(torrent: e.item.torrent, status: e.file, export: $export, onPlay: { play(e) })
            } label: {
                Image(systemName: "ellipsis")
                    .font(.body.weight(.semibold))
                    .foregroundStyle(.secondary)
                    .frame(width: Metrics.touchTarget, height: Metrics.touchTarget)
                    .contentShape(.rect)
            }
            .buttonStyle(.borderless)
            .accessibilityLabel("Actions for \(e.file.file.title)")
        }
        .contextMenu {
            FileActionsMenu(torrent: e.item.torrent, status: e.file, export: $export, onPlay: { play(e) })
        }
    }

    private func play(_ e: Entry) {
        playing = model.playbackRequest(torrent: e.item.torrent, file: e.file.file)
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
    @AppStorage(SettingsKey.nyaaAddress) private var nyaaAddress = ""
    @State private var confirmClear = false

    private var selectedEngine: PlayerEngine { PlayerEngine(rawValue: engine) ?? .vlc }

    var body: some View {
        NavigationStack {
            Form {
                if VLCAvailability.isAvailable {
                    Section {
                        Picker("Player", selection: $engine) {
                            ForEach(PlayerEngine.allCases) { e in Text(e.title).tag(e.rawValue) }
                        }
                        .pickerStyle(.menu)
                    } footer: {
                        Text(selectedEngine.detail + ".")
                    }
                }

                Section("Playback") {
                    Toggle("Resume Playback", isOn: $resumePlayback)
                    Toggle("Autoplay Next Episode", isOn: $autoPlayNext)
                }

                Section {
                    Toggle("Keep Downloading After Playback", isOn: $keepDownloading)
                } footer: {
                    Text("Videos you start keep downloading after you close the player, so they’re ready to watch offline.")
                }

                Section {
                    LabeledContent("Nyaa Address") {
                        TextField("nyaa.si", text: $nyaaAddress)
                            .multilineTextAlignment(.trailing)
                            .keyboardType(.URL)
                            .textInputAutocapitalization(.never)
                            .autocorrectionDisabled()
                            .submitLabel(.done)
                    }
                } header: {
                    Text("Search")
                } footer: {
                    Text("Use a mirror if nyaa.si is blocked on your network.")
                }

                Section {
                    Toggle("DHT", isOn: $useDHT)
                    Toggle("Public Trackers", isOn: $publicTrackers)
                } header: {
                    Text("Peer Discovery")
                } footer: {
                    Text("Changes take effect the next time TorrentStream opens.")
                }

                Section("Storage") {
                    LabeledContent("Downloaded Data", value: Format.bytes(model.storageUsed))
                        .monospacedDigit()
                    Button("Remove All Torrents…", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .onAppear { model.refreshStorage() }
            .confirmationDialog("Remove all torrents?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove All and Delete Files", role: .destructive) { model.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every torrent and downloaded file will be deleted from this iPhone.")
            }
        }
    }
}
