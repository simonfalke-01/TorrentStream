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
                    LabeledContent("Cache", value: Format.bytes(model.storageUsed))
                        .monospacedDigit()
                    Button("Clear Cache") { model.clearCache() }
                        .disabled(model.items.isEmpty)
                    Button("Remove All Titles…", role: .destructive) { confirmClear = true }
                        .disabled(model.items.isEmpty)
                } header: {
                    Text("Storage")
                } footer: {
                    Text("TorrentStream keeps recently watched titles ready to play and clears older ones on its own.")
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
