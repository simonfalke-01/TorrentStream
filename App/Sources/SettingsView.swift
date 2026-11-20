import SwiftUI
import TorrentKit

/// Opened from the gear button on Home.
struct SettingsView: View {
    @EnvironmentObject var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @AppStorage(SettingsKey.playerEngine) private var engine: String = PlayerEngine.vlc.rawValue
    @AppStorage(SettingsKey.resumePlayback) private var resumePlayback = true
    @AppStorage(SettingsKey.autoPlayNext) private var autoPlayNext = true
    @AppStorage(SettingsKey.showArtwork) private var showArtwork = true
    @AppStorage(SettingsKey.useDHT) private var useDHT = true
    @AppStorage(SettingsKey.publicTrackers) private var publicTrackers = true
    @AppStorage(SettingsKey.nyaaAddress) private var nyaaAddress = ""
    @AppStorage(SettingsKey.cacheLimitGB) private var cacheLimitGB = 5
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
                    Toggle("Show Artwork and Details", isOn: $showArtwork)
                        .onChange(of: showArtwork) { _, on in
                            if on { model.refresh() } else { model.clearCatalog() }
                        }
                } footer: {
                    Text("Looks up posters and synopses by title on AniList and Cinemeta. Turn off to keep titles on this device.")
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
                    Text("Search results come from Nyaa. Use a mirror if nyaa.si is blocked on your network.")
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
                        .disabled(model.items.isEmpty)
                    Button("Remove All Titles…", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("TorrentStream loads up to ten minutes ahead of what you're watching and the start of the next episode. Older titles are cleared on their own; your progress is kept.")
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
            .confirmationDialog("Remove all titles from My List?", isPresented: $confirmClear, titleVisibility: .visible) {
                Button("Remove All", role: .destructive) { model.removeAll() }
                Button("Cancel", role: .cancel) {}
            } message: {
                Text("Every title is removed from My List.")
            }
        }
    }
}
