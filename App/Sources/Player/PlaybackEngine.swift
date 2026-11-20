import SwiftUI
import AVFoundation
import MediaPlayer
import VLCKit
import SubtitleKit

/// An audio or subtitle track as libVLC lists it, with a name fit to show.
struct MediaTrack: Identifiable, Hashable {
    static let offID = "off"
    static let off = MediaTrack(id: offID, raw: "", language: nil)

    let id: String
    /// "English", "Signs & Songs", "Off".
    let title: String
    /// The language when the title names something else, e.g. "English" under "Signs & Songs".
    let detail: String?
    /// libVLC's own name, which choices are remembered by.
    let raw: String
    let language: String?

    /// libVLC names tracks "Track 1 - [Japanese]" or "Full Subtitles - [English]".
    init(id: String, raw: String, language: String?) {
        self.id = id
        self.raw = raw
        self.language = language
        if id == Self.offID {
            title = "Off"
            detail = nil
            return
        }
        var name = raw
        var label: String?
        if let open = raw.range(of: " - [", options: .backwards), raw.hasSuffix("]") {
            name = String(raw[..<open.lowerBound]).trimmingCharacters(in: .whitespaces)
            label = String(raw[open.upperBound..<raw.index(before: raw.endIndex)])
        } else if raw.hasPrefix("["), raw.hasSuffix("]") {
            name = ""
            label = String(raw.dropFirst().dropLast())
        }
        if label == nil, let code = language, !code.isEmpty, code != "und" {
            label = Locale.current.localizedString(forLanguageCode: code)
        }
        let generic = name.isEmpty || name.range(of: #"^Track \d+$"#, options: .regularExpression) != nil
        if generic, let label {
            title = label
            detail = nil
        } else {
            title = name.isEmpty ? (raw.isEmpty ? "Track" : raw) : name
            detail = label.flatMap { $0.caseInsensitiveCompare(name) == .orderedSame ? nil : $0 }
        }
    }

    var isSignsOnly: Bool { SubtitleLabels.isSignsOnly(name: raw) }
    var isEnglish: Bool {
        if let l = language?.lowercased(), ["en", "eng"].contains(l) || l.hasPrefix("en-") { return true }
        return raw.range(of: #"english|\beng\b|\ben\b"#, options: [.regularExpression, .caseInsensitive]) != nil
    }
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

/// libVLC behind a small observable surface: time, state, tracks, chapters, the video's size, Picture in
/// Picture and a connected TV.
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
    @Published private(set) var currentAudio = ""
    @Published private(set) var currentSubtitle = MediaTrack.offID
    @Published private(set) var chapters: [Chapter] = []
    @Published private(set) var subtitleDelay: Double = 0
    @Published private(set) var audioDelay: Double = 0
    @Published private(set) var rate: Float = 1
    @Published private(set) var videoSize: CGSize = .zero
    @Published private(set) var canPictureInPicture = false
    @Published private(set) var isPictureInPicture = false
    /// The video is showing on a TV rather than the phone.
    @Published private(set) var isOnTV = false

    let output: VideoOutput
    private let player: VLCMediaPlayer
    private let url: URL
    private let subtitleFiles: [URL]
    private let memoryKey: String
    private let preferDub: Bool
    private var timer: Timer?
    private var ticks = 0
    private var lastTime: Int32 = -1
    private var lastChange = Date()
    private var seekTarget: Double?
    private var seekDeadline = Date()
    private var tracksSettled = false
    private var chaptersLoaded = false
    private var startedAt = Date()
    private var hasPlayed = false
    /// Between asking libVLC to start again and it doing so, a stopped state isn't the end of the video.
    private var restarting = false

    /// - Parameter memoryKey: what audio and subtitle choices are remembered under, usually the show.
    init(request: PlaybackRequest, memoryKey: String) {
        let size = UserDefaults.standard.integer(forKey: SettingsKey.subtitleSize)
        let scale = SubtitleSize(rawValue: size)?.rawValue ?? SubtitleSize.medium.rawValue
        player = VLCMediaPlayer(options: ["--sub-text-scale=\(scale)"])
        output = VideoOutput(player: player)
        url = request.url
        subtitleFiles = request.subtitles.prefix(8).map(\.url)
        self.memoryKey = memoryKey
        preferDub = UserDefaults.standard.bool(forKey: SettingsKey.preferDub)

        player.drawable = output
        load(from: request.resumeAt)
        if let r = request.resumeAt, r > 0 { currentTime = r }

        output.onPiPReady = { [weak self] in
            MainActor.assumeIsolated { self?.canPictureInPicture = true }
        }
        output.onPiPChange = { [weak self] active in
            MainActor.assumeIsolated { self?.isPictureInPicture = active }
        }
    }

    private func load(from start: Double?) {
        guard let media = VLCMedia(url: url) else {
            errorText = "This video couldn’t be opened."
            return
        }
        // Generous network cache: the torrent may deliver in bursts.
        media.addOption(":network-caching=4000")
        media.addOption(":http-reconnect")
        media.addOption(preferDub ? ":audio-language=eng,en,jpn,ja" : ":audio-language=jpn,ja,eng,en")
        if !preferDub { media.addOption(":sub-language=eng,en,English") }
        if let start, start > 0 { media.addOption(":start-time=\(Int(start))") }
        player.media = media
        for s in subtitleFiles {
            player.addPlaybackSlave(s, type: .subtitle, enforce: false)
        }
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
        if isPictureInPicture { output.stopPictureInPicture() }
        if isOnTV { showOnTV(false) }
        let p = player
        DispatchQueue.global(qos: .userInitiated).async { p.stop() }
    }

    private func poll() {
        ticks += 1
        let state = player.state
        let t = player.time.intValue
        if t != lastTime { lastTime = t; lastChange = Date() }
        let idle = Date().timeIntervalSince(lastChange)

        if state == .playing { hasPlayed = true; restarting = false }
        if state == .error {
            if errorText == nil { errorText = "This video couldn’t be played." }
            isBuffering = false
            return
        }
        if (state == .stopped || state == .stopping) && hasPlayed && !restarting {
            if !didFinish {
                didFinish = true
                output.invalidatePlaybackState()
            }
            isPlaying = false
            isBuffering = false
            if duration > 0 { currentTime = duration }
            return
        }

        let playing = player.isPlaying
        if playing != isPlaying {
            isPlaying = playing
            output.invalidatePlaybackState()
        }
        isBuffering = state == .opening
            || (!hasPlayed && state == .nothingSpecial)
            || (playing && idle > 1.25)

        let len = player.media?.length.intValue ?? 0
        if len > 0 {
            let d = Double(len) / 1000
            if d != duration {
                duration = d
                output.invalidatePlaybackState()
            }
        }

        let now = Double(t) / 1000
        if let target = seekTarget {
            if abs(now - target) < 2.5 || Date() > seekDeadline { seekTarget = nil } else { currentTime = target }
        }
        if seekTarget == nil, t > 0 { currentTime = now }

        let size = player.videoSize
        if size.width > 0, size != videoSize { videoSize = size }

        if ticks % 4 == 0 || !tracksSettled { refreshTracks() }
        if !chaptersLoaded, duration > 0 { loadChapters() }
    }

    private func refreshTracks() {
        let audio = player.audioTracks
        let a = audio.map { MediaTrack(id: $0.trackId, raw: $0.trackName, language: $0.language) }
        if a != audioTracks { audioTracks = a }
        let selectedAudio = audio.first(where: { $0.isSelected })?.trackId ?? ""
        if selectedAudio != currentAudio { currentAudio = selectedAudio }

        let text = player.textTracks
        let s = text.isEmpty ? [] : [MediaTrack.off] + text.map { MediaTrack(id: $0.trackId, raw: $0.trackName, language: $0.language) }
        if s != subtitleTracks { subtitleTracks = s }
        let selectedText = text.first(where: { $0.isSelected })?.trackId ?? MediaTrack.offID
        if selectedText != currentSubtitle { currentSubtitle = selectedText }

        // Tracks appear once the file is open; give slaves a moment to load before choosing.
        if !tracksSettled, !audioTracks.isEmpty, currentTime > 0 || Date().timeIntervalSince(startedAt) > 6 {
            tracksSettled = true
            applyRememberedTracks()
        }
    }

    private func loadChapters() {
        let title = player.currentTitleIndex
        guard title >= 0 else { return }
        let list = player.chapterDescriptions(ofTitle: title)
        chaptersLoaded = true
        guard list.count > 1 else { return }
        chapters = list.enumerated().map { i, c in
            let offset = Double(c.timeOffset.intValue)
            let length = Double(c.durationTime.intValue)
            let name = c.name?.trimmingCharacters(in: .whitespaces) ?? ""
            return Chapter(id: i, name: name.isEmpty ? "Chapter \(i + 1)" : name,
                           start: offset / 1000, end: length > 0 ? (offset + length) / 1000 : nil)
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
            restart(from: target)
            return
        }
        player.position = target / duration
        markSeek(target)
    }

    func skip(by seconds: Double) {
        if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
        markSeek(max(0, duration > 0 ? min(currentTime + seconds, duration) : currentTime + seconds))
    }

    private func markSeek(_ target: Double) {
        seekTarget = target
        seekDeadline = Date().addingTimeInterval(4)
        currentTime = target
        lastChange = Date()
    }

    func replay() { restart(from: 0) }

    /// A stopped player can't seek; open the file again at `start`.
    private func restart(from start: Double) {
        didFinish = false
        restarting = true
        tracksSettled = false
        markSeek(start)
        let p = player
        DispatchQueue.global(qos: .userInitiated).async {
            p.stop()
            DispatchQueue.main.async { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load(from: start)
                    self.player.rate = self.rate
                    self.player.play()
                }
            }
        }
        isPlaying = true
    }

    func setRate(_ r: Float) { rate = r; player.rate = r }

    // MARK: Picture in Picture and TV

    func togglePictureInPicture() {
        if isPictureInPicture { output.stopPictureInPicture() } else { output.startPictureInPicture() }
    }

    /// Moves the video to a connected TV, or back to the phone.
    func showOnTV(_ on: Bool) {
        if on, let host = ExternalDisplay.shared.claim() {
            output.attach(external: host)
            isOnTV = true
        } else {
            output.attach(external: nil)
            ExternalDisplay.shared.release()
            isOnTV = false
        }
    }

    // MARK: tracks

    func selectAudio(_ id: String) {
        guard let track = player.audioTracks.first(where: { $0.trackId == id }) else { return }
        track.isSelectedExclusively = true
        currentAudio = id
        remember(audio: audioTracks.first { $0.id == id }?.raw)
    }

    func selectSubtitle(_ id: String) {
        applySubtitle(id)
        remember(subtitle: id == MediaTrack.offID ? Self.offChoice : subtitleTracks.first { $0.id == id }?.raw)
    }

    private func applySubtitle(_ id: String) {
        if id == MediaTrack.offID {
            player.deselectAllTextTracks()
        } else if let track = player.textTracks.first(where: { $0.trackId == id }) {
            track.isSelectedExclusively = true
        } else {
            return
        }
        currentSubtitle = id
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
            selectAudio(match.id)
        }
        if let s = saved["subtitle"] {
            if s == Self.offChoice {
                applySubtitle(MediaTrack.offID)
                return
            }
            if let match = subtitleTracks.first(where: { $0.raw == s && $0.id != MediaTrack.offID }) {
                if match.id != currentSubtitle { applySubtitle(match.id) }
                return
            }
        }
        // Releases often flag the signs track as default, which leaves dialogue untranslated.
        guard !preferDub, let current = subtitleTracks.first(where: { $0.id == currentSubtitle }), current.isSignsOnly else { return }
        let real = subtitleTracks.filter { $0.id != MediaTrack.offID && !$0.isSignsOnly }
        if let better = real.first(where: \.isEnglish) ?? real.first {
            applySubtitle(better.id)
        }
    }
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
