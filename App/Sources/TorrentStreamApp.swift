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
            LibraryView()
                .environmentObject(model)
                .onOpenURL { url in model.handleOpen(url: url) }
        }
        .onChange(of: scenePhase) { phase in
            if phase == .active { model.client.ensureStreamingServer() }
        }
    }
}
