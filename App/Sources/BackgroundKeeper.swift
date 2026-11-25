import AVFoundation

/// Keeps the app running while downloads are pending and it's off screen. iOS suspends an app shortly after it leaves
/// the screen unless it is playing audio, so a silent loop plays, mixed with whatever else is playing.
@MainActor
final class BackgroundKeeper {
    private var player: AVAudioPlayer?
    private var interrupted = false
    private var observer: NSObjectProtocol?

    var isRunning: Bool { player != nil }
    /// Running the whole time since it started: iOS never suspended the app.
    var stayedAwake: Bool { player != nil && !interrupted }

    func start() {
        guard player == nil else { return }
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .default, options: [.mixWithOthers])
        try? session.setActive(true)
        guard let p = try? AVAudioPlayer(data: Self.silence) else { return }
        p.numberOfLoops = -1
        p.prepareToPlay()
        p.play()
        player = p
        interrupted = false
        observer = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: session, queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            MainActor.assumeIsolated {
                guard let self, let player = self.player else { return }
                if type == .began {
                    self.interrupted = true
                } else {
                    try? AVAudioSession.sharedInstance().setActive(true)
                    player.play()
                }
            }
        }
    }

    /// `playing`: a video is on (in Picture in Picture, say), so the session stays active for it.
    func stop(playing: Bool) {
        guard let p = player else { return }
        p.stop()
        player = nil
        if let observer { NotificationCenter.default.removeObserver(observer) }
        observer = nil
        let session = AVAudioSession.sharedInstance()
        try? session.setCategory(.playback, mode: .moviePlayback)
        if !playing { try? session.setActive(false, options: .notifyOthersOnDeactivation) }
    }

    /// A second of 8 kHz mono silence as WAV.
    private static let silence: Data = {
        let rate: UInt32 = 8000
        let size = rate * 2
        var d = Data()
        func u32(_ v: UInt32) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        func u16(_ v: UInt16) { withUnsafeBytes(of: v.littleEndian) { d.append(contentsOf: $0) } }
        d.append(contentsOf: Array("RIFF".utf8)); u32(36 + size); d.append(contentsOf: Array("WAVE".utf8))
        d.append(contentsOf: Array("fmt ".utf8)); u32(16); u16(1); u16(1); u32(rate); u32(rate * 2); u16(2); u16(16)
        d.append(contentsOf: Array("data".utf8)); u32(size)
        d.append(Data(count: Int(size)))
        return d
    }()
}
