import SwiftUI
import AVFoundation
import TorrentKit

@main
struct TorrentStreamApp: App {
    @StateObject private var model = AppModel()
    @Environment(\.scenePhase) private var scenePhase

    init() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .onOpenURL { url in model.handleOpen(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            if phase == .active {
                model.client.ensureStreamingServer()
                model.refreshStorage()
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            Tab("Library", systemImage: "play.square.stack", value: AppTab.library) {
                LibraryView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle", value: AppTab.downloads) {
                DownloadsView()
            }
            .badge(model.activeDownloadCount)
            Tab("Settings", systemImage: "gear", value: AppTab.settings) {
                SettingsView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.top, Space.s)
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.success, trigger: model.toast) { _, new in new != nil }
        .alert(model.errorMessage ?? "", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        }
    }
}
