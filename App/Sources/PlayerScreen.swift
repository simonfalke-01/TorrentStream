import SwiftUI
import AVKit
import TorrentKit
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

private struct PlayerChrome: View {
    let request: PlaybackRequest
    @ObservedObject var backend: PlayerBackend
    @ObservedObject var stats: StreamStatsModel
    let engine: PlayerEngine
    let onNext: (PlaybackRequest) -> Void
    let onSwitchEngine: (PlayerEngine) -> Void

    @EnvironmentObject private var model: AppModel
    @Environment(\.dismiss) private var dismiss
    @State private var showControls = true
    @State private var showTracks = false
    @State private var scrub: Double?
    @State private var hideTask: Task<Void, Never>?
    @State private var seekFlash: SeekFlash?
    @State private var showResumed = false
    @State private var nextFile: TorrentFile?
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?
    @State private var upNextDismissed = false
    @State private var export: ExportItem?

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
                bufferingPill.transition(.opacity.combined(with: .scale(scale: 0.9)))
            }

            if showControls && backend.errorText == nil {
                controls.transition(.opacity)
            }

            if backend.didFinish && backend.errorText == nil {
                finishedOverlay.transition(.opacity.combined(with: .scale(scale: 0.95)))
            }

            if let err = backend.errorText { errorPanel(err) }
        }
        .animation(.easeInOut(duration: 0.25), value: showControls)
        .animation(.spring(duration: 0.35), value: backend.didFinish)
        .animation(.easeInOut(duration: 0.2), value: backend.isBuffering)
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if request.resumeAt != nil { flashResumed() }
            scheduleHide()
        }
        .onDisappear { countdownTask?.cancel(); hideTask?.cancel() }
        .onChange(of: backend.didFinish) { _, done in
            if done { handleFinish() } else { cancelCountdown(); nextFile = nil; upNextDismissed = false }
        }
        .onChange(of: backend.isPlaying) { _, playing in
            if playing { scheduleHide() } else { reveal(autoHide: false) }
        }
        .sheet(isPresented: $showTracks) {
            TracksSheet(backend: backend, request: request)
                .presentationDetents([.medium, .large])
        }
        .sheet(item: $export) { e in
            DocumentExporter(urls: e.urls) { ok in if ok { model.showToast("Saved to Files") } }.ignoresSafeArea()
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.top, 8)
            }
        }
    }

    // MARK: gestures

    private var gestureLayer: some View {
        GeometryReader { geo in
            Color.clear
                .contentShape(Rectangle())
                .onTapGesture(count: 2) { location in
                    guard !backend.didFinish else { return }
                    let forward = location.x > geo.size.width / 2
                    backend.skip(by: forward ? 10 : -10)
                    withAnimation(.spring(duration: 0.3)) { seekFlash = SeekFlash(forward: forward) }
                    let flash = seekFlash
                    Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(650))
                        if seekFlash == flash { withAnimation(.easeOut) { seekFlash = nil } }
                    }
                }
                .onTapGesture {
                    if showControls { showControls = false } else { reveal() }
                }
        }
        .ignoresSafeArea()
    }

    @ViewBuilder
    private var seekFlashView: some View {
        if let flash = seekFlash {
            HStack {
                if flash.forward { Spacer() }
                Image(systemName: flash.forward ? "goforward.10" : "gobackward.10")
                    .font(.system(size: 30, weight: .semibold))
                    .foregroundStyle(.white)
                    .frame(width: 84, height: 84)
                    .glassEffect(.clear, in: .circle)
                    .padding(.horizontal, 48)
                if !flash.forward { Spacer() }
            }
            .transition(.scale(scale: 0.7).combined(with: .opacity))
            .allowsHitTesting(false)
        }
    }

    // MARK: controls

    private var controls: some View {
        ZStack {
            LinearGradient(colors: [.black.opacity(0.55), .clear, .clear, .black.opacity(0.6)],
                           startPoint: .top, endPoint: .bottom)
                .ignoresSafeArea()
                .allowsHitTesting(false)

            VStack(spacing: 0) {
                topBar
                if showResumed, let at = request.resumeAt {
                    resumedPill(at).padding(.top, 10).transition(.move(edge: .top).combined(with: .opacity))
                }
                Spacer()
                if !backend.didFinish { centerControls }
                Spacer()
                bottomPanel
            }
            .padding(.horizontal, 16)
            .padding(.vertical, 8)
        }
        .foregroundStyle(.white)
    }

    private var topBar: some View {
        GlassEffectContainer(spacing: 12) {
            HStack(spacing: 10) {
                GlassIconButton(systemImage: "xmark", label: "Close") { dismiss() }

                VStack(alignment: .leading, spacing: 2) {
                    Text(request.file.fileName)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(1)
                    statsLine
                }
                .padding(.horizontal, 14)
                .padding(.vertical, 7)
                .frame(maxWidth: 460, alignment: .leading)
                .glassEffect(.clear, in: .capsule)

                Spacer(minLength: 0)

                GlassIconButton(systemImage: "captions.bubble", label: "Audio & Subtitles") {
                    showTracks = true
                    hideTask?.cancel()
                }
                if backend.supportsPiP {
                    GlassIconButton(systemImage: "pip.enter", label: "Picture in Picture") { backend.startPiP() }
                }
                if backend.supportsAirPlay {
                    AirPlayButton()
                        .frame(width: 44, height: 44)
                        .glassEffect(.clear.interactive(), in: .circle)
                        .accessibilityLabel("AirPlay")
                }
                moreMenu
            }
        }
    }

    @ViewBuilder
    private var statsLine: some View {
        Group {
            if stats.isComplete {
                Label("Downloaded · playing from device", systemImage: "checkmark.circle.fill")
            } else if let s = stats.stream {
                HStack(spacing: 10) {
                    Label("\(s.connectedPeers)", systemImage: "person.2.fill")
                    Label(Format.rate(s.downloadRate), systemImage: "arrow.down")
                    Label(Format.bytes(s.bufferedAhead) + " ahead", systemImage: "forward.fill")
                }
            }
        }
        .labelStyle(CompactLabelStyle())
        .font(.caption2.weight(.medium).monospacedDigit())
        .foregroundStyle(.white.opacity(0.8))
        .lineLimit(1)
    }

    private var moreMenu: some View {
        Menu {
            Button {
                backend.pause()
                ExternalPlayer.openInVLC(request) { model.errorMessage = $0 }
            } label: { Label("Open in VLC App", systemImage: "arrow.up.forward.app") }

            #if canImport(MobileVLCKit)
            Button {
                onSwitchEngine(engine == .vlc ? .apple : .vlc)
            } label: {
                Label(engine == .vlc ? "Switch to Apple Player" : "Switch to VLC Engine",
                      systemImage: "arrow.triangle.2.circlepath")
            }
            #endif

            Section {
                if stats.isComplete, let url = model.localURL(request.torrent, request.file) {
                    Button { export = ExportItem(urls: [url]) } label: { Label("Save to Files", systemImage: "folder") }
                    if PhotoSaver.canSave(request.file) {
                        Button { model.saveToPhotos(request.torrent, request.file) } label: {
                            Label("Save to Photos", systemImage: "photo.on.rectangle")
                        }
                    }
                    ShareLink(item: url) { Label("Share", systemImage: "square.and.arrow.up") }
                } else if model.isOfflineDownload(request.torrent, fileIndex: request.file.index) {
                    Label("Downloading \(Int((stats.file?.progress ?? 0) * 100))%", systemImage: "arrow.down.circle")
                    Button(role: .destructive) {
                        model.stopDownloading(request.torrent, fileIndex: request.file.index)
                    } label: { Label("Stop Downloading", systemImage: "stop.circle") }
                } else {
                    Button {
                        model.download(request.torrent, fileIndex: request.file.index)
                    } label: { Label("Download for Offline", systemImage: "arrow.down.circle") }
                }
            }

            Button { model.copyStreamLink(request.torrent, request.file) } label: {
                Label("Copy Stream Link", systemImage: "link")
            }
        } label: {
            Image(systemName: "ellipsis")
                .font(.system(size: 17, weight: .semibold))
                .frame(width: 44, height: 44)
                .contentShape(Circle())
        }
        .foregroundStyle(.white)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel("More")
    }

    private var centerControls: some View {
        GlassEffectContainer(spacing: 28) {
            HStack(spacing: 28) {
                GlassIconButton(systemImage: "gobackward.10", label: "Back 10 seconds", size: 60, font: .title2) {
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
                                .font(.system(size: 34, weight: .semibold))
                                .contentTransition(.symbolEffect(.replace))
                        }
                    }
                    .frame(width: 84, height: 84)
                    .contentShape(Circle())
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.interactive(), in: .circle)
                .accessibilityLabel(backend.isPlaying ? "Pause" : "Play")
                GlassIconButton(systemImage: "goforward.10", label: "Forward 10 seconds", size: 60, font: .title2) {
                    backend.skip(by: 10); scheduleHide()
                }
            }
        }
    }

    private var bottomPanel: some View {
        VStack(spacing: 8) {
            if let next = nextFile, backend.didFinish, !upNextDismissed {
                upNextCard(next).frame(maxWidth: .infinity, alignment: .trailing)
                    .transition(.move(edge: .trailing).combined(with: .opacity))
            }
            VStack(spacing: 4) {
                TorrentScrubber(progress: backend.duration > 0 ? backend.currentTime / backend.duration : 0,
                                availability: stats.availability,
                                duration: backend.duration,
                                scrub: $scrub) { fraction in
                    backend.seek(to: fraction * backend.duration)
                    scheduleHide()
                }
                .onChange(of: scrub != nil) { _, dragging in if dragging { hideTask?.cancel() } }

                HStack {
                    Text(Format.seconds(scrub.map { $0 * backend.duration } ?? backend.currentTime))
                    Spacer()
                    speedMenu
                    Spacer()
                    Text("-" + Format.seconds(max(0, backend.duration - (scrub.map { $0 * backend.duration } ?? backend.currentTime))))
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.9))
            }
            .padding(.horizontal, 18)
            .padding(.top, 6)
            .padding(.bottom, 10)
            .glassEffect(.clear, in: .rect(cornerRadius: 26))
        }
        .frame(maxWidth: 900)
    }

    private var speedMenu: some View {
        Menu {
            Picker("Speed", selection: Binding(get: { backend.rate }, set: { backend.setRate($0) })) {
                ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                    Text(String(format: "%g×", r)).tag(r)
                }
            }
        } label: {
            Text(String(format: "%g×", backend.rate))
                .font(.caption.weight(.semibold).monospacedDigit())
                .padding(.horizontal, 10)
                .padding(.vertical, 3)
                .glassEffect(.clear.interactive(), in: .capsule)
        }
        .foregroundStyle(.white)
        .accessibilityLabel("Playback speed")
    }

    private func resumedPill(_ at: Double) -> some View {
        HStack(spacing: 12) {
            Label("Resumed at \(Format.seconds(at))", systemImage: "clock.arrow.circlepath")
                .font(.subheadline.weight(.medium))
            Button("Start Over") {
                backend.seek(to: 0)
                withAnimation { showResumed = false }
            }
            .font(.subheadline.weight(.semibold))
            .buttonStyle(.glass)
        }
        .padding(.leading, 16)
        .padding(.trailing, 6)
        .padding(.vertical, 6)
        .glassEffect(.regular, in: .capsule)
    }

    private var bufferingPill: some View {
        HStack(spacing: 10) {
            ProgressView().tint(.white)
            VStack(alignment: .leading, spacing: 1) {
                Text("Buffering from peers…").font(.subheadline.weight(.semibold))
                if let s = stats.stream {
                    Text("\(s.connectedPeers) peers · \(Format.rate(s.downloadRate))")
                        .font(.caption.monospacedDigit())
                        .foregroundStyle(.white.opacity(0.75))
                }
            }
        }
        .foregroundStyle(.white)
        .padding(.horizontal, 18)
        .padding(.vertical, 12)
        .glassEffect(.clear, in: .capsule)
        .allowsHitTesting(false)
    }

    // MARK: end of playback

    private func upNextCard(_ next: TorrentFile) -> some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("UP NEXT").font(.caption.weight(.bold)).foregroundStyle(.white.opacity(0.7))
            Text(next.fileName).font(.headline).lineLimit(2)
            HStack(spacing: 10) {
                Button { playNext() } label: {
                    Label(countdown.map { "Play in \($0)" } ?? "Play Now", systemImage: "play.fill")
                        .contentTransition(.numericText(countsDown: true))
                }
                .buttonStyle(.glassProminent)
                Button("Cancel") {
                    cancelCountdown()
                    withAnimation { upNextDismissed = true }
                }
                .buttonStyle(.glass)
            }
        }
        .padding(18)
        .frame(maxWidth: 360, alignment: .leading)
        .glassEffect(.regular, in: .rect(cornerRadius: 26))
    }

    @ViewBuilder
    private var finishedOverlay: some View {
        if nextFile == nil || upNextDismissed {
            GlassEffectContainer(spacing: 16) {
                HStack(spacing: 16) {
                    Button { backend.replay(); scheduleHide() } label: {
                        Label("Replay", systemImage: "arrow.counterclockwise").padding(.horizontal, 6)
                    }
                    .buttonStyle(.glass)
                    Button { dismiss() } label: {
                        Label("Done", systemImage: "checkmark").padding(.horizontal, 6)
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
        nextFile = model.nextPlayable(after: request.file, in: request.torrent)
        guard nextFile != nil, UserDefaults.standard.bool(forKey: SettingsKey.autoPlayNext) else { return }
        countdown = 8
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while let c = countdown, c > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                withAnimation { countdown = c - 1 }
            }
            if !Task.isCancelled { playNext() }
        }
    }

    private func cancelCountdown() {
        countdownTask?.cancel()
        countdownTask = nil
        countdown = nil
    }

    private func playNext() {
        cancelCountdown()
        guard let next = nextFile else { return }
        onNext(model.playbackRequest(torrent: request.torrent, file: next))
    }

    // MARK: errors

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: 14) {
            Image(systemName: "exclamationmark.triangle.fill").font(.largeTitle).foregroundStyle(.yellow)
            Text(message).multilineTextAlignment(.center)
            #if canImport(MobileVLCKit)
            if engine == .apple {
                Button { onSwitchEngine(.vlc) } label: { Label("Play with VLC Engine", systemImage: "play.rectangle") }
                    .buttonStyle(.glassProminent)
            }
            #endif
            Button {
                ExternalPlayer.openInVLC(request) { model.errorMessage = $0 }
            } label: { Label("Open in VLC App", systemImage: "arrow.up.forward.app") }
                .buttonStyle(.glass)
            Button("Close") { dismiss() }.buttonStyle(.glass)
        }
        .foregroundStyle(.white)
        .padding(24)
        .frame(maxWidth: 360)
        .glassEffect(.regular, in: .rect(cornerRadius: 28))
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
            withAnimation { showResumed = false }
        }
    }
}

struct GlassIconButton: View {
    let systemImage: String
    let label: String
    var size: CGFloat = 44
    var font: Font = .system(size: 17, weight: .semibold)
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(font)
                .frame(width: size, height: size)
                .contentShape(Circle())
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

/// Seek bar that also paints which parts of the file are already downloaded.
struct TorrentScrubber: View {
    let progress: Double
    let availability: [Double]
    let duration: Double
    @Binding var scrub: Double?
    let onCommit: (Double) -> Void

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = min(max(scrub ?? progress, 0), 1)
            let barHeight: CGFloat = scrub == nil ? 6 : 12
            let thumb: CGFloat = scrub == nil ? 14 : 22

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.18))
                Canvas { ctx, size in
                    guard !availability.isEmpty else { return }
                    let w = size.width / CGFloat(availability.count)
                    for (i, a) in availability.enumerated() where a > 0 {
                        let rect = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)
                        ctx.fill(Path(rect), with: .color(.white.opacity(0.2 + 0.25 * a)))
                    }
                }
                .clipShape(Capsule())
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
                        .padding(.horizontal, 10)
                        .padding(.vertical, 5)
                        .glassEffect(.regular, in: .capsule)
                        .fixedSize()
                        .offset(x: min(max(width * s - 28, 0), width - 56), y: -30)
                }
            }
            .frame(maxHeight: .infinity)
            .contentShape(Rectangle())
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { v in scrub = min(max(v.location.x / width, 0), 1) }
                    .onEnded { v in
                        let f = min(max(v.location.x / width, 0), 1)
                        onCommit(f)
                        scrub = nil
                    }
            )
            .animation(.spring(duration: 0.25), value: scrub == nil)
        }
        .frame(height: 30)
        .accessibilityElement()
        .accessibilityLabel("Playback position")
        .accessibilityValue(Format.seconds(progress * duration))
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
                                Label("Subtitle Files in Torrent (\(request.subtitles.count))", systemImage: "captions.bubble")
                            }
                        }
                    }
                } header: {
                    Text("Subtitles")
                } footer: {
                    Text(backend.supportsExternalSubtitles
                         ? "Embedded subtitles (MKV/MP4) and subtitle files shipped in the torrent appear here automatically."
                         : "The Apple player only shows subtitles embedded in MP4/MOV files. Switch to the VLC engine for .srt/.ass files and MKV.")
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
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in
                            Text(String(format: "%g×", r)).tag(r)
                        }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .confirmationAction) {
                    Button(role: .confirm) { dismiss() }
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
