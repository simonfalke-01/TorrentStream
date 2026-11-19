import UIKit
import AVFoundation
import TorrentKit

/// Hands a stream to the VLC for iOS app.
enum ExternalPlayer {
    static let vlcAppStore = URL(string: "https://apps.apple.com/app/vlc-media-player/id650377962")!

    @MainActor
    static func openInVLC(_ request: PlaybackRequest, onError: @escaping (String) -> Void) {
        // VLC pulls from our local HTTP server, so TorrentStream must keep running while VLC is in front.
        BackgroundKeeper.shared.start()

        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-._~"))
        var callback = "vlc-x-callback://x-callback-url/stream?url="
            + (request.url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        if let sub = request.subtitles.first {
            callback += "&sub=" + (sub.url.absoluteString.addingPercentEncoding(withAllowedCharacters: allowed) ?? "")
        }
        let app = UIApplication.shared
        app.open(URL(string: callback)!, options: [:]) { ok in
            if ok { return }
            app.open(URL(string: "vlc://\(request.url.absoluteString)")!, options: [:]) { ok2 in
                if ok2 { return }
                BackgroundKeeper.shared.stop()
                app.open(vlcAppStore)
                onError("VLC for iOS is not installed. Install it from the App Store, then try again.")
            }
        }
    }
}

/// Keeps the app (and therefore the torrent engine + local HTTP server) alive in the background while an
/// external player streams from it, by holding an active, silent, mixable audio session.
@MainActor
final class BackgroundKeeper: ObservableObject {
    static let shared = BackgroundKeeper()
    @Published private(set) var isActive = false
    private var player: AVAudioPlayer?
    private var task: UIBackgroundTaskIdentifier = .invalid

    func start() {
        guard !isActive else { return }
        do {
            let session = AVAudioSession.sharedInstance()
            try session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
            try session.setActive(true)
            let p = try AVAudioPlayer(data: BackgroundKeeper.silentWAV())
            p.numberOfLoops = -1
            p.volume = 0
            p.play()
            player = p
            isActive = true
        } catch {
            // Fall back to the limited background task window.
        }
        task = UIApplication.shared.beginBackgroundTask(withName: "stream") { [weak self] in
            Task { @MainActor in self?.endTask() }
        }
    }

    func stop() {
        player?.stop()
        player = nil
        isActive = false
        endTask()
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
    }

    private func endTask() {
        if task != .invalid { UIApplication.shared.endBackgroundTask(task); task = .invalid }
    }

    /// One second of 8 kHz mono 16-bit silence.
    static func silentWAV() -> Data {
        let sampleRate: UInt32 = 8000
        let dataSize: UInt32 = sampleRate * 2
        var d = Data()
        func u32(_ v: UInt32) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 4)) }
        func u16(_ v: UInt16) { var x = v.littleEndian; d.append(Data(bytes: &x, count: 2)) }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + dataSize)
        d.append(contentsOf: Array("WAVEfmt ".utf8)); u32(16); u16(1); u16(1)
        u32(sampleRate); u32(sampleRate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(dataSize)
        d.append(Data(count: Int(dataSize)))
        return d
    }
}
