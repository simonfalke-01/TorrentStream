import SwiftUI
import TorrentKit

/// Opened from the gear button on Home.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @EnvironmentObject var shows: ShowsModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.playerEngine) private var engine: String = PlayerEngine.vlc.rawValue
    @AppStorage(SettingsKey.resumePlayback) private var resumePlayback = true
    @AppStorage(SettingsKey.autoPlayNext) private var autoPlayNext = true
    @AppStorage(SettingsKey.showArtwork) private var showArtwork = true
    @AppStorage(SettingsKey.useDHT) private var useDHT = true
    @AppStorage(SettingsKey.publicTrackers) private var publicTrackers = true
    @AppStorage(SettingsKey.nyaaAddress) private var nyaaAddress = ""
    @AppStorage(SettingsKey.cacheLimitGB) private var cacheLimitGB = 5
    @AppStorage(SettingsKey.preferredResolution) private var resolution = 1080
    @AppStorage(SettingsKey.preferDub) private var preferDub = false
    @State private var confirmClear = false

    private var selectedEngine: PlayerEngine { PlayerEngine(rawValue: engine) ?? .vlc }

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if VLCAvailability.isAvailable {
                        Picker("Player", selection: $engine) {
                            ForEach(PlayerEngine.allCases) { e in Text(e.title).tag(e.rawValue) }
                        }
                        .pickerStyle(.menu)
                    }
                    Toggle("Resume Where You Left Off", isOn: $resumePlayback)
                    Toggle("Autoplay Next Episode", isOn: $autoPlayNext)
                } header: {
                    Text("Playback")
                } footer: {
                    if VLCAvailability.isAvailable { Text(selectedEngine.detail + ".") }
                }

                Section {
                    Picker("Quality", selection: $resolution) {
                        Text("4K").tag(2160)
                        Text("1080p").tag(1080)
                        Text("720p").tag(720)
                        Text("480p").tag(480)
                    }
                    .pickerStyle(.menu)
                    Picker("Audio", selection: $preferDub) {
                        Text("Japanese with Subtitles").tag(false)
                        Text("English Dub").tag(true)
                    }
                    .pickerStyle(.menu)
                } header: {
                    Text("Streaming")
                } footer: {
                    Text("Play picks the closest match that starts quickly. To choose a specific version, touch and hold an episode.")
                }
                .onChange(of: resolution) { shows.preferencesChanged() }
                .onChange(of: preferDub) { shows.preferencesChanged() }

                Section {
                    Toggle("Show Artwork and Details", isOn: $showArtwork)
                        .onChange(of: showArtwork) { _, on in
                            if on { model.refresh() } else { model.clearCatalog() }
                        }
                } footer: {
                    Text("For titles added by link, looks up posters and synopses on AniList and Cinemeta. Turn off to keep those titles on this device.")
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
                    Text("Sources")
                } footer: {
                    Text("Episodes are found on Nyaa. Use a mirror if nyaa.si is blocked on your network.")
                }

                Section {
                    Toggle("DHT", isOn: $useDHT)
                    Toggle("Public Trackers", isOn: $publicTrackers)
                } header: {
                    Text("Connections")
                } footer: {
                    Text("Both help titles start faster. Changes take effect the next time TorrentStream opens.")
                }

                Section {
                    Picker("Cache Size", selection: $cacheLimitGB) {
                        Text("Small (2 GB)").tag(2)
                        Text("Medium (5 GB)").tag(5)
                        Text("Large (10 GB)").tag(10)
                    }
                    .pickerStyle(.menu)
                    .onChange(of: cacheLimitGB) { model.trimCache() }
                    LabeledContent("In Use", value: Format.bytes(model.storageUsed))
                        .monospacedDigit()
                    Button("Clear Cache") { model.clearCache() }
                        .disabled(model.storageUsed == 0)
                    Button("Remove Titles Added by Link…", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("TorrentStream loads up to ten minutes ahead of what you’re watching and the start of the next episode. Older episodes are cleared on their own; your progress is kept.")
                }

                Section {
                    LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "")
                }
            }
            .navigationTitle("Settings")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
            .onAppear { model.refreshStorage() }
            .confirmationDialog("Remove every title added by link?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) { model.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Shows in My List and your progress stay.")
            }
        }
    }
}
