import SwiftUI
import AVFoundation
import MediaPlayer
import MobileVLCKit
import SubtitleKit

/// An audio or subtitle track as libVLC lists it, with a name fit to show.
struct MediaTrack: Identifiable, Hashable {
    let id: Int
    /// "English", "Signs & Songs", "Off".
    let title: String
    /// The language when the title names something else, e.g. "English" under "Signs & Songs".
    let detail: String?
    /// libVLC's own name, which choices are remembered by.
    let raw: String

    /// libVLC names tracks "Track 1 - [Japanese]" or "Full Subtitles - [English]".
    init(id: Int, raw: String) {
        self.id = id
        self.raw = raw
        if id == -1 {
            title = "Off"
            detail = nil
            return
        }
        var name = raw
        var language: String?
        if let open = raw.range(of: " - [", options: .backwards), raw.hasSuffix("]") {
            name = String(raw[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            language = String(raw[open.upperBound..<raw.index(before: raw.endIndex)])
        } else if raw.hasPrefix("["), raw.hasSuffix("]") {
            name = ""
            language = String(raw.dropFirst().dropLast())
        }
        let generic = name.isEmpty || name.range(of: #"^Track \d+$"#, options: .regularExpression) != nil
        if generic, let language {
            title = language
            detail = nil
        } else {
            title = name.isEmpty ? raw : name
            detail = language.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
        }
    }

    var isSignsOnly: Bool { SubtitleLabels.isSignsOnly(name: raw) }
    var isEnglish: Bool { raw.range(of: #"english|\beng\b|\ben\b"#, options: [.regularExpression, .caseInsensitive]) != nil }
}

/// A chapter of the video, in seconds.
struct Chapter: Identifiable, Hashable {
    let id: Int
    let name: String
    let start: Double
    let end: Double?
}

/// Subtitle text size, applied when the player opens.
enum SubtitleSize: Int, CaseIterable, Identifiable {
    case small = 80, medium = 100, large = 125, extraLarge = 150
    var id: Int { rawValue }
    var title: String {
        switch self {
        case .small: return "Small"
        case .medium: return "Medium"
        case .large: return "Large"
        case .extraLarge: return "Extra Large"
        }
    }
}

/// libVLC behind a small observable surface: time, state, tracks, chapters and the video's size.
@MainActor
final class PlaybackEngine: ObservableObject {
    @Published private(set) var isPlaying = false
    @Published private(set) var isBuffering = true
    @Published private(set) var currentTime: Double = 0
    @Published private(set) var duration: Double = 0
    @Published private(set) var didFinish = false
    @Published private(set) var errorText: String?
    @Published private(set) var audioTracks: [MediaTrack] = []
    @Published private(set) var subtitleTracks: [MediaTrack] = []
    @Published private(set) var currentAudio = -1
    @Published private(set) var currentSubtitle = -1
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var audioDelay: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var videoSize: CGSize = .zero

    let surface = UIView()
    private let player: VLCMediaPlayer
    private let memoryKey: String
    private let preferDub: Bool
    private var timer: Timer?
    private var lastTime: Int32 = -1
    private var lastChange = Date()
    private var seekTarget: Double?
    private var seekDeadline = Date()
    private var tracksSettled = false
    private var chaptersLoaded = false
    private var startedAt = Date()

    /// - Parameter memoryKey: what audio and subtitle choices are remembered under, usually the show.
    init(request: PlaybackRequest, memoryKey: String) {
        let size = UserDefaults.standard.integer(forKey: SettingsKey.subtitleSize)
        let scale = SubtitleSize(rawValue: size)?.rawValue ?? SubtitleSize.medium.rawValue
        player = VLCMediaPlayer(options: ["--sub-text-scale=\(scale)"])
        self.memoryKey = memoryKey
        preferDub = UserDefaults.standard.bool(forKey: SettingsKey.preferDub)
        surface.backgroundColor = .black
        surface.isUserInteractionEnabled = false

        let media = VLCMedia(url: request.url)
        // Generous network cache: the torrent may deliver in bursts.
        media.addOption(":network-caching=4000")
        media.addOption(":http-reconnect")
        media.addOption(preferDub ? ":audio-language=eng,en,jpn,ja" : ":audio-language=jpn,ja,eng,en")
        if !preferDub { media.addOption(":sub-language=eng,en,English") }
        if let r = request.resumeAt, r > 0 { media.addOption(":start-time=\(Int(r))") }
        player.media = media
        player.drawable = surface
        for s in request.subtitles.prefix(8) {
            player.addPlaybackSlave(s.url, type: .subtitle, enforce: false)
        }
        if let r = request.resumeAt, r > 0 { currentTime = r }
    }

    // MARK: lifecycle

    func start() {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        startedAt = Date()
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        let p = player
        DispatchQueue.global(qos: .userInitiated).async { p.stop() }
    }

    private func poll() {
        let state = player.state
        let t = player.time.intValue
        if t != lastTime { lastTime = t; lastChange = Date() }
        let idle = Date().timeIntervalSince(lastChange)

        if state == .ended {
            if !didFinish { didFinish = true }
            isPlaying = false
            isBuffering = false
            if duration > 0 { currentTime = duration }
            return
        }
        if state == .error {
            errorText = "This video couldn’t be played."
            isBuffering = false
            return
        }
        isPlaying = player.isPlaying
        isBuffering = state == .opening
            || (state == .buffering && idle > 0.75)
            || (player.isPlaying && idle > 1.5)

        let len = player.media?.length.intValue ?? 0
        if len > 0 { duration = Double(len) / 1000 }

        let now = Double(t) / 1000
        if let target = seekTarget {
            if abs(now - target) < 2.5 || Date() > seekDeadline { seekTarget = nil } else { currentTime = target }
        }
        if seekTarget == nil, t > 0 { currentTime = now }

        let size = player.videoSize
        if size.width > 0, size != videoSize { videoSize = size }

        refreshTracks()
        if !chaptersLoaded, duration > 0 { loadChapters() }
    }

    private func refreshTracks() {
        let aNames = player.audioTrackNames.compactMap { $0 as? String }
        let aIDs = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let a = zip(aIDs, aNames).filter { $0.0 != -1 }.map { MediaTrack(id: $0, raw: $1) }
        if a != audioTracks { audioTracks = a }
        currentAudio = Int(player.currentAudioTrackIndex)

        let sNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let sIDs = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let s = zip(sIDs, sNames).map { MediaTrack(id: $0, raw: $1) }
        if s != subtitleTracks { subtitleTracks = s }
        currentSubtitle = Int(player.currentVideoSubTitleIndex)

        // Tracks appear once the file is open; give slaves a moment to load before choosing.
        if !tracksSettled, !audioTracks.isEmpty, currentTime > 0 || Date().timeIntervalSince(startedAt) > 6 {
            tracksSettled = true
            applyRememberedTracks()
        }
    }

    private func loadChapters() {
        let title = player.currentTitleIndex
        guard title >= 0 else { return }
        let list = player.chapterDescriptions(ofTitle: title).compactMap { $0 as? [String: Any] }
        chaptersLoaded = true
        guard list.count > 1 else { return }
        chapters = list.enumerated().compactMap { i, d in
            guard let offset = (d[VLCChapterDescriptionTimeOffset] as? NSNumber)?.doubleValue else { return nil }
            let length = (d[VLCChapterDescriptionDuration] as? NSNumber)?.doubleValue
            let name = (d[VLCChapterDescriptionName] as? String)?.trimmingCharacters(in: .whitespaces)
            return Chapter(id: i, name: name?.isEmpty == false ? name! : "Chapter \(i + 1)",
                           start: offset / 1000, end: length.map { (offset + $0) / 1000 })
        }
    }

    // MARK: transport

    func play() {
        if didFinish { replay(); return }
        player.play()
        isPlaying = true
    }

    func pause() { player.pause(); isPlaying = false }
    func togglePlay() { isPlaying ? pause() : play() }

    func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(seconds, duration - 1))
        if didFinish {
            didFinish = false
            player.play()
        }
        player.position = Float(target / duration)
        markSeek(target)
    }

    func skip(by seconds: Double) {
        let s = Int32(abs(seconds))
        if seconds > 0 { player.jumpForward(s) } else { player.jumpBackward(s) }
        markSeek(max(0, duration > 0 ? min(currentTime + seconds, duration) : currentTime + seconds))
    }

    private func markSeek(_ target: Double) {
        seekTarget = target
        seekDeadline = Date().addingTimeInterval(4)
        currentTime = target
        lastChange = Date()
    }

    func replay() {
        didFinish = false
        markSeek(0)
        let p = player
        DispatchQueue.global(qos: .userInitiated).async {
            p.stop()
            p.play()
        }
        isPlaying = true
    }

    func setRate(_ r: Float) { rate = r; player.rate = r }

    // MARK: tracks

    func selectAudio(_ id: Int) {
        player.currentAudioTrackIndex = Int32(id)
        currentAudio = id
        remember(audio: audioTracks.first { $0.id == id }?.raw)
    }

    func selectSubtitle(_ id: Int) {
        player.currentVideoSubTitleIndex = Int32(id)
        currentSubtitle = id
        remember(subtitle: id == -1 ? Self.offChoice : subtitleTracks.first { $0.id == id }?.raw)
    }

    func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        player.currentVideoSubTitleDelay = Int(seconds * 1_000_000)
    }

    func setAudioDelay(_ seconds: Double) {
        audioDelay = seconds
        player.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
    }

    func addSubtitleFile(_ url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }

    // MARK: remembered choices

    private static let offChoice = "\u{0}off"

    private var memory: [String: String] {
        (UserDefaults.standard.dictionary(forKey: SettingsKey.trackChoices)?[memoryKey] as? [String: String]) ?? [:]
    }

    private func remember(audio: String? = nil, subtitle: String? = nil) {
        var all = UserDefaults.standard.dictionary(forKey: SettingsKey.trackChoices) ?? [:]
        var mine = memory
        if let audio { mine["audio"] = audio }
        if let subtitle { mine["subtitle"] = subtitle }
        all[memoryKey] = mine
        UserDefaults.standard.set(all, forKey: SettingsKey.trackChoices)
    }

    /// The choices made last time for this show, else a full subtitle track rather than signs only.
    private func applyRememberedTracks() {
        let saved = memory
        if let a = saved["audio"], let match = audioTracks.first(where: { $0.raw == a }), match.id != currentAudio {
            player.currentAudioTrackIndex = Int32(match.id)
            currentAudio = match.id
        }
        if let s = saved["subtitle"] {
            if s == Self.offChoice {
                player.currentVideoSubTitleIndex = -1
                currentSubtitle = -1
                return
            }
            if let match = subtitleTracks.first(where: { $0.raw == s }) {
                if match.id != currentSubtitle {
                    player.currentVideoSubTitleIndex = Int32(match.id)
                    currentSubtitle = match.id
                }
                return
            }
        }
        // Releases often flag the signs track as default, which leaves dialogue untranslated.
        guard !preferDub, let current = subtitleTracks.first(where: { $0.id == currentSubtitle }), current.isSignsOnly else { return }
        let real = subtitleTracks.filter { $0.id != -1 && !$0.isSignsOnly }
        if let better = real.first(where: \.isEnglish) ?? real.first {
            player.currentVideoSubTitleIndex = Int32(better.id)
            currentSubtitle = better.id
        }
    }
}

/// The video itself.
struct VideoSurface: UIViewRepresentable {
    let engine: PlaybackEngine
    func makeUIView(context: Context) -> UIView { engine.surface }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

/// Lock Screen and Control Center: what's playing, and play, pause and seek from there.
@MainActor
final class NowPlaying {
    private var targets: [Any] = []
    private var timer: Timer?

    func activate(engine: PlaybackEngine, title: String, subtitle: String?) {
        let center = MPRemoteCommandCenter.shared()
        targets = [
            center.playCommand.addTarget { [weak engine] _ in MainActor.assumeIsolated { engine?.play() }; return .success },
            center.pauseCommand.addTarget { [weak engine] _ in MainActor.assumeIsolated { engine?.pause() }; return .success },
            center.togglePlayPauseCommand.addTarget { [weak engine] _ in MainActor.assumeIsolated { engine?.togglePlay() }; return .success },
            center.skipForwardCommand.addTarget { [weak engine] _ in MainActor.assumeIsolated { engine?.skip(by: 10) }; return .success },
            center.skipBackwardCommand.addTarget { [weak engine] _ in MainActor.assumeIsolated { engine?.skip(by: -10) }; return .success },
            center.changePlaybackPositionCommand.addTarget { [weak engine] e in
                guard let e = e as? MPChangePlaybackPositionCommandEvent else { return .commandFailed }
                let at = e.positionTime
                MainActor.assumeIsolated { engine?.seek(to: at) }
                return .success
            },
        ]
        center.skipForwardCommand.preferredIntervals = [10]
        center.skipBackwardCommand.preferredIntervals = [10]
        var info: [String: Any] = [MPMediaItemPropertyTitle: subtitle ?? title]
        if subtitle != nil { info[MPMediaItemPropertyAlbumTitle] = title }
        info[MPNowPlayingInfoPropertyMediaType] = MPNowPlayingInfoMediaType.video.rawValue
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self, weak engine] _ in
            Task { @MainActor in
                if let engine { self?.update(engine: engine) }
            }
        }
    }

    private func update(engine: PlaybackEngine) {
        guard var info = MPNowPlayingInfoCenter.default().nowPlayingInfo else { return }
        info[MPNowPlayingInfoPropertyElapsedPlaybackTime] = engine.currentTime
        info[MPMediaItemPropertyPlaybackDuration] = engine.duration
        info[MPNowPlayingInfoPropertyPlaybackRate] = engine.isPlaying ? Double(engine.rate) : 0
        MPNowPlayingInfoCenter.default().nowPlayingInfo = info
    }

    func deactivate() {
        let center = MPRemoteCommandCenter.shared()
        for c in [center.playCommand, center.pauseCommand, center.togglePlayPauseCommand, center.skipForwardCommand,
                  center.skipBackwardCommand, center.changePlaybackPositionCommand] as [MPRemoteCommand] {
            c.removeTarget(nil)
        }
        targets = []
        timer?.invalidate()
        timer = nil
        MPNowPlayingInfoCenter.default().nowPlayingInfo = nil
    }
}
