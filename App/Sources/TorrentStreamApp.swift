import SwiftUI
import AVFoundation
import TorrentKit

@main
struct TorrentStreamApp: App {
    @UIApplicationDelegateAdaptor(AppDelegate.self) private var appDelegate
    @StateObject private var model: AppModel
    @StateObject private var shows: ShowsModel
    @StateObject private var downloads: DownloadsModel
    @Environment(\.scenePhase) private var scenePhase

    init() {
        let m = AppModel()
        let s = ShowsModel(app: m)
        let d = DownloadsModel(app: m, shows: s)
        s.downloads = d
        _model = StateObject(wrappedValue: m)
        _shows = StateObject(wrappedValue: s)
        _downloads = StateObject(wrappedValue: d)
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        // Posters and backdrops are fetched often; keep them around between launches.
        URLCache.shared = URLCache(memoryCapacity: 50_000_000, diskCapacity: 300_000_000)
    }

    var body: some Scene {
        WindowGroup {
            RootView()
                .environmentObject(model)
                .environmentObject(shows)
                .environmentObject(downloads)
                .onOpenURL { url in model.handleOpen(url: url) }
        }
        .onChange(of: scenePhase) { _, phase in
            switch phase {
            case .active:
                // Same port as before the suspension, and fresh peers in place of the ones that timed out.
                model.client.applicationWillEnterForeground()
                model.refreshStorage()
                model.trimCache()
                downloads.enteredForeground()
            case .background:
                model.client.applicationDidEnterBackground()
                downloads.enteredBackground()
            default:
                break
            }
        }
    }
}

struct RootView: View {
    @EnvironmentObject var model: AppModel

    var body: some View {
        TabView(selection: $model.selectedTab) {
            Tab("Home", systemImage: "house", value: AppTab.home) {
                HomeView()
            }
            Tab("Schedule", systemImage: "calendar", value: AppTab.schedule) {
                ScheduleView()
            }
            Tab("Library", systemImage: "rectangle.stack", value: AppTab.library) {
                LibraryView()
            }
            Tab(value: AppTab.search, role: .search) {
                SearchView()
            }
        }
        .tabBarMinimizeBehavior(.onScrollDown)
        .preferredColorScheme(.dark)
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
