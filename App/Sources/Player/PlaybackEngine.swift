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
    /// libVLC has drawn its first picture (or, for a file without video, started playing). Until then the player
    /// shows the episode's artwork where the video goes.
    @Published private(set) var hasFirstFrame = false
    /// A seek the picture hasn't caught up with yet, in seconds: the player shows that spot's preview over the
    /// old frame until libVLC draws the new one.
    @Published private(set) var seekPending: Double?

    /// The keyframe nearest a time, within a distance (both in seconds), when the file's index is known. Seeks and
    /// skips land on keyframes when one is close: libVLC then decodes nothing before the spot, and the bytes there
    /// are the ones fetched ahead.
    var keyframeNear: ((Double, Double) -> Double?)?

    let output: VideoOutput
    /// The streaming server's port as it is now. iOS can take the server's socket while the app is away, and the
    /// server may come back on another port; the stream's address follows it.
    var streamPort: (() -> UInt16)?
    /// The streaming listener's generation; a stream opened under an older one is dead.
    var streamGeneration: (() -> Int)?
    private var openedGeneration = 0
    private let player: VLCMediaPlayer
    private var url: URL
    private var subtitleFiles: [URL]
    /// Subtitle files the viewer added, added again whenever the stream is reopened.
    private var importedSubtitles: [URL] = []
    private let memoryKey: String
    private let preferDub: Bool
    private var timer: Timer?
    private var ticks = 0
    private var lastTime: Int32 = -1
    private var lastChange = Date()
    private var seekTarget: Double?
    private var seekDeadline = Date()
    private var seekStarted: Date?
    private var lastState: VLCMediaPlayerState?
    private var tracedFirstFrame = false
    private var subtitlesAddedAt: Date?
    private var tracksSettled = false
    private var chaptersLoaded = false
    private var startedAt = Date()
    private var hasPlayed = false
    /// Between asking libVLC to start again and it doing so, a stopped state isn't the end of the video.
    private var restarting = false
    private var restartBegan = Date()
    /// Times the stream was reopened after ending early; reset once playback has run well for a while.
    private var recoveries = 0
    private var lastRecovery = Date.distantPast
    private static let maxRecoveries = 6
    /// Where the viewer left off last time, checked once the picture is up.
    private let resumeAt: Double?
    private var resumeChecked = false
    /// The reopened stream should stay paused (it opens paused, and is paused again if it starts anyway).
    private var restartPaused = false
    /// When the reopened media was handed to libVLC, and whether it has been seen opening since. libVLC stops
    /// asynchronously and VLCKit's state follows events, so until then the state may still be the old stream's.
    private var restartLoadedAt: Date?
    private var restartSeenOpening = false
    /// Delays to set again once a reopened stream is up; a new input starts without them.
    private var reapplyDelays = false
    /// Where the current input was opened with `:start-time`. libVLC adds it to every later seek and takes it off
    /// the length it reports (input.c ControlSetTime/ControlSetPosition, input_GetItemDuration), so seeks and the
    /// duration are converted through it.
    private var clipStart: Double = 0
    private let fileExtension: String
    private var mediaSetAt = Date()
    private var tracedFirstBytes = false
    /// The first time libVLC reported, before the first picture.
    private var timeSeen: Double?
    /// Pictures shown when the pending seek was asked for; a higher count is the new spot's picture.
    private var seekBaseline: UInt64 = 0
    private var seekAskedAt = Date()
    /// How far from the target libVLC may land and still count as there.
    private var seekTolerance = 2.5
    /// Polls libVLC's picture counters quickly while the first picture or a seek's picture is awaited.
    private var frameTimer: Timer?

    /// A play the viewer asked for and libVLC hasn't yet shown, with the time it was asked at.
    private var playRequest: (at: Date, time: Int32, fromForeground: Bool)?
    private var playRetries = 0
    /// A pause just asked for: libVLC pauses on its own queue, so its state lags for a moment.
    private var pauseRequestedAt: Date?
    private var foregroundAt = Date.distantPast
    private var leftWhilePlaying = false
    private var resumeAfterInterruption = false
    private var interruptionObserver: NSObjectProtocol?
    /// The decoder and display counters when last seen moving, and the media time then.
    private var videoStats: (decoded: UInt64, displayed: UInt64, time: Int32)?
    private var videoRepairs = 0
    private var lastVideoRepair = Date.distantPast

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
        resumeAt = request.resumeAt.flatMap { $0 > 0 ? $0 : nil }
        fileExtension = request.fileExtension

        player.drawable = output
        // Open on the keyframe at or before the resume point when the index was read ahead: nothing before the
        // spot has to be decoded, and the bytes there are the ones the warm-up fetched.
        let start = resumeAt.map { r in KeyframeIndexCache.shared.keyframeTime(atOrBefore: r, for: request, within: 10) ?? r }
        load(from: start, initial: true)
        if let r = resumeAt { currentTime = start ?? r }

        output.onPiPReady = { [weak self] in
            MainActor.assumeIsolated { self?.canPictureInPicture = true }
        }
        output.onPiPChange = { [weak self] active in
            MainActor.assumeIsolated { self?.pictureInPictureChanged(active) }
        }
        output.onPiPRestore = { [weak self] in
            MainActor.assumeIsolated {
                self?.restoringFromPiP = true
                self?.isPictureInPicture = false
            }
        }
        // PiP's own buttons go through play() and pause() like every other control.
        output.onPlay = { [weak self] in
            guard let self else { return }
            PlaybackEngine.onMain { self.play() }
        }
        output.onPause = { [weak self] in
            guard let self else { return }
            PlaybackEngine.onMain { self.pause() }
        }
    }

    private nonisolated static func onMain(_ work: @escaping @MainActor () -> Void) {
        if Thread.isMainThread {
            MainActor.assumeIsolated { work() }
        } else {
            DispatchQueue.main.async { MainActor.assumeIsolated { work() } }
        }
    }

    /// Keeps libVLC's plugin list loaded between players, so opening one doesn't build it again (module_InitBank
    /// rebuilds it whenever the last libVLC instance has gone). Cheap after the first call.
    nonisolated static func prepareLibrary() {
        DispatchQueue.global(qos: .utility).async { _ = VLCLibrary.shared() }
    }

    /// - Parameter initial: the first open. Its input exists as soon as the media is set, so the resume point is
    ///   a seek queued before it starts rather than `:start-time` (see `clipStart`). A reopened stream's input is
    ///   created only once the old one has stopped, so it uses `:start-time`.
    private func load(from start: Double?, paused: Bool = false, initial: Bool = false) {
        refreshStreamURL()
        guard let media = VLCMedia(url: url) else {
            errorText = "This video couldn’t be opened."
            return
        }
        // VLC buffers this much media at start and after every seek before showing a frame. The torrent engine
        // does the buffering, so VLC's own only adds delay.
        media.addOption(":network-caching=400")
        // A stall (a slow peer) makes libVLC raise its buffering by up to clock-jitter for the rest of the input,
        // so every later start and seek would wait longer. The torrent engine absorbs stalls; keep VLC's at 400 ms.
        media.addOption(":clock-jitter=0")
        // The stream's URL has no file name, so VLC would probe demuxers by priority (MP4 first, then the rest
        // reading the head each time). Name the right one, with any other as fallback.
        if let demux = Self.demuxer(forExtension: fileExtension) { media.addOption(":demux=\(demux),any") }
        // Picture counters (first frame, a seek's new frame) refresh every 50 ms instead of 250 ms.
        media.addOption(":stats-min-report-interval=50")
        media.addOption(":http-reconnect")
        media.addOption(preferDub ? ":audio-language=eng,en,jpn,ja" : ":audio-language=jpn,ja,eng,en")
        if !preferDub { media.addOption(":sub-language=eng,en,English") }
        let at = start.flatMap { $0 > 0 ? $0 : nil }
        let queueSeek = initial && at != nil && Self.setTimeSymbol != nil && libVLCPlayer() != nil
        clipStart = 0
        if let at, !queueSeek {
            media.addOption(":start-time=\(Int(at))")
            clipStart = Double(Int(at))
        }
        // Opens to the first picture and holds there (input.c MainLoop pauses before the first demux).
        if paused { media.addOption(":start-paused") }
        openedGeneration = streamGeneration?() ?? 0
        player.media = media
        mediaSetAt = Date()
        // A new input's counters start from nothing.
        seekBaseline = 0
        if initial { PlaybackTrace.shared.mark("player: media set") }
        if queueSeek, let at {
            // Applied by the input before its first frame, like :start-time, but on the nearest keyframe. Should it
            // not take, the resume check in poll() seeks there once playing.
            if setTime(at, fast: true) { PlaybackTrace.shared.mark(String(format: "player: opening at %.1fs", at)) }
        }
        watchFrames()
    }

    private static func demuxer(forExtension ext: String) -> String? {
        switch ext.lowercased() {
        case "mkv", "webm", "mk3d", "mka": return "mkv"
        case "mp4", "m4v", "mov": return "mp4"
        default: return nil
        }
    }

    /// Points the stream (and subtitle files from the torrent) at the server's current port; true if it moved.
    @discardableResult
    private func refreshStreamURL() -> Bool {
        guard let port = streamPort?(), port > 0, let moved = Self.url(url, onPort: port) else { return false }
        PlaybackTrace.shared.mark("stream server moved to port \(port)")
        url = moved
        subtitleFiles = subtitleFiles.map { Self.url($0, onPort: port) ?? $0 }
        return true
    }

    /// `url` on `port` if it's a loopback address on another port, else nil.
    private static func url(_ url: URL, onPort port: UInt16) -> URL? {
        guard var parts = URLComponents(url: url, resolvingAgainstBaseURL: false),
              parts.host == "127.0.0.1" || parts.host == "localhost",
              let old = parts.port, old != Int(port) else { return nil }
        parts.port = Int(port)
        return parts.url
    }

    /// Subtitle files beside the video, added once the picture is up: each is another read from the torrent, and
    /// at the start every read competes with the first frame.
    private func addSubtitleFiles() {
        for s in importedSubtitles {
            player.addPlaybackSlave(s, type: .subtitle, enforce: false)
        }
        guard !subtitleFiles.isEmpty else { return }
        for s in subtitleFiles {
            player.addPlaybackSlave(s, type: .subtitle, enforce: false)
        }
        subtitlesAddedAt = Date()
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
        // Posted on the main thread (AVAudioSession.interruptionNotification).
        interruptionObserver = NotificationCenter.default.addObserver(
            forName: AVAudioSession.interruptionNotification, object: AVAudioSession.sharedInstance(), queue: .main
        ) { [weak self] note in
            let type = (note.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt)
                .flatMap(AVAudioSession.InterruptionType.init(rawValue:))
            let options = AVAudioSession.InterruptionOptions(
                rawValue: note.userInfo?[AVAudioSessionInterruptionOptionKey] as? UInt ?? 0)
            MainActor.assumeIsolated {
                guard let self, let type else { return }
                self.audioInterrupted(began: type == .began, shouldResume: options.contains(.shouldResume))
            }
        }
    }

    func shutdown() {
        timer?.invalidate()
        timer = nil
        frameTimer?.invalidate()
        frameTimer = nil
        if let interruptionObserver { NotificationCenter.default.removeObserver(interruptionObserver) }
        interruptionObserver = nil
        output.shutdown()
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
        if state != lastState {
            lastState = state
            PlaybackTrace.shared.mark("player state \(Self.name(of: state)) at \(t) ms")
        }
        if !tracedFirstFrame, t > 0 {
            tracedFirstFrame = true
            PlaybackTrace.shared.mark("first frame \(String(format: "%.2f", Date().timeIntervalSince(startedAt)))s after the player opened")
            addSubtitleFiles()
        }

        if state == .playing { hasPlayed = true }
        if restarting, let loaded = restartLoadedAt {
            if state == .opening { restartSeenOpening = true }
            let current = restartSeenOpening || Date().timeIntervalSince(loaded) > 2
            // The viewer may have pressed play or pause while the stream was reopening.
            if state == .paused && !restartPaused {
                player.play()
            } else if state == .playing && restartPaused {
                player.pause()
            } else if current && (state == .playing || state == .paused) {
                restarting = false
                if reapplyDelays {
                    reapplyDelays = false
                    player.currentVideoSubTitleDelay = Int(subtitleDelay * 1_000_000)
                    player.currentAudioPlaybackDelay = Int(audioDelay * 1_000_000)
                }
            }
        }
        if restarting, Date().timeIntervalSince(restartBegan) > 20 { restarting = false }
        if recoveries > 0, state == .playing, Date().timeIntervalSince(lastRecovery) > 60 { recoveries = 0 }

        // A stream that stops short of the end didn't finish: the read from the torrent was cut off (a cold
        // swarm after a relaunch, a connection iOS closed while the app was away). Open it again where the
        // viewer was, rather than calling the episode over and saving it as watched.
        let ended = state == .stopped || state == .stopping
        if (state == .error || (ended && hasPlayed)) && !restarting {
            let at = currentTime
            let atEnd = duration > 0 && at >= duration - max(15, duration * 0.02)
            if !atEnd && recoveries < Self.maxRecoveries {
                recoveries += 1
                lastRecovery = Date()
                PlaybackTrace.shared.mark(String(format: "stream \(state == .error ? "failed" : "ended early") at %.1fs of %.0fs; reopening (try %d)",
                                                 at, duration, recoveries))
                isBuffering = true
                restart(from: at, after: recoveries == 1 ? 0 : Double(recoveries), paused: !isPlaying)
                return
            }
        }
        if state == .error {
            if errorText == nil { errorText = "This video couldn’t be played." }
            isBuffering = false
            return
        }
        if ended && hasPlayed && !restarting {
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
        if checkPlayRequest(playing: playing, state: state, time: t) { return }
        // What the controls show: what was asked for until libVLC catches up, else what libVLC reports.
        var shown = playing
        if restarting { shown = !restartPaused } else if playRequest != nil { shown = true }
        if let asked = pauseRequestedAt {
            if Date().timeIntervalSince(asked) < 1.5 { shown = false } else { pauseRequestedAt = nil }
        }
        if shown != isPlaying {
            isPlaying = shown
            output.invalidatePlaybackState()
        }
        let waitingForPlay = playRequest.map { !playing && Date().timeIntervalSince($0.at) > 0.5 } ?? false
        isBuffering = state == .opening
            || (!hasPlayed && state == .nothingSpecial)
            || (playing && idle > 1.25)
            || (restarting && !restartPaused)
            || waitingForPlay

        let len = player.media?.length.intValue ?? 0
        // A stream reopened with :start-time reports its length less the start; the length doesn't change, so
        // keep the one known.
        if len > 0, clipStart == 0 || duration == 0 {
            let d = Double(len) / 1000 + clipStart
            if d != duration {
                if duration == 0 { PlaybackTrace.shared.mark(String(format: "duration %.0fs", d)) }
                duration = d
                output.invalidatePlaybackState()
            }
        }

        let now = Double(t) / 1000
        if let target = seekTarget {
            if abs(now - target) < 2.5 || Date() > seekDeadline { seekTarget = nil } else { currentTime = target }
        }
        if let began = seekStarted, idle < 0.3, t != 0, state == .playing || !player.isPlaying {
            if abs(now - (seekTarget ?? now)) < 2.5 {
                seekStarted = nil
                PlaybackTrace.shared.mark(String(format: "seek settled at %.1fs after %.2fs", now, Date().timeIntervalSince(began)))
            }
        }
        if seekTarget == nil, t > 0 { currentTime = now }

        // libVLC sometimes ignores the start time (a file it can't seek in yet); go there once it can.
        if !resumeChecked, let r = resumeAt, duration > 0, t > 0, state == .playing {
            resumeChecked = true
            if r > 15, now < r - 15, r < duration - 5 {
                PlaybackTrace.shared.mark(String(format: "started at %.1fs instead of %.1fs; seeking there", now, r))
                move(to: r, fast: false)
                markSeek(r)
            }
        }

        let size = player.videoSize
        if size.width > 0, size != videoSize { videoSize = size }

        if ticks % 4 == 0 || !tracksSettled { refreshTracks() }
        if !chaptersLoaded, duration > 0 { loadChapters() }
        if ticks % 4 == 0 {
            output.reconcilePiP()
            checkVideo()
        }
    }

    /// Follows a play the viewer asked for. libVLC applies play on its input thread, and an input stuck on a
    /// stream that went away while the app was in the background never does: the button flips straight back to
    /// play and the picture stays black. Reopening the stream where it was gets it going. True if it reopened.
    private func checkPlayRequest(playing: Bool, state: VLCMediaPlayerState, time t: Int32) -> Bool {
        guard let request = playRequest, !restarting else { return false }
        let waited = Date().timeIntervalSince(request.at)
        if playing && t != request.time {
            playRequest = nil
            playRetries = 0
        } else if !playing && state == .paused && waited > 3 {
            playRequest = nil
            guard playRetries < 2 else { return false }
            playRetries += 1
            PlaybackTrace.shared.mark(String(format: "play didn't take: still paused %.1fs later; reopening at %.1fs (try %d)",
                                             waited, currentTime, playRetries))
            restart(from: currentTime)
            return true
        } else if request.fromForeground && playing && waited > 10 {
            // Playing in name only since coming back: the time hasn't moved at all.
            playRequest = nil
            guard playRetries < 1 else { return false }
            playRetries += 1
            PlaybackTrace.shared.mark(String(format: "playing but stuck at %.1fs since coming back; reopening", currentTime))
            restart(from: currentTime)
            return true
        } else if waited > 15 {
            playRequest = nil
        }
        return false
    }

    /// The picture can freeze while the sound plays on: the display layer fails (a failed layer drops every
    /// frame libVLC gives it) or the decoder stops producing pictures. Checked about once a second while the
    /// app is on screen and the video should be moving.
    private func checkVideo() {
        guard UIApplication.shared.applicationState == .active, hasPlayed, !restarting, !didFinish,
              videoTrackAway == nil, !isPictureInPicture, !output.isPiPEngaged else {
            videoStats = nil
            return
        }
        switch output.checkDisplayLayer() {
        case .fine:
            break
        case .flushed:
            PlaybackTrace.shared.mark("video: display layer had lost its decoder; flushed it")
        case .failed(let why):
            PlaybackTrace.shared.mark("video: display layer failed (\(why))")
            repairVideo()
            return
        }
        guard player.isPlaying, videoSize.width > 0, seekStarted == nil, let media = player.media else {
            videoStats = nil
            return
        }
        let stats = media.statistics
        let t = player.time.intValue
        guard let last = videoStats, last.decoded > 0,
              stats.decodedVideo == last.decoded, stats.displayedPictures == last.displayed else {
            videoStats = (stats.decodedVideo, stats.displayedPictures, t)
            return
        }
        // Counters still while the media time has moved on more than three seconds: the picture is frozen.
        if t - last.time > 3000 {
            PlaybackTrace.shared.mark(String(format: "video: no new pictures (decoded %llu, shown %llu) while time ran %.1fs",
                                             stats.decodedVideo, stats.displayedPictures, Double(t - last.time) / 1000))
            repairVideo()
        } else if t < last.time {
            videoStats = (stats.decodedVideo, stats.displayedPictures, t)
        }
    }

    /// Rebuilds the picture: switching the video track off and on gives libVLC a new display and decoder. If that
    /// doesn't hold, the stream is opened again where it was.
    private func repairVideo() {
        if Date().timeIntervalSince(lastVideoRepair) > 120 { videoRepairs = 0 }
        videoRepairs += 1
        lastVideoRepair = Date()
        videoStats = nil
        guard videoRepairs < 3, let track = player.videoTracks.first(where: { $0.isSelected }) else {
            PlaybackTrace.shared.mark(String(format: "video: still frozen; reopening at %.1fs", currentTime))
            restart(from: currentTime, paused: !isPlaying)
            return
        }
        PlaybackTrace.shared.mark("video: frozen; rebuilding the picture (try \(videoRepairs))")
        let id = track.trackId
        videoTrackAway = id
        player.deselectAllVideoTracks()
        DispatchQueue.main.asyncAfter(deadline: .now() + 0.3) { [weak self] in
            MainActor.assumeIsolated {
                // Gone to the background meanwhile: the picture comes back with the app.
                guard let self, self.videoTrackAway == id, UIApplication.shared.applicationState != .background else { return }
                self.videoTrackAway = nil
                self.restoreVideoTrack(id)
            }
        }
    }

    private static func name(of state: VLCMediaPlayerState) -> String {
        switch state {
        case .stopped: return "stopped"
        case .stopping: return "stopping"
        case .opening: return "opening"
        case .error: return "error"
        case .playing: return "playing"
        case .paused: return "paused"
        default: return "\(state.rawValue)"
        }
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

        // Tracks appear once the file is open; give subtitle files a moment to load before choosing.
        let ready: Bool
        if subtitleFiles.isEmpty {
            ready = currentTime > 0 || Date().timeIntervalSince(startedAt) > 6
        } else {
            ready = subtitlesAddedAt.map { Date().timeIntervalSince($0) > 1.5 } ?? (Date().timeIntervalSince(startedAt) > 20)
        }
        if !tracksSettled, !audioTracks.isEmpty, ready {
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
        activateAudioSession()
        pauseRequestedAt = nil
        resumeAfterInterruption = false
        if restarting {
            restartPaused = false
        } else {
            playRequest = (Date(), player.time.intValue, Date().timeIntervalSince(foregroundAt) < 30)
        }
        // Started from the Lock Screen: the picture stays off until the app is back, as when it left playing.
        if UIApplication.shared.applicationState == .background { hideVideoWhileAway() }
        player.play()
        isPlaying = true
    }

    func pause() {
        playRequest = nil
        resumeAfterInterruption = false
        pauseRequestedAt = Date()
        if restarting { restartPaused = true }
        player.pause()
        isPlaying = false
    }
    func togglePlay() { isPlaying ? pause() : play() }

    /// - Parameter fast: land on the nearest keyframe instead of decoding up to the exact time. Right for a
    ///   scrub, where the viewer picked a rough spot; wrong for skipping an intro or opening a chapter, unless a
    ///   keyframe is a fraction of a second away.
    func seek(to seconds: Double, fast: Bool = false) {
        guard duration > 0 else { return }
        var target = max(0, min(seconds, duration - 1))
        if didFinish {
            restart(from: target)
            return
        }
        // On a keyframe, nothing before the spot is decoded and the bytes are the ones fetched ahead.
        var keyed = fast
        if let k = keyframeNear?(target, fast ? 6 : 0.75) {
            target = k
            keyed = true
        }
        PlaybackTrace.shared.mark(String(format: "seek to %.1fs%@ from %.1fs", target, keyed ? " (keyframe)" : "", currentTime))
        move(to: target, fast: keyed)
        markSeek(target, tolerance: fast && target == seconds ? 10 : 2.5)
    }

    /// Skips from where playback is (or is going), as one absolute seek: libVLC's relative jumps are applied from
    /// the input's own clock and land wrong after a reopen. Lands on a keyframe when one is near the spot.
    func skip(by seconds: Double) {
        PlaybackTrace.shared.mark(String(format: "skip %+.0fs from %.1fs", seconds, currentTime))
        guard duration > 0, !didFinish else {
            if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
            markSeek(max(0, currentTime + seconds))
            return
        }
        let from = seekTarget ?? currentTime
        let target = max(0, min(from + seconds, duration - 1))
        if let k = keyframeNear?(target, 2.5), abs(k - from) >= 5, (k - from) * seconds > 0 {
            move(to: k, fast: true)
            markSeek(k)
        } else {
            move(to: target, fast: false)
            markSeek(target)
        }
    }

    /// Sends libVLC to `target` seconds into the file. A time before where the input was opened can't be
    /// reached in it (libVLC adds the start to every seek), so the stream is opened again there.
    private func move(to target: Double, fast: Bool) {
        if target < clipStart - 0.5 {
            restart(from: target, paused: !isPlaying)
            return
        }
        if setTime(target - clipStart, fast: fast) { return }
        let span = duration - clipStart
        if span > 0 { player.position = (target - clipStart) / span }
    }

    private func markSeek(_ target: Double, tolerance: Double = 2.5) {
        seekTarget = target
        seekDeadline = Date().addingTimeInterval(4)
        seekStarted = Date()
        currentTime = target
        lastChange = Date()
        seekPending = target
        seekTolerance = tolerance
        seekAskedAt = Date()
        seekBaseline = player.media?.statistics.displayedPictures ?? 0
        watchFrames()
    }

    // MARK: pictures

    private func watchFrames() {
        guard frameTimer == nil, !hasFirstFrame || seekPending != nil else { return }
        frameTimer = Timer.scheduledTimer(withTimeInterval: 1.0 / 30, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.checkFrames() }
        }
    }

    /// Notices the first picture and a seek's first new picture within a frame or two, from libVLC's counters.
    private func checkFrames() {
        guard let media = player.media else { return }
        let stats = media.statistics
        let t = Double(player.time.intValue) / 1000
        if !hasFirstFrame {
            if !tracedFirstBytes, stats.readBytes > 0 {
                tracedFirstBytes = true
                PlaybackTrace.shared.mark(String(format: "player: first bytes read %.2fs after media set",
                                                 Date().timeIntervalSince(mediaSetAt)))
            }
            // A file without video counts once it plays; so does one whose counters never move, once its clock has
            // run a while, so the artwork can't stay over a playing picture.
            if timeSeen == nil, t > 0 { timeSeen = t }
            let ranOn = timeSeen.map { t - $0 > 1.5 } ?? false
            let audioOnly = t > 0 && Date().timeIntervalSince(mediaSetAt) > 1.5 && stats.decodedVideo == 0
            if stats.displayedPictures > 0 || audioOnly || ranOn {
                hasFirstFrame = true
                PlaybackTrace.shared.mark(String(format: "player: first frame %.2fs after media set",
                                                 Date().timeIntervalSince(mediaSetAt)))
            }
        }
        if let target = seekPending {
            let waited = Date().timeIntervalSince(seekAskedAt)
            let there = abs(t - target) < seekTolerance
            // Paused, libVLC's counters don't move; the time reaching the spot is the sign.
            let paused = !player.isPlaying && !isPlaying
            // Pictures from before the jump may still be counted until the input gets there.
            if !there { seekBaseline = max(seekBaseline, stats.displayedPictures) }
            if (there && stats.displayedPictures > seekBaseline) || (paused && (there || waited > 1.5)) || waited > 8 {
                seekPending = nil
                PlaybackTrace.shared.mark(String(format: "seek: new picture at %.1fs after %.2fs", t, waited))
            }
        }
        if hasFirstFrame && seekPending == nil {
            frameTimer?.invalidate()
            frameTimer = nil
        }
    }

    private typealias SetTime = @convention(c) (UnsafeMutableRawPointer, Int64, Bool) -> Int32
    private typealias InstanceGetter = @convention(c) (AnyObject, Selector) -> UnsafeMutableRawPointer?

    /// VLCKit only seeks precisely; libVLC itself can seek to a keyframe, which needs no decoding past it.
    private static let setTimeSymbol: SetTime? = {
        guard let sym = dlsym(UnsafeMutableRawPointer(bitPattern: -2), "libvlc_media_player_set_time") else { return nil }
        return unsafeBitCast(sym, to: SetTime.self)
    }()

    private func libVLCPlayer() -> UnsafeMutableRawPointer? {
        let selector = NSSelectorFromString("libVLCMediaPlayer")
        guard player.responds(to: selector), let imp = player.method(for: selector) else { return nil }
        return unsafeBitCast(imp, to: InstanceGetter.self)(player, selector)
    }

    /// libvlc_media_player_set_time in the current input's own time (see `clipStart`); false if unavailable.
    private func setTime(_ seconds: Double, fast: Bool) -> Bool {
        guard let setTime = Self.setTimeSymbol, let instance = libVLCPlayer() else { return false }
        // libVLC 4 counts in microseconds (lib/libvlc_internal.h vlc_tick_from_libvlc_time).
        return setTime(instance, Int64(max(0, seconds) * 1_000_000), fast) == 0
    }

    func replay() { restart(from: 0) }

    /// Where the viewer got to, for remembering: the end once finished, and the old resume point until playback
    /// has actually reached it, so a slow or failed start never overwrites it with the opening seconds.
    var positionToSave: Double {
        if didFinish { return duration }
        if let r = resumeAt, !resumeChecked { return r }
        return currentTime
    }

    /// A stopped player can't seek; open the file again at `start`.
    /// - Parameter paused: open to the picture at `start` and wait there, rather than play.
    private func restart(from start: Double, after delay: Double = 0, paused: Bool = false) {
        didFinish = false
        restarting = true
        restartBegan = Date()
        restartPaused = paused
        restartLoadedAt = nil
        restartSeenOpening = false
        reapplyDelays = subtitleDelay != 0 || audioDelay != 0
        tracksSettled = false
        playRequest = nil
        videoStats = nil
        markSeek(start)
        let p = player
        DispatchQueue.global(qos: .userInitiated).async {
            p.stop()
            DispatchQueue.main.asyncAfter(deadline: .now() + delay) { [weak self] in
                MainActor.assumeIsolated {
                    guard let self else { return }
                    self.load(from: start, paused: self.restartPaused)
                    self.addSubtitleFiles()
                    self.player.rate = self.rate
                    self.player.play()
                    self.restartLoadedAt = Date()
                }
            }
        }
        isPlaying = !paused
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

    /// PiP is handing the picture back to the player screen, so the app is on its way to the foreground.
    private var restoringFromPiP = false

    private func pictureInPictureChanged(_ active: Bool) {
        isPictureInPicture = active
        // PiP closed while the app is away: the picture would otherwise go on drawing in the background.
        if !active, !restoringFromPiP, isPlaying, UIApplication.shared.applicationState == .background {
            hideVideoWhileAway()
        }
        restoringFromPiP = false
    }

    // MARK: leaving the app

    private var videoTrackAway: String?

    /// iOS lets nothing draw while the app is in the background, and libVLC's picture can stall for good if it
    /// tries, leaving sound over a frozen frame. Sound carries on alone; the picture comes back with the app.
    /// Paused, nothing draws, so the last frame stays: switching the track off then left a black screen to come
    /// back to, and a video output that had to be rebuilt from the next keyframe while paused.
    func appDidEnterBackground() {
        leftWhilePlaying = isPlaying
        guard isPlaying else {
            PlaybackTrace.shared.mark("background: paused, picture kept")
            return
        }
        hideVideoWhileAway()
    }

    private func hideVideoWhileAway() {
        guard !isPictureInPicture, !output.isPiPEngaged, !isOnTV, videoTrackAway == nil,
              let track = player.videoTracks.first(where: { $0.isSelected }) else { return }
        PlaybackTrace.shared.mark("background: video off")
        videoTrackAway = track.trackId
        player.deselectAllVideoTracks()
    }

    func appWillEnterForeground() {
        foregroundAt = Date()
        videoStats = nil
        if isPlaying { activateAudioSession() }
        // The server lost its socket while the app was away: the open stream is dead even if the port is the same.
        let moved = refreshStreamURL()
        let relistened = (streamGeneration?() ?? openedGeneration) != openedGeneration
        if moved || relistened, hasPlayed, !didFinish {
            PlaybackTrace.shared.mark(String(format: "foreground: stream server restarted; reopening at %.1fs", currentTime))
            videoTrackAway = nil
            restart(from: currentTime, paused: !isPlaying)
            return
        }
        guard let id = videoTrackAway else { return }
        videoTrackAway = nil
        // Paused while away (Lock Screen, an interruption): a video output rebuilt while paused can stay black,
        // so open the stream again to the picture where it stopped.
        if !isPlaying, hasPlayed, !didFinish, !restarting {
            PlaybackTrace.shared.mark(String(format: "foreground: paused with video off; reopening to the picture at %.1fs", currentTime))
            restart(from: currentTime, paused: true)
            return
        }
        PlaybackTrace.shared.mark("foreground: video on")
        restoreVideoTrack(id)
    }

    private func restoreVideoTrack(_ id: String) {
        player.videoTracks.first { $0.trackId == id }?.isSelectedExclusively = true
        // A track switched back on waits for the next keyframe; a seek to here shows the picture at once.
        if duration > 0, !didFinish {
            move(to: currentTime, fast: false)
            markSeek(currentTime)
        }
    }

    // MARK: audio session

    /// Takes the audio back after another app or a call had it. Only when about to play: activating a playback
    /// session stops other apps' audio.
    private func activateAudioSession() {
        do {
            try AVAudioSession.sharedInstance().setActive(true)
        } catch {
            PlaybackTrace.shared.mark("audio session didn't activate: \(error.localizedDescription)")
        }
    }

    /// A call, an alarm or another app's audio. libVLC only mutes itself (its audio output corks), so pause, and
    /// carry on afterwards if iOS says to.
    private func audioInterrupted(began: Bool, shouldResume: Bool) {
        if began {
            // iOS may deliver an interruption from while the app was suspended only once it's back.
            let stale = !leftWhilePlaying && Date().timeIntervalSince(foregroundAt) < 3
            guard isPlaying, !stale else { return }
            PlaybackTrace.shared.mark("audio interrupted; pausing")
            pause()
            resumeAfterInterruption = true
        } else {
            let resume = resumeAfterInterruption && shouldResume
            resumeAfterInterruption = false
            PlaybackTrace.shared.mark("audio interruption ended\(resume ? "; resuming" : "")")
            if resume { play() }
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
        importedSubtitles.append(url)
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
