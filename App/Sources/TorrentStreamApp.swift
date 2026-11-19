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
            Tab("Library", systemImage: "play.square.stack.fill", value: AppTab.library) {
                LibraryView()
            }
            Tab("Downloads", systemImage: "arrow.down.circle.fill", value: AppTab.downloads) {
                DownloadsView()
            }
            .badge(model.activeDownloadCount)
            Tab("Settings", systemImage: "gearshape.fill", value: AppTab.settings) {
                SettingsView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast)
                    .padding(.top, 8)
                    .allowsHitTesting(false)
            }
        }
        .sensoryFeedback(.success, trigger: model.toast)
        .alert("Something went wrong", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
            Button("OK", role: .cancel) {}
        } message: {
            Text(model.errorMessage ?? "")
        }
    }
}
