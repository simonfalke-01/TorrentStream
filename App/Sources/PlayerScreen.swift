import SwiftUI
import AVKit
import TorrentKit
import CatalogKit
import SourceKit
#if canImport(MobileVLCKit)
import MobileVLCKit
#endif

enum VLCAvailability {
    static var isAvailable: Bool {
        #if canImport(MobileVLCKit)
        return true
        #else
        return false
        #endif
    }
}

/// Full-screen player. Owns the "current" request so Up Next can swap episodes in place.
struct PlayerScreen: View {
    @State private var current: PlaybackRequest

    init(request: PlaybackRequest) {
        _current = State(initialValue: request)
    }

    var body: some View {
        PlayerContainer(request: current) { next in current = next }
            .id(current.id)
            .preferredColorScheme(.dark)
            .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
            .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

// MARK: - Engine abstraction

struct MediaTrack: Identifiable, Hashable {
    let id: Int
    let name: String
}

/// Common playback surface for AVPlayer and libVLC so both share the same glass controls.
@MainActor
class PlayerBackend: ObservableObject {
    @Published var isPlaying = false
    @Published var isBuffering = true
    @Published var currentTime: Double = 0
    @Published var duration: Double = 0
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudio = -1
    @Published var currentSubtitle = -1
    @Published var subtitleDelay: Double = 0
    @Published var audioDelay: Double = 0
    @Published var rate: Float = 1
    @Published var errorText: String?
    @Published var didFinish = false

    var supportsDelays: Bool { false }
    var supportsExternalSubtitles: Bool { false }
    var supportsPiP: Bool { false }
    var supportsAirPlay: Bool { false }
    var view: UIView { UIView() }

    func start(at seconds: Double?) {}
    func play() {}
    func pause() {}
    func togglePlay() { isPlaying ? pause() : play() }
    func seek(to seconds: Double) {}
    func skip(by seconds: Double) { seek(to: currentTime + seconds) }
    func replay() { seek(to: 0); play() }
    func selectAudio(_ id: Int) {}
    func selectSubtitle(_ id: Int) {}
    func setSubtitleDelay(_ seconds: Double) {}
    func setAudioDelay(_ seconds: Double) {}
    func setRate(_ r: Float) {}
    func addSubtitleFile(_ url: URL) {}
    func startPiP() {}
    func shutdown() {}
}

// MARK: - AVPlayer engine

final class PlayerLayerView: UIView {
    override class var layerClass: AnyClass { AVPlayerLayer.self }
    var playerLayer: AVPlayerLayer { layer as! AVPlayerLayer }
}

final class AVBackend: PlayerBackend {
    private let player: AVPlayer
    private let item: AVPlayerItem
    private let surface = PlayerLayerView()
    private var pip: AVPictureInPictureController?
    private var timer: Timer?
    private var seeking = false
    private var tracksLoaded = false
    private var audioGroup: AVMediaSelectionGroup?
    private var legibleGroup: AVMediaSelectionGroup?

    init(url: URL) {
        item = AVPlayerItem(url: url)
        item.preferredForwardBufferDuration = 30
        player = AVPlayer(playerItem: item)
        player.automaticallyWaitsToMinimizeStalling = true
        super.init()
        surface.backgroundColor = .black
        surface.playerLayer.player = player
        surface.playerLayer.videoGravity = .resizeAspect
        if AVPictureInPictureController.isPictureInPictureSupported() {
            pip = AVPictureInPictureController(playerLayer: surface.playerLayer)
            pip?.canStartPictureInPictureAutomaticallyFromInline = true
        }
    }

    override var supportsPiP: Bool { pip != nil }
    override var supportsAirPlay: Bool { true }
    override var view: UIView { surface }

    override func start(at seconds: Double?) {
        try? AVAudioSession.sharedInstance().setCategory(.playback, mode: .moviePlayback)
        try? AVAudioSession.sharedInstance().setActive(true)
        if let s = seconds, s > 0 { seek(to: s) }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
    }

    private func poll() {
        let t = player.currentTime().seconds
        if !seeking, t.isFinite { currentTime = t }
        let d = item.duration.seconds
        if d.isFinite, d > 0 { duration = d }
        let waiting = player.timeControlStatus == .waitingToPlayAtSpecifiedRate
        isPlaying = player.rate != 0 || waiting
        isBuffering = item.status == .unknown || waiting
        if item.status == .failed {
            isBuffering = false
            errorText = item.error?.localizedDescription ?? "This format can't be played by the Apple player."
        }
        if item.status == .readyToPlay {
            if !tracksLoaded { tracksLoaded = true; Task { await loadTracks() } }
            if duration > 1, currentTime >= duration - 0.4, player.rate == 0, !didFinish {
                didFinish = true
                isPlaying = false
            }
        }
    }

    private func loadTracks() async {
        let asset = item.asset
        audioGroup = try? await asset.loadMediaSelectionGroup(for: .audible)
        legibleGroup = try? await asset.loadMediaSelectionGroup(for: .legible)
        refreshTracks()
    }

    private func refreshTracks() {
        let selection = item.currentMediaSelection
        if let g = audioGroup {
            audioTracks = g.options.enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
            currentAudio = selection.selectedMediaOption(in: g).flatMap { g.options.firstIndex(of: $0) } ?? -1
        }
        if let g = legibleGroup {
            subtitleTracks = [MediaTrack(id: -1, name: "Off")]
                + g.options.enumerated().map { MediaTrack(id: $0.offset, name: $0.element.displayName) }
            currentSubtitle = selection.selectedMediaOption(in: g).flatMap { g.options.firstIndex(of: $0) } ?? -1
        }
    }

    override func play() {
        didFinish = false
        player.play()
        player.rate = rate
        isPlaying = true
    }

    override func pause() { player.pause(); isPlaying = false }

    override func seek(to seconds: Double) {
        let target = max(0, duration > 0 ? min(seconds, duration - 0.5) : seconds)
        seeking = true
        currentTime = target
        didFinish = false
        player.seek(to: CMTime(seconds: target, preferredTimescale: 600)) { [weak self] _ in
            Task { @MainActor in self?.seeking = false }
        }
    }

    override func selectAudio(_ id: Int) {
        guard let g = audioGroup, g.options.indices.contains(id) else { return }
        item.select(g.options[id], in: g)
        currentAudio = id
    }

    override func selectSubtitle(_ id: Int) {
        guard let g = legibleGroup else { return }
        item.select(g.options.indices.contains(id) ? g.options[id] : nil, in: g)
        currentSubtitle = id
    }

    override func setRate(_ r: Float) {
        rate = r
        player.defaultRate = r
        if player.rate != 0 { player.rate = r }
    }

    override func startPiP() { pip?.startPictureInPicture() }

    override func shutdown() {
        timer?.invalidate()
        timer = nil
        player.pause()
        player.replaceCurrentItem(with: nil)
    }
}

struct AirPlayButton: UIViewRepresentable {
    func makeUIView(context: Context) -> AVRoutePickerView {
        let v = AVRoutePickerView()
        v.tintColor = .white
        v.activeTintColor = .systemBlue
        v.prioritizesVideoDevices = true
        return v
    }

    func updateUIView(_ uiView: AVRoutePickerView, context: Context) {}
}

// MARK: - VLC engine

#if canImport(MobileVLCKit)
final class VLCBackend: PlayerBackend {
    let player = VLCMediaPlayer()
    private let surface = UIView()
    private var timer: Timer?
    private var lastTime: Int32 = -1
    private var lastChange = Date()
    private var seekTarget: Double?
    private var seekDeadline = Date()

    init(request: PlaybackRequest) {
        super.init()
        surface.backgroundColor = .black
        let media = VLCMedia(url: request.url)
        // Generous network cache: the torrent may deliver in bursts.
        media.addOption(":network-caching=4000")
        media.addOption(":http-reconnect")
        if let r = request.resumeAt, r > 0 { media.addOption(":start-time=\(Int(r))") }
        player.media = media
        player.drawable = surface
        for s in request.subtitles {
            player.addPlaybackSlave(s.url, type: .subtitle, enforce: false)
        }
    }

    override var supportsDelays: Bool { true }
    override var supportsExternalSubtitles: Bool { true }
    override var view: UIView { surface }

    override func start(at seconds: Double?) {
        if let s = seconds, s > 0 { currentTime = s }
        player.play()
        isPlaying = true
        timer = Timer.scheduledTimer(withTimeInterval: 0.25, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.poll() }
        }
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
            errorText = "VLC couldn't play this stream."
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

        let aNames = player.audioTrackNames.compactMap { $0 as? String }
        let aIDs = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let a = zip(aIDs, aNames).map { MediaTrack(id: $0, name: $1) }
        if a != audioTracks { audioTracks = a }
        currentAudio = Int(player.currentAudioTrackIndex)

        let sNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let sIDs = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.intValue }
        let s = zip(sIDs, sNames).map { MediaTrack(id: $0, name: $0 == -1 ? "Off" : $1) }
        if s != subtitleTracks { subtitleTracks = s }
        currentSubtitle = Int(player.currentVideoSubTitleIndex)
    }

    override func play() { player.play(); isPlaying = true }
    override func pause() { player.pause(); isPlaying = false }

    override func seek(to seconds: Double) {
        guard duration > 0 else { return }
        let target = max(0, min(seconds, duration - 1))
        player.position = Float(target / duration)
        markSeek(target)
    }

    override func skip(by seconds: Double) {
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

    override func replay() {
        didFinish = false
        markSeek(0)
        let p = player
        DispatchQueue.global(qos: .userInitiated).async {
            p.stop()
            p.play()
        }
        isPlaying = true
    }

    override func selectAudio(_ id: Int) { player.currentAudioTrackIndex = Int32(id); currentAudio = id }
    override func selectSubtitle(_ id: Int) { player.currentVideoSubTitleIndex = Int32(id); currentSubtitle = id }

    override func setSubtitleDelay(_ seconds: Double) {
        subtitleDelay = seconds
        player.currentVideoSubTitleDelay = Int(seconds * 1_000_000)
    }

    override func setAudioDelay(_ seconds: Double) {
        audioDelay = seconds
        player.currentAudioPlaybackDelay = Int(seconds * 1_000_000)
    }

    override func setRate(_ r: Float) { rate = r; player.rate = r }

    override func addSubtitleFile(_ url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }

    override func shutdown() {
        timer?.invalidate()
        timer = nil
        let p = player
        DispatchQueue.global(qos: .userInitiated).async { p.stop() }
    }
}
#endif

struct PlayerSurface: UIViewRepresentable {
    let backend: PlayerBackend
    func makeUIView(context: Context) -> UIView { backend.view }
    func updateUIView(_ uiView: UIView, context: Context) {}
}

// MARK: - Torrent stats

/// Live torrent statistics for the file being played.
@MainActor
final class StreamStatsModel: ObservableObject {
    @Published var stream: StreamStatus?
    @Published var file: FileStatus?
    @Published var availability: [Double] = []
    private var timer: Timer?
    private var torrent: Torrent?
    private var fileIndex = 0

    var isComplete: Bool { file?.isComplete ?? false }

    func start(torrent: Torrent, fileIndex: Int) {
        self.torrent = torrent
        self.fileIndex = fileIndex
        update()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    func update() {
        guard let torrent else { return }
        stream = torrent.streamStatus(fileIndex: fileIndex)
        file = torrent.status().files.first { $0.file.index == fileIndex }
        availability = isComplete ? [1] : torrent.availability(fileIndex: fileIndex, buckets: 160)
    }

    func stop() { timer?.invalidate(); timer = nil }
}

// MARK: - Container

private struct PlayerContainer: View {
    let request: PlaybackRequest
    let onNext: (PlaybackRequest) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shows: ShowsModel
    @StateObject private var stats = StreamStatsModel()
    @State private var backend: PlayerBackend?
    @State private var engine: PlayerEngine = .apple

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let backend {
                PlayerChrome(request: request, backend: backend, stats: stats, engine: engine,
                             onNext: onNext, onSwitchEngine: switchEngine)
                    .id(ObjectIdentifier(backend))
            }
        }
        .onAppear {
            stats.start(torrent: request.torrent, fileIndex: request.file.index)
            guard backend == nil else { return }
            model.playbackStarted(request)
            shows.playbackStarted(request)
            engine = model.playerEngine
            let b = makeBackend(engine)
            backend = b
            b.start(at: request.resumeAt)
        }
        .onDisappear {
            stats.stop()
            if let b = backend {
                let position = b.didFinish ? b.duration : b.currentTime
                model.playbackEnded(torrent: request.torrent, file: request.file,
                                    positionSeconds: position, durationSeconds: b.duration)
                shows.playbackEnded(request, position: position, duration: b.duration)
                b.shutdown()
            }
        }
    }

    private func makeBackend(_ engine: PlayerEngine) -> PlayerBackend {
        #if canImport(MobileVLCKit)
        if engine == .vlc { return VLCBackend(request: request) }
        #endif
        return AVBackend(url: request.url)
    }

    private func switchEngine(_ newEngine: PlayerEngine) {
        let resume = backend?.currentTime ?? 0
        backend?.shutdown()
        engine = newEngine
        let b = makeBackend(newEngine)
        backend = b
        b.start(at: resume > 1 ? resume : nil)
    }
}

// MARK: - Glass controls

/// Player-only geometry. Controls float over video, so they use Liquid Glass.
private enum PlayerMetrics {
    static let control: CGFloat = 44
    static let skip: CGFloat = 60
    static let play: CGFloat = 80
    static let titleMaxWidth: CGFloat = 460
    static let panelMaxWidth: CGFloat = 880
    static let cardMaxWidth: CGFloat = 360
    static let skipFlash: CGFloat = 80
    static let skipFlashInset: CGFloat = 48
}

private struct PlayerChrome: View {
    let request: PlaybackRequest
    @ObservedObject var backend: PlayerBackend
    @ObservedObject var stats: StreamStatsModel
    let engine: PlayerEngine
    let onNext: (PlaybackRequest) -> Void
    let onSwitchEngine: (PlayerEngine) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shows: ShowsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var showControls = true
    @State private var showTracks = false
    @State private var scrub: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: SeekFlash?
    @State private var showResumed = false
    @State private var upNext: UpNextItem?
    @State private var resolvingNext = false
    @State private var versions: EpisodeTarget?
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var upNextDismissed = false

    private struct SeekFlash: Equatable {
        let id = UUID()
        let forward: Bool
    }

    var body: some View {
        ZStack {
            PlayerSurface(backend: backend).ignoresSafeArea()
            gestureLayer
            seekFlashView

            if backend.isBuffering && !showControls && backend.errorText == nil {
                bufferingPill.transition(.opacity)
            }

            if showControls && backend.errorText == nil {
                controls.transition(.opacity)
            }

            if backend.didFinish && backend.errorText == nil {
                finishedOverlay.transition(.opacity)
            }

            if let err = backend.errorText { errorPanel(err) }
        }
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: showControls)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: backend.didFinish)
        .animation(Motion.role(Motion.fast, reduce: reduceMotion), value: backend.isBuffering)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if request.resumeAt != nil { flashResumed() }
            scheduleHide()
        }
        .onDisappear { countdownTask?.cancel(); hideTask?.cancel() }
        .onChange(of: backend.didFinish) { _, done in
            if done { handleFinish() } else { cancelCountdown(); upNext = nil; upNextDismissed = false }
        }
        .onChange(of: backend.isPlaying) { _, playing in
            if playing { scheduleHide() } else { reveal(autoHide: false) }
        }
        .onChange(of: backend.duration > 0, initial: true) { _, known in
            guard known else { return }
            model.durationKnown(request, seconds: backend.duration)
            shows.prefetchNext(after: request, duration: backend.duration)
        }
        .sheet(isPresented: $showTracks) {
            TracksSheet(backend: backend, request: request)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $versions) { target in
            VersionsView(target: target, current: request.torrent.infoHashHex) { source in
                versions = nil
                switchVersion(target, to: source)
            }
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.top, Space.s)
            }
        }
    }

    // MARK: gestures

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(.rect)
                .onTapGesture(count: 2) { location in
                    guard !backend.didFinish else { return }
                    let forward = location.x > geo.size.width / 2
                    backend.skip(by: forward ? 10 : -10)
                    let flash = SeekFlash(forward: forward)
                    withAnimation(Motion.role(Motion.fast, reduce: reduceMotion)) { seekFlash = flash }
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(600))
                        if seekFlash == flash {
                            withAnimation(Motion.role(Motion.exit, reduce: reduceMotion)) { seekFlash = nil }
                        }
                    }
                }
                .onTapGesture {
                    if showControls { showControls = false } else { reveal() }
                }
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    @ViewBuilder
    private var seekFlashView: some View {
        if let flash = seekFlash {
            HStack {
                if flash.forward { Spacer() }
                Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
                    .font(.title.weight(.semibold))
                    .foregroundStyle(.white)
                    .frame(width: PlayerMetrics.skipFlash, height: PlayerMetrics.skipFlash)
                    .glassEffect(.clear, in: .circle)
                    .padding(.horizontal, PlayerMetrics.skipFlashInset)
                if !flash.forward { Spacer() }
            }
            .transition(.opacity)
            .allowsHitTesting(false)
            .accessibilityHidden(true)
        }
    }

    // MARK: controls

    private var controls: some View {
        ZStack {
            // Scrim so glass and text stay legible over bright video.
            LinearGradient(colors: [.black.opacity(0.5), .clear, .clear, .black.opacity(0.55)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                if showResumed, let at = request.resumeAt {
                    resumedPill(at)
                        .padding(.top, Space.m)
                        .transition(.opacity)
                }
                Spacer()
                if !backend.didFinish { centerControls }
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.s)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: Space.m) {
            HStack(spacing: Space.s) {
                GlassIconButton(systemImage: "xmark", label: "Close") { dismiss() }

                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(request.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    if let episode = request.episode {
                        Text(episode)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.8))
                            .lineLimit(1)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .frame(maxWidth: PlayerMetrics.titleMaxWidth, alignment: .leading)
                .glassEffect(.clear, in: .capsule)
                .accessibilityElement(children: .combine)

                Spacer(minLength: 0)

                GlassIconButton(systemImage: "captions.bubble", label: "Audio and Subtitles") {
                    showTracks = true
                    hideTask?.cancel()
                }
                if backend.supportsPiP {
                    GlassIconButton(systemImage: "pip.enter", label: "Picture in Picture") { backend.startPiP() }
                }
                if backend.supportsAirPlay {
                    AirPlayButton()
                        .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .accessibilityLabel("AirPlay")
                }
                moreMenu
            }
        }
    }

    private var moreMenu: some View {
        Menu {
            if let target = episodeTarget {
                Section {
                    Button {
                        hideTask?.cancel()
                        versions = target
                    } label: { Label("Choose Version…", systemImage: "slider.horizontal.3") }
                }
            }
            Section {
                Button {
                    backend.pause()
                    ExternalPlayer.openInVLC(request) { model.errorMessage = $0 }
                } label: { Label("Open in VLC", systemImage: "arrow.up.forward.app") }
                #if canImport(MobileVLCKit)
                Button {
                    onSwitchEngine(engine == .vlc ? .apple : .vlc)
                } label: {
                    Label(engine == .vlc ? "Use Apple Player" : "Use VLC Player", systemImage: "arrow.triangle.2.circlepath")
                }
                #endif
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.body.weight(.semibold))
                .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                .contentShape(.circle)
        }
        .foregroundStyle(.white)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel("More")
    }

    private var centerControls: some View {
        GlassEffectContainer(spacing: Space.xl) {
            HStack(spacing: Space.xl) {
                GlassIconButton(systemImage: "gobackward.10", label: "Back 10 Seconds",
                                size: PlayerMetrics.skip, font: .title2) {
                    backend.skip(by: -10); scheduleHide()
                }
                Button {
                    backend.togglePlay()
                    scheduleHide()
                } label: {
                    ZStack {
                        if backend.isBuffering && backend.isPlaying {
                            ProgressView().controlSize(.large).tint(.white)
                        } else {
                            Image(systemName: backend.isPlaying ? "pause.fill" : "play.fill")
                                .font(.largeTitle)
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: PlayerMetrics.play, height: PlayerMetrics.play)
                    .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.interactive(), in: .circle)
                .accessibilityLabel(backend.isPlaying ? "Pause" : "Play")
                GlassIconButton(systemImage: "goforward.10", label: "Forward 10 Seconds",
                                size: PlayerMetrics.skip, font: .title2) {
                    backend.skip(by: 10); scheduleHide()
                }
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: Space.s) {
            if let next = upNext, backend.didFinish, !upNextDismissed {
                upNextCard(next)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.opacity)
            }
            VStack(spacing: Space.xs) {
                StreamScrubber(progress: backend.duration > 0 ? backend.currentTime / backend.duration : 0,
                                availability: stats.availability,
                                duration: backend.duration,
                                scrub: $scrub) { fraction in
                    backend.seek(to: fraction * backend.duration)
                    scheduleHide()
                }
                .onChange(of: scrub != nil) { _, dragging in if dragging { hideTask?.cancel() } }

                HStack {
                    Text(Format.seconds(displayedTime))
                    Spacer()
                    speedMenu
                    Spacer()
                    Text("-" + Format.seconds(max(0, backend.duration - displayedTime)))
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, Space.l)
            .padding(.top, Space.xs)
            .padding(.bottom, Space.m)
            .glassEffect(.clear, in: .rect(cornerRadius: Radius.large))
        }
        .frame(maxWidth: PlayerMetrics.panelMaxWidth)
    }

    private var displayedTime: Double { scrub.map { $0 * backend.duration } ?? backend.currentTime }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { backend.rate }, set: { backend.setRate($0) })) {
                ForEach(PlaybackSpeed.all, id: \.self) { r in Text(PlaybackSpeed.label(r)).tag(r) }
            }
        } label: {
            Text(PlaybackSpeed.label(backend.rate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xs)
                .contentShape(.capsule)
        }
        .foregroundStyle(.white)
        .glassEffect(.clear.interactive(), in: .capsule)
        .accessibilityLabel("Playback Speed")
        .accessibilityValue(PlaybackSpeed.label(backend.rate))
    }

    private func resumedPill(_ at: Double) -> some View {
        HStack(spacing: Space.m) {
            Text("Resumed at \(Format.seconds(at))")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
            Button("Start Over") {
                backend.seek(to: 0)
                showResumed = false
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glass)
        }
        .padding(.leading, Space.l)
        .padding(.trailing, Space.xs)
        .padding(.vertical, Space.xs)
        .glassEffect(.regular, in: .capsule)
    }

    private var bufferingPill: some View {
        ProgressView()
            .controlSize(.large)
            .tint(.white)
            .frame(width: PlayerMetrics.play, height: PlayerMetrics.play)
            .glassEffect(.clear, in: .circle)
            .allowsHitTesting(false)
            .accessibilityLabel("Loading")
    }

    // MARK: end of playback

    private func upNextCard(_ next: UpNextItem) -> some View {
        VStack(alignment: .leading, spacing: Space.m) {
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text("Up Next")
                    .font(.subheadline.weight(.semibold))
                    .foregroundStyle(.white.opacity(0.8))
                Text(next.title)
                    .font(.headline)
                    .lineLimit(2)
                if let subtitle = next.subtitle, !subtitle.isEmpty {
                    Text(subtitle)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.8))
                        .lineLimit(1)
                }
            }
            HStack(spacing: Space.s) {
                Button { playNext() } label: {
                    if resolvingNext {
                        HStack(spacing: Space.s) {
                            ProgressView().tint(.white)
                            Text("Starting")
                        }
                    } else {
                        Label(countdown.map { "Play in \($0)" } ?? "Play", systemImage: "play.fill")
                            .monospacedDigit()
                    }
                }
                .buttonStyle(.glassProminent)
                .disabled(resolvingNext)
                Button("Cancel") {
                    cancelCountdown()
                    upNextDismissed = true
                }
                .buttonStyle(.glass)
                .disabled(resolvingNext)
            }
        }
        .padding(Space.l)
        .frame(maxWidth: PlayerMetrics.cardMaxWidth, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.large))
    }

    @ViewBuilder
    private var finishedOverlay: some View {
        if upNext == nil || upNextDismissed {
            GlassEffectContainer(spacing: Space.l) {
                HStack(spacing: Space.l) {
                    Button { backend.replay(); scheduleHide() } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise")
                    }
                    .buttonStyle(.glass)
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark")
                    }
                    .buttonStyle(.glassProminent)
                }
                .controlSize(.large)
            }
        }
    }

    private func handleFinish() {
        reveal(autoHide: false)
        upNextDismissed = false
        upNext = nextItem()
        guard upNext != nil, UserDefaults.standard.bool(forKey: SettingsKey.autoPlayNext) else { return }
        countdown = 8
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while let c = countdown, c > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                countdown = c - 1
            }
            if !Task.isCancelled { playNext() }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    /// The catalog's next episode for shows; the next video in the torrent for titles added by link.
    private func nextItem() -> UpNextItem? {
        if request.show != nil { return shows.upNextItem(after: request) }
        guard let file = model.nextPlayable(after: request.file, in: request.torrent) else { return nil }
        let label = model.episodeLabel(file)
        let name = model.episodeTitle(file)
        return UpNextItem(title: label ?? file.title, subtitle: label != nil && name != label ? name : nil) { [model, request] in
            model.playbackRequest(torrent: request.torrent, file: file)
        }
    }

    private func playNext() {
        cancelCountdown()
        guard let next = upNext, !resolvingNext else { return }
        resolvingNext = true
        Task { @MainActor in
            let req = await next.resolve()
            resolvingNext = false
            if let req {
                onNext(req)
            } else {
                upNextDismissed = true
                model.showToast("\(next.title) couldn’t be started", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    /// The catalog episode playing, for choosing another version of it.
    private var episodeTarget: EpisodeTarget? {
        guard let ctx = request.show, let d = shows.details[ctx.show.id], let s = d.season(id: ctx.seasonID),
              let e = s.episodes.first(where: { $0.number == ctx.episode }) else { return nil }
        return EpisodeTarget(details: d, season: s, episode: e)
    }

    /// Restarts the episode from another release at the same moment.
    private func switchVersion(_ target: EpisodeTarget, to source: EpisodeSource) {
        guard source.result.infoHash?.lowercased() != request.torrent.infoHashHex else { return }
        let at = backend.currentTime
        backend.pause()
        model.showToast("Switching to \(source.group ?? "another version")", systemImage: "arrow.triangle.2.circlepath")
        Task { @MainActor in
            do {
                let req = try await shows.request(target.details, target.season, target.episode, source: source,
                                                  resumeAt: at > 1 ? at : nil, status: { _ in })
                onNext(req)
            } catch {
                backend.play()
                model.showToast("That version couldn’t be started", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: errors

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: Space.l) {
            VStack(spacing: Space.s) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .font(.largeTitle)
                    .foregroundStyle(.yellow)
                    .accessibilityHidden(true)
                Text("Can’t Play This File").font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.8))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Space.s) {
                #if canImport(MobileVLCKit)
                if engine == .apple {
                    Button { onSwitchEngine(.vlc) } label: {
                        Text("Use VLC Player").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                #endif
                Button {
                    ExternalPlayer.openInVLC(request) { model.errorMessage = $0 }
                } label: {
                    Text("Open in VLC").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
                Button { dismiss() } label: {
                    Text("Close").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .foregroundStyle(.white)
        .padding(Space.xl)
        .frame(maxWidth: PlayerMetrics.cardMaxWidth)
        .glassEffect(.regular, in: .rect(cornerRadius: Radius.large))
    }

    // MARK: visibility

    private func reveal(autoHide: Bool = true) {
        showControls = true
        if autoHide { scheduleHide() } else { hideTask?.cancel() }
    }

    private func scheduleHide() {
        hideTask?.cancel()
        hideTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(4))
            guard !Task.isCancelled, backend.isPlaying, !showTracks, scrub == nil, !backend.didFinish else { return }
            showControls = false
        }
    }

    private func flashResumed() {
        showResumed = true
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(6))
            withAnimation(Motion.role(Motion.exit, reduce: reduceMotion)) { showResumed = false }
        }
    }
}

/// Speeds offered by the player, and how they are labelled.
enum PlaybackSpeed {
    static let all: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static func label(_ r: Float) -> String { String(format: "%g×", r) }
}

/// Circular Liquid Glass control used on top of video.
private struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = PlayerMetrics.control
    var font: Font = .body.weight(.semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .frame(width: size, height: size)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// Seek bar that also shows which parts of the video are already loaded,
/// so it's clear where seeking will play instantly.
struct StreamScrubber: View {
    let progress: Double
    let availability: [Double]
    let duration: Double
    @Binding var scrub: Double?
    let onCommit: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 32
    private let restingBar: CGFloat = 6
    private let activeBar: CGFloat = 12
    private let restingThumb: CGFloat = 14
    private let activeThumb: CGFloat = 22
    private let bubbleWidth: CGFloat = 56
    private let bubbleLift: CGFloat = 32

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = min(max(scrub ?? progress, 0), 1)
            let barHeight = scrub == nil ? restingBar : activeBar
            let thumb = scrub == nil ? restingThumb : activeThumb

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.2))
                Canvas { ctx, size in
                    guard !availability.isEmpty else { return }
                    let w = size.width / CGFloat(availability.count)
                    for (i, a) in availability.enumerated() where a > 0 {
                        let rect = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)
                        ctx.fill(Path(rect), with: .color(.white.opacity(0.2 + 0.25 * a)))
                    }
                }
                .clipShape(.capsule)
                Capsule().fill(.white).frame(width: max(barHeight, width * shown))
            }
            .frame(height: barHeight)
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.3), radius: 3)
                    .offset(x: width * shown - thumb / 2)
            }
            .overlay(alignment: .leading) {
                if let s = scrub, duration > 0 {
                    Text(Format.seconds(s * duration))
                        .font(.caption.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Space.s)
                        .padding(.vertical, Space.xs)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .offset(x: min(max(width * s - bubbleWidth / 2, 0), width - bubbleWidth), y: -bubbleLift)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(v.location.x / width, 0), 1) }
                    .onEnded { v in
                        onCommit(min(max(v.location.x / width, 0), 1))
                        scrub = nil
                    }
            )
            .animation(Motion.role(Motion.fast, reduce: reduceMotion), value: scrub == nil)
        }
        .frame(height: height)
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue("\(Format.seconds(progress * duration)) of \(Format.seconds(duration))")
        .accessibilityAdjustableAction { direction in
            let step = duration > 0 ? 10 / duration : 0
            onCommit(min(max(progress + (direction == .increment ? step : -step), 0), 1))
        }
    }
}

// MARK: - Tracks sheet

/// Audio track, subtitle track, delays, speed, and loading subtitle files.
struct TracksSheet: View {
    @ObservedObject var backend: PlayerBackend
    let request: PlaybackRequest
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    if backend.audioTracks.isEmpty {
                        Text("Default audio").foregroundStyle(.secondary)
                    }
                    ForEach(backend.audioTracks) { t in
                        trackRow(t.name, selected: t.id == backend.currentAudio) { backend.selectAudio(t.id) }
                    }
                }
                Section {
                    if backend.subtitleTracks.isEmpty {
                        Text("No subtitles found").foregroundStyle(.secondary)
                    }
                    ForEach(backend.subtitleTracks) { t in
                        trackRow(t.name, selected: t.id == backend.currentSubtitle) { backend.selectSubtitle(t.id) }
                    }
                    if backend.supportsExternalSubtitles {
                        Button { importing = true } label: { Label("Load Subtitle File…", systemImage: "doc.badge.plus") }
                        if !request.subtitles.isEmpty {
                            Menu {
                                ForEach(request.subtitles, id: \.self) { s in
                                    Button(s.name) { backend.addSubtitleFile(s.url) }
                                }
                            } label: {
                                Label("Subtitle Files (\(request.subtitles.count))", systemImage: "captions.bubble")
                            }
                        }
                    }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text(backend.supportsExternalSubtitles
                         ? "Embedded subtitles and subtitle files in the torrent appear here."
                         : "The Apple player shows only subtitles embedded in MP4 and MOV files. Use the VLC player in Settings for SRT, ASS and MKV.")
                }
                if backend.supportsDelays {
                    Section("Sync") {
                        Stepper(value: Binding(get: { backend.subtitleDelay }, set: { backend.setSubtitleDelay($0) }),
                                in: -60...60, step: 0.1) {
                            LabeledContent("Subtitle delay", value: String(format: "%+.1f s", backend.subtitleDelay))
                        }
                        Stepper(value: Binding(get: { backend.audioDelay }, set: { backend.setAudioDelay($0) }),
                                in: -10...10, step: 0.05) {
                            LabeledContent("Audio delay", value: String(format: "%+.2f s", backend.audioDelay))
                        }
                    }
                }
                Section("Playback Speed") {
                    Picker("Speed", selection: Binding(get: { backend.rate }, set: { backend.setRate($0) })) {
                        ForEach(PlaybackSpeed.all, id: \.self) { r in
                            Text(PlaybackSpeed.label(r)).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button("Done", role: .confirm) { dismiss() }
                }
            }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { backend.addSubtitleFile(dest) }
            }
        }
    }

    private func trackRow(_ name: String, selected: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack {
                Text(name).foregroundStyle(.primary)
                Spacer()
                if selected { Image(systemName: "checkmark").foregroundStyle(.tint) }
            }
        }
    }
}
