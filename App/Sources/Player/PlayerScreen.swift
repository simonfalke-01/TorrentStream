import SwiftUI
import TorrentKit
import CatalogKit
import SourceKit
import SkipKit

/// Full-screen player. Owns the request playing now so the next episode, another episode or another version
/// can take its place without leaving.
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

// MARK: - Torrent stats

/// Which parts of the file are loaded, for the timeline.
@MainActor
final class StreamStatsModel: ObservableObject {
    @Published var availability: [Double] = []
    private var timer: Timer?
    private var torrent: Torrent?
    private var fileIndex = 0

    func start(torrent: Torrent, fileIndex: Int) {
        self.torrent = torrent
        self.fileIndex = fileIndex
        update()
        timer?.invalidate()
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            Task { @MainActor in self?.update() }
        }
    }

    /// The player is waiting for data; the swarm is written to the playback log meanwhile.
    var isWaiting = false

    func update() {
        guard let torrent else { return }
        let status = torrent.status()
        let complete = status.files.first { $0.file.index == fileIndex }?.isComplete ?? false
        availability = complete ? [1] : torrent.availability(fileIndex: fileIndex, buckets: 160)
        if isWaiting {
            PlaybackTrace.shared.mark(String(format: "waiting: %d peers of %d known, %.0f KB/s",
                                             status.connectedPeers, status.knownPeers, status.downloadRate / 1024))
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

// MARK: - Container

/// Starts and stops playback and records where the viewer got to.
private struct PlayerContainer: View {
    let request: PlaybackRequest
    let onNext: (PlaybackRequest) -> Void
    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shows: ShowsModel
    @StateObject private var stats = StreamStatsModel()
    @StateObject private var secondary = SecondarySubtitles()
    @State private var engine: PlaybackEngine?
    @State private var previews: SeekPreviews?
    @State private var nowPlaying = NowPlaying()
    @State private var backgroundTask: Task<Void, Never>?
    /// Held in state so re-rendering doesn't restart it.
    @State private var saveTimer = Timer.publish(every: 10, on: .main, in: .common).autoconnect()
    @Environment(\.scenePhase) private var scenePhase

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine, let previews {
                PlayerChrome(request: request, engine: engine, stats: stats, secondary: secondary, previews: previews,
                             onNext: onNext)
            }
        }
        .onAppear {
            stats.start(torrent: request.torrent, fileIndex: request.file.index)
            guard engine == nil else { return }
            model.playbackStarted(request)
            shows.playbackStarted(request)
            let key = request.show.map { "show.\($0.show.id)" } ?? "torrent.\(request.torrent.infoHashHex)"
            let e = PlaybackEngine(request: request, memoryKey: key)
            previews = SeekPreviews(torrent: request.torrent, fileIndex: request.file.index,
                                    fileLength: request.file.length, fileExtension: request.file.fileExtension)
            engine = e
            e.start()
            e.showOnTV(ExternalDisplay.shared.isConnected)
            secondary.prepare(request)
            nowPlaying.activate(engine: e, title: request.title, subtitle: request.episode)
        }
        .onReceive(ExternalDisplay.shared.$isConnected.dropFirst()) { connected in
            engine?.showOnTV(connected)
        }
        .onReceive(saveTimer) { _ in
            if engine?.isPlaying == true { saveProgress() }
        }
        .onChange(of: scenePhase) { _, phase in
            backgroundTask?.cancel()
            if phase != .active { saveProgress() }
            switch phase {
            case .background:
                // Picture in Picture starts as the app leaves; give it a moment to say so.
                backgroundTask = Task { @MainActor in
                    try? await Task.sleep(for: .milliseconds(400))
                    guard !Task.isCancelled else { return }
                    engine?.appDidEnterBackground()
                }
            case .active:
                engine?.appWillEnterForeground()
            default:
                break
            }
        }
        .onDisappear {
            backgroundTask?.cancel()
            previews?.stop()
            stats.stop()
            secondary.shutdown()
            nowPlaying.deactivate()
            if let e = engine {
                let position = e.positionToSave
                model.playbackEnded(torrent: request.torrent, file: request.file,
                                    positionSeconds: position, durationSeconds: e.duration)
                shows.playbackEnded(request, position: position, duration: e.duration)
                e.shutdown()
            }
        }
    }

    /// Remembers the position as playback goes, so a closed or killed app still resumes in the right place.
    private func saveProgress() {
        guard let e = engine, e.duration > 0, !e.didFinish else { return }
        let position = e.positionToSave
        guard position > 0 else { return }
        model.playbackProgressed(torrent: request.torrent, file: request.file, positionSeconds: position, durationSeconds: e.duration)
        shows.playbackEnded(request, position: position, duration: e.duration)
    }
}

// MARK: - Chrome

/// Everything drawn over the video. Three tiers: the video itself; the timeline and play controls, which come
/// and go; and the few things that matter at a given moment (Skip Intro, the next episode), which stay.
private struct PlayerChrome: View {
    let request: PlaybackRequest
    @ObservedObject var engine: PlaybackEngine
    @ObservedObject var stats: StreamStatsModel
    @ObservedObject var secondary: SecondarySubtitles
    @ObservedObject var previews: SeekPreviews
    let onNext: (PlaybackRequest) -> Void

    @EnvironmentObject private var model: AppModel
    @EnvironmentObject private var shows: ShowsModel
    @Environment(\.dismiss) private var dismiss
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    @State private var showControls = true
    @State private var hideTask: Task<Void, Never>?
    @State private var panel: PlayerPanel?
    @State private var scrub: Double?
    @State private var seekFlash: SeekFlash?
    @State private var flashTask: Task<Void, Never>?
    /// Seconds of double-tap seeking not yet sent to the player; a run of taps becomes one seek.
    @State private var pendingSeek: Double = 0
    @State private var lastTap: (time: Date, forward: Bool)?
    @State private var singleTapTask: Task<Void, Never>?
    @State private var showResumed = false
    @State private var fill = false
    @State private var locked = false
    @State private var showUnlock = false
    @State private var importing = false
    @State private var versions: EpisodeTarget?

    @State private var upNext: UpNextItem?
    @State private var nextDismissed = false
    @State private var resolvingNext = false
    @State private var countdown: Int?
    @State private var countdownTask: Task<Void, Never>?

    @State private var skips: [SkipSegment] = []
    @State private var catalogSkips: [SkipSegment] = []
    /// The opening and ending found in the episode's audio.
    @StateObject private var contentSkips = ContentSkipsModel()

    /// Seconds played without stalling; the next episode is fetched only once playback has settled.
    @State private var steadySeconds = 0
    @State private var seekWantTask: Task<Void, Never>?
    @State private var scrubRestTask: Task<Void, Never>?
    private static let steadyBeforePrefetch = 20

    @State private var sleep: SleepTimer = .off
    @State private var sleepTask: Task<Void, Never>?

    enum SleepTimer: Hashable {
        case off, minutes(Int), endOfEpisode
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            let compact = geo.size.width < PlayerMetrics.compactWidth
            ZStack {
                video
                if let place = elsewhere, !controlsVisible { elsewhereNote(place).transition(.opacity) }
                gestureLayer

                if let flash = seekFlash {
                    SeekFeedbackView(flash: flash).id(flash.forward).transition(.opacity)
                }

                if engine.isBuffering && !showControls && engine.errorText == nil && !engine.didFinish {
                    ProgressView()
                        .controlSize(.large)
                        .tint(.white)
                        .allowsHitTesting(false)
                        .accessibilityLabel("Loading")
                        .transition(.opacity)
                }

                if controlsVisible {
                    scrim.transition(.opacity)
                    if !engine.didFinish { centerControls.transition(.opacity) }
                }

                // Top: leave and where the picture goes. Bottom, read from the bottom up: time, the timeline, what
                // is playing beside what can be done to it, and above all of it, the one thing that matters at
                // this moment. Hidden controls give their space back, so the moment settles into the corner.
                VStack(spacing: 0) {
                    if controlsVisible {
                        topBar.transition(.opacity)
                    }
                    secondSubtitle
                    Spacer(minLength: 0)
                    momentRow
                    if controlsVisible {
                        bottomBar(compact: compact)
                            .padding(.top, Space.l)
                            .transition(.opacity)
                    }
                }
                .padding(.horizontal, compact ? Space.l : PlayerMetrics.wideMargin)
                .padding(.vertical, Space.s)

                if engine.didFinish && (upNext == nil || nextDismissed) && engine.errorText == nil && panel == nil {
                    finishedOverlay.transition(.opacity)
                }

                if let panel {
                    panelLayer(panel, landscape: landscape, size: geo.size)
                        .transition(.move(edge: landscape ? .trailing : .bottom).combined(with: .opacity))
                }

                if locked { lockLayer }

                if let err = engine.errorText { errorPanel(err) }
            }
            .frame(width: geo.size.width, height: geo.size.height)
        }
        .foregroundStyle(.white)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: showControls)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: panel)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: engine.didFinish)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: momentID)
        .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: showResumed)
        .animation(Motion.role(Motion.fast, reduce: reduceMotion), value: engine.isBuffering)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if request.resumeAt != nil { flashResumed() }
            upNext = nextItem()
            scheduleHide()
            contentSkips.start(request) { [shows, request] in shows.preparedNext(after: request) }
        }
        .onDisappear {
            seekWantTask?.cancel()
            scrubRestTask?.cancel()
            request.torrent.clearWants(tag: Self.seekTag)
            request.torrent.clearWants(tag: Self.skipsTag)
            contentSkips.stop()
            countdownTask?.cancel()
            hideTask?.cancel()
            sleepTask?.cancel()
            singleTapTask?.cancel()
            flashTask?.cancel()
        }
        .onChange(of: engine.didFinish) { _, done in
            if done { handleFinish() } else { cancelCountdown() }
        }
        .onChange(of: engine.isPlaying) { _, playing in
            if playing { scheduleHide() } else if !locked { reveal(autoHide: false) }
        }
        .onChange(of: engine.duration > 0, initial: true) { _, known in
            guard known else { return }
            model.durationKnown(request, seconds: engine.duration)
            previews.start(duration: engine.duration)
            loadSkips()
        }
        .onChange(of: Int(engine.currentTime)) {
            // Going back before the ending brings the card back the next time the ending comes round.
            if nextDismissed, !engine.didFinish, engine.duration > 0,
               engine.currentTime < (creditsStart ?? engine.duration) - 2 {
                nextDismissed = false
            }
            guard engine.isPlaying, !engine.isBuffering, engine.duration > 0 else { return }
            steadySeconds += 1
            if steadySeconds == Self.steadyBeforePrefetch {
                model.playbackSteady(request, seconds: engine.duration)
                shows.prefetchNext(after: request, duration: engine.duration)
            }
        }
        .onChange(of: engine.chapters) {
            updateSkips()
            contentSkips.setChapters(engine.chapters.map { (name: $0.name, start: $0.start, end: $0.end) },
                                     duration: engine.duration)
        }
        .onChange(of: contentSkips.content) { updateSkips() }
        .onChange(of: engine.isBuffering, initial: true) { _, waiting in
            stats.isWaiting = waiting
            PlaybackTrace.shared.mark(waiting ? "waiting for data" : "playing")
        }
        .onChange(of: Int(engine.currentTime * 4)) { secondary.update(time: engine.currentTime) }
        .onChange(of: panel) { _, p in if p == nil { scheduleHide() } else { hideTask?.cancel() } }
        .sheet(item: $versions) { target in
            VersionsView(target: target, current: request.torrent.infoHashHex) { source in
                versions = nil
                switchVersion(target, to: source)
            }
        }
        .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
            importSubtitle(result)
        }
        .overlay(alignment: .top) {
            if let toast = model.toast {
                ToastView(toast: toast).padding(.top, Space.s)
            }
        }
    }

    private var controlsVisible: Bool { showControls && panel == nil && !locked && engine.errorText == nil }

    /// Where the picture is when it isn't on this screen.
    private var elsewhere: (title: String, systemImage: String)? {
        if engine.isOnTV { return ("Playing on TV", "tv") }
        if engine.isPictureInPicture { return ("Playing in Picture in Picture", "pip") }
        return nil
    }

    private func elsewhereNote(_ place: (title: String, systemImage: String)) -> some View {
        VStack(spacing: Space.m) {
            Image(systemName: place.systemImage)
                .font(.system(size: 44, weight: .light))
            Text(place.title)
                .font(.subheadline.weight(.medium))
        }
        .foregroundStyle(.white.opacity(0.55))
        .allowsHitTesting(false)
        .accessibilityElement(children: .combine)
    }

    // MARK: video

    /// Fill crops the video to the screen; Fit shows all of it. Measured edge to edge, not within the safe area,
    /// so the picture is centered on the physical screen.
    private var video: some View {
        GeometryReader { geo in
            let size = geo.size
            let zoom = fillZoom(screen: size)
            VideoSurface(output: engine.output)
                .scaleEffect(zoom)
                .frame(width: size.width, height: size.height)
                // Clip to the full screen here; clipping after ignoresSafeArea would cut the picture to the safe
                // area and leave a black strip over the home indicator.
                .clipped()
                .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: zoom)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    private func fillZoom(screen size: CGSize) -> CGFloat {
        let v = engine.videoSize
        guard fill, v.width > 0, v.height > 0, size.width > 0, size.height > 0 else { return 1 }
        let fit = min(size.width / v.width, size.height / v.height)
        let cover = max(size.width / v.width, size.height / v.height)
        return cover / fit
    }

    private var scrim: some View {
        LinearGradient(stops: [.init(color: .black.opacity(0.45), location: 0),
                               .init(color: .black.opacity(0.15), location: 0.25),
                               .init(color: .black.opacity(0.15), location: 0.6),
                               .init(color: .black.opacity(0.7), location: 1)],
                       startPoint: .top, endPoint: .bottom)
            .ignoresSafeArea()
            .allowsHitTesting(false)
    }

    // MARK: gestures

    private var gestureLayer: some View {
        GeometryReader { geo in
            gestures(width: geo.size.width)
        }
        .ignoresSafeArea()
        .accessibilityHidden(true)
    }

    /// One tap recognizer, timed by hand: a single tap waits a beat in case a second follows, and while a seek run
    /// is showing, every tap on that side adds to it at once.
    private func gestures(width: CGFloat) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture(coordinateSpace: .local) { location in
                handleTap(at: location, width: width)
            }
            .gesture(
                MagnifyGesture().onEnded { v in
                    guard !locked else { return }
                    if v.magnification > 1.08 { fill = true } else if v.magnification < 0.92 { fill = false }
                }
            )
    }

    private static let doubleTapWindow: TimeInterval = 0.3

    private func handleTap(at location: CGPoint, width: CGFloat) {
        if locked { flashUnlock(); return }
        if panel != nil { panel = nil; return }

        let forward = location.x > width / 2
        let canSeek = !engine.didFinish && engine.duration > 0
        let continuesRun = seekFlash?.forward == forward
        let isDouble = lastTap.map { $0.forward == forward && Date().timeIntervalSince($0.time) < Self.doubleTapWindow } ?? false

        if canSeek && (continuesRun || isDouble) {
            singleTapTask?.cancel()
            lastTap = nil
            addSeek(forward: forward)
            return
        }

        lastTap = (Date(), forward)
        singleTapTask?.cancel()
        singleTapTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(Self.doubleTapWindow))
            guard !Task.isCancelled else { return }
            lastTap = nil
            if showControls { showControls = false } else { reveal() }
        }
    }

    /// Each tap adds ten seconds on its side. The picture answers at once; the player is asked once the taps stop,
    /// so a run of five taps is one seek rather than five.
    private func addSeek(forward: Bool) {
        if let f = seekFlash, f.forward != forward {
            commitSeek()
            seekFlash = nil
        }
        showControls = false

        var flash = seekFlash ?? SeekFlash(forward: forward)
        flash.seconds += 10
        flash.taps += 1
        withAnimation(Motion.role(Motion.fast, reduce: reduceMotion)) { seekFlash = flash }
        pendingSeek += forward ? 10 : -10
        prefetchSeek(to: engine.currentTime + pendingSeek)

        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(350))
            guard !Task.isCancelled else { return }
            commitSeek()
            try? await Task.sleep(for: .milliseconds(500))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.role(Motion.exit, reduce: reduceMotion)) { seekFlash = nil }
        }
    }

    private func commitSeek() {
        guard pendingSeek != 0 else { return }
        engine.skip(by: pendingSeek)
        pendingSeek = 0
    }

    // MARK: top

    /// Leave on the leading side; where the picture goes on the trailing side.
    private var topBar: some View {
        HStack(alignment: .center, spacing: Space.m) {
            PlayerIconButton(systemImage: "xmark", label: "Close") { dismiss() }
            Spacer(minLength: 0)
            PlayerToolbar {
                if engine.canPictureInPicture && !engine.isOnTV {
                    Button { engine.togglePictureInPicture() } label: {
                        PlayerGlyph(systemImage: "pip.enter")
                    }
                    .accessibilityLabel("Picture in Picture")
                }
                AirPlayButton()
                    .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                    .accessibilityLabel("AirPlay")
            }
        }
    }

    // MARK: center

    /// Plain glyphs: the video stays the subject, and the scrim already carries contrast.
    private var centerControls: some View {
        HStack(spacing: PlayerMetrics.playGlyph) {
            Button { engine.skip(by: -10); scheduleHide() } label: {
                Image(systemName: "gobackward.10")
                    .font(.system(size: 30, weight: .regular))
                    .frame(width: PlayerMetrics.skipGlyph, height: PlayerMetrics.skipGlyph)
                    .contentShape(.circle)
            }
            .accessibilityLabel("Back 10 Seconds")

            Button { engine.togglePlay(); scheduleHide() } label: {
                ZStack {
                    if engine.isBuffering && engine.isPlaying {
                        ProgressView().controlSize(.large).tint(.white)
                    } else {
                        Image(systemName: engine.isPlaying ? "pause.fill" : "play.fill")
                            .font(.system(size: 46, weight: .regular))
                            .contentTransition(.symbolEffect(.replace))
                    }
                }
                .frame(width: PlayerMetrics.playGlyph, height: PlayerMetrics.playGlyph)
                .contentShape(.circle)
            }
            .accessibilityLabel(engine.isPlaying ? "Pause" : "Play")

            Button { engine.skip(by: 10); scheduleHide() } label: {
                Image(systemName: "goforward.10")
                    .font(.system(size: 30, weight: .regular))
                    .frame(width: PlayerMetrics.skipGlyph, height: PlayerMetrics.skipGlyph)
                    .contentShape(.circle)
            }
            .accessibilityLabel("Forward 10 Seconds")
        }
        .buttonStyle(PlayerPressStyle())
        .shadow(color: .black.opacity(0.35), radius: PlayerMetrics.glyphShadow)
    }

    // MARK: bottom

    /// What's playing and what can be done to it share a row; the timeline and times sit beneath, edge to edge.
    private func bottomBar(compact: Bool) -> some View {
        VStack(spacing: Space.s) {
            HStack(alignment: .center, spacing: Space.l) {
                titleBlock
                    .frame(maxWidth: .infinity, alignment: .leading)
                actionToolbar(compact: compact)
            }

            VStack(spacing: 0) {
                StreamScrubber(progress: engine.duration > 0 ? engine.currentTime / engine.duration : 0,
                               availability: stats.availability,
                               duration: engine.duration,
                               marks: engine.duration > 0 ? engine.chapters.map { $0.start / engine.duration } : [],
                               chapterName: { f in chapter(at: f * engine.duration)?.name },
                               preview: previews.isSupported ? { t in previews.image(at: t) } : nil,
                               previewAspect: engine.videoSize.width > 0 ? engine.videoSize.height / engine.videoSize.width : 9 / 16,
                               scrub: $scrub) { fraction in
                    previews.endFocus()
                    scrubRestTask?.cancel()
                    prefetchSeek(to: fraction * engine.duration)
                    engine.seek(to: fraction * engine.duration, fast: true)
                    scheduleHide()
                }
                .onChange(of: scrub != nil) { _, dragging in if dragging { hideTask?.cancel() } }
                .onChange(of: scrub) { _, s in
                    guard let s, engine.duration > 0 else { return }
                    previews.focus(at: s * engine.duration)
                    // Only where the finger rests: a sweep across the bar shouldn't pull bytes from every spot.
                    scrubRestTask?.cancel()
                    scrubRestTask = Task { @MainActor in
                        try? await Task.sleep(for: .milliseconds(150))
                        guard !Task.isCancelled, scrub != nil else { return }
                        prefetchSeek(to: s * engine.duration)
                    }
                }

                HStack {
                    Text(Format.seconds(displayedTime))
                    Spacer()
                    Text("-" + Format.seconds(max(0, engine.duration - displayedTime)))
                }
                .font(.caption.weight(.medium).monospacedDigit())
                .foregroundStyle(.white.opacity(0.7))
            }
        }
    }

    private var displayedTime: Double { scrub.map { $0 * engine.duration } ?? engine.currentTime }

    /// The show over the episode, so the eye lands on what's specific to this moment; a film is just its title.
    private var titleBlock: some View {
        VStack(alignment: .leading, spacing: Space.xxs) {
            if let episode = request.episode {
                Text(request.title)
                    .font(.subheadline.weight(.medium))
                    .foregroundStyle(.white.opacity(0.7))
                Text(episode)
                    .font(.headline)
            } else {
                Text(request.title)
                    .font(.headline)
            }
        }
        .lineLimit(1)
        .shadow(color: .black.opacity(0.4), radius: PlayerMetrics.glyphShadow)
        .accessibilityElement(children: .combine)
    }

    /// Navigation first, then the two used most (Audio & Subtitles, Next Episode), then More for everything rarer.
    /// A changed speed shows as its value, so it's never forgotten. On a narrow screen Chapters and Episodes move
    /// into More so the title keeps its room.
    private func actionToolbar(compact: Bool) -> some View {
        PlayerToolbar {
            if engine.rate != 1 {
                speedMenu {
                    Text(PlaybackSpeed.label(engine.rate))
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .padding(.horizontal, Space.s)
                        .frame(minWidth: PlayerMetrics.control, minHeight: PlayerMetrics.control)
                        .contentShape(.rect)
                }
                .accessibilityLabel("Playback Speed, \(PlaybackSpeed.label(engine.rate))")
            }
            if !compact && engine.chapters.count > 1 {
                Button { panel = .chapters } label: { PlayerGlyph(systemImage: "list.bullet") }
                    .accessibilityLabel("Chapters")
            }
            if !compact && episodesAvailable {
                Button { panel = .episodes } label: { PlayerGlyph(systemImage: "rectangle.stack") }
                    .accessibilityLabel("Episodes")
            }
            Button { panel = .tracks } label: { PlayerGlyph(systemImage: "captions.bubble") }
                .accessibilityLabel("Audio & Subtitles")
            if upNext != nil {
                Button { playNext() } label: { PlayerGlyph(systemImage: "forward.end.fill") }
                    .disabled(resolvingNext)
                    .accessibilityLabel("Next Episode")
            }
            moreMenu(compact: compact)
        }
    }

    private func speedMenu<MenuLabel: View>(@ViewBuilder label: () -> MenuLabel) -> some View {
        Menu {
            Picker("Speed", selection: Binding(get: { engine.rate }, set: { engine.setRate($0); scheduleHide() })) {
                ForEach(PlaybackSpeed.all, id: \.self) { r in Text(PlaybackSpeed.label(r)).tag(r) }
            }
        } label: { label() }
    }

    private func moreMenu(compact: Bool) -> some View {
        Menu {
            if compact {
                Section {
                    if engine.chapters.count > 1 {
                        Button { panel = .chapters } label: { Label("Chapters", systemImage: "list.bullet") }
                    }
                    if episodesAvailable {
                        Button { panel = .episodes } label: { Label("Episodes", systemImage: "rectangle.stack") }
                    }
                }
            }
            Section {
                Picker(selection: Binding(get: { engine.rate }, set: { engine.setRate($0); scheduleHide() })) {
                    ForEach(PlaybackSpeed.all, id: \.self) { r in Text(PlaybackSpeed.label(r)).tag(r) }
                } label: {
                    Label("Playback Speed", systemImage: "gauge.with.dots.needle.67percent")
                }
                .pickerStyle(.menu)
                if engine.videoSize.width > 0 && !engine.isOnTV {
                    Button {
                        fill.toggle()
                    } label: {
                        Label(fill ? "Fit to Screen" : "Fill Screen",
                              systemImage: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                    }
                }
                if let target = episodeTarget {
                    Button {
                        versions = target
                    } label: { Label("Choose Version…", systemImage: "slider.horizontal.3") }
                }
            }
            Section {
                Picker(selection: Binding(get: { sleep }, set: { setSleep($0) })) {
                    Text("Off").tag(SleepTimer.off)
                    ForEach([15, 30, 45, 60], id: \.self) { m in
                        Text(m == 60 ? "1 Hour" : "\(m) Minutes").tag(SleepTimer.minutes(m))
                    }
                    Text("End of Episode").tag(SleepTimer.endOfEpisode)
                } label: {
                    Label("Sleep Timer", systemImage: sleep == .off ? "moon" : "moon.fill")
                }
                .pickerStyle(.menu)
                Button {
                    locked = true
                    flashUnlock()
                } label: { Label("Lock Controls", systemImage: "lock") }
            }
        } label: {
            PlayerGlyph(systemImage: "ellipsis")
        }
        .accessibilityLabel("More")
    }

    // MARK: second subtitle

    @ViewBuilder
    private var secondSubtitle: some View {
        if let text = secondary.text {
            Text(text)
                .font(.callout.weight(.medium))
                .multilineTextAlignment(.center)
                .padding(.horizontal, Space.s)
                .padding(.vertical, Space.xxs)
                .background(.black.opacity(0.45), in: .rect(cornerRadius: Space.xs))
                .padding(.top, Space.s)
                .frame(maxWidth: PlayerMetrics.titleMaxWidth)
                .allowsHitTesting(false)
                .accessibilityHidden(true)
        }
    }

    // MARK: the moment: resumed, skip intro, next episode

    /// The row directly above the controls, which settles into the bottom corners when they hide. The resume note
    /// sits on the leading side under the title; Skip and the next episode on the trailing side, in line with the
    /// toolbar and under the thumb.
    private var momentRow: some View {
        HStack(alignment: .bottom, spacing: Space.l) {
            if showResumed, let at = request.resumeAt, !locked, panel == nil, engine.errorText == nil {
                resumedPill(at)
                    .transition(.opacity.combined(with: .offset(y: Space.s)))
            }
            Spacer(minLength: 0)
            moment
        }
    }

    private func resumedPill(_ at: Double) -> some View {
        HStack(spacing: Space.m) {
            Text("Resumed at \(Format.seconds(at))")
                .foregroundStyle(.white.opacity(0.75))
                .monospacedDigit()
            Button {
                engine.seek(to: 0)
                showResumed = false
            } label: {
                Text("Start Over")
                    .fontWeight(.semibold)
                    .frame(minHeight: PlayerMetrics.control)
                    .contentShape(.rect)
            }
            .buttonStyle(PlayerPressStyle())
        }
        .font(.subheadline)
        .padding(.horizontal, Space.l)
        .glassEffect(.regular, in: .capsule)
    }

    private var activeSkip: SkipSegment? {
        let t = engine.currentTime
        // At the credits the Next Episode card is the way on; without one, skip them like anything else.
        let nextCovers = upNext != nil && !nextDismissed
        return skips.first { s in
            t >= s.start && t < s.end - 1
                && !((s.kind == .credits || s.kind == .preview) && nextCovers)
        }
    }

    /// Where the ending starts, once it's known; until then the card waits for the end of the episode.
    private var creditsStart: Double? {
        SkipResolver.nextEpisodeCue(skips, duration: engine.duration)
    }

    /// While the controls are up, the toolbar's Next button stands in for the card, which would otherwise crowd
    /// the play controls; once the episode has ended they're gone and the card returns.
    private var showsNextCard: Bool {
        guard upNext != nil, !nextDismissed, panel == nil, !locked, engine.errorText == nil else { return false }
        if engine.didFinish { return true }
        guard !showControls, let start = creditsStart, scrub == nil else { return false }
        return engine.currentTime >= start
    }

    /// Skip shows with the controls, and on its own for the first few seconds of the part it skips.
    private var showsSkip: Bool {
        guard let s = activeSkip, !locked, panel == nil, engine.errorText == nil else { return false }
        return showControls || engine.currentTime - s.start < 8
    }

    private var momentID: String {
        if showsNextCard { return "next" }
        if showsSkip, let s = activeSkip { return "skip.\(s.start)" }
        return ""
    }

    @ViewBuilder
    private var moment: some View {
        if showsNextCard, let next = upNext {
            NextEpisodeCard(item: next, countdown: countdown, isStarting: resolvingNext,
                            onPlay: playNext,
                            onDismiss: {
                                cancelCountdown()
                                nextDismissed = true
                            })
            .transition(.opacity.combined(with: .offset(y: Space.s)))
        } else if showsSkip, let s = activeSkip {
            SkipButton(title: skipTitle(s.kind)) {
                engine.seek(to: s.end)
                scheduleHide()
            }
            .transition(.opacity.combined(with: .offset(y: Space.s)))
        }
    }

    private func skipTitle(_ kind: SkipSegment.Kind) -> String {
        switch kind {
        case .intro: return "Skip Intro"
        case .recap: return "Skip Recap"
        case .preview: return "Skip Preview"
        case .credits: return "Skip Credits"
        }
    }

    private func loadSkips() {
        guard let ctx = request.show, !ctx.isMovie else { updateSkips(); return }
        let duration = engine.duration
        Task { @MainActor in
            catalogSkips = await shows.skipSegments(ctx, duration: duration)
            updateSkips()
        }
    }

    /// The file's own chapter names first, then the opening and ending found in its audio, then the catalog's times;
    /// lined up with the chapters where they're close.
    private func updateSkips() {
        let chapters = engine.duration > 0
            ? engine.chapters.map { (name: $0.name, start: $0.start, end: $0.end) } : []
        skips = SkipResolver.segments(catalog: catalogSkips, content: contentSkips.content,
                                      chapters: chapters, duration: engine.duration)
        // Skipping lands where each segment ends; have those bytes before the button is pressed.
        let ends = skips.map(\.end).filter { $0 > engine.currentTime && $0 < engine.duration - 1 }
        request.torrent.want(fileIndex: request.file.index, ranges: ends.map(seekRange), urgency: .soon, tag: Self.skipsTag)
    }

    // MARK: seeking ahead of the player

    private static let seekTag = "player.seek"
    private static let skipsTag = "player.skips"

    /// What a seek to `seconds` reads first: from the keyframe before it on, by the file's index when it's loaded,
    /// else by proportion with a margin either side.
    private func seekRange(_ seconds: Double) -> Range<Int64> {
        let length = request.file.length
        if let r = previews.playbackRange(at: seconds) { return r }
        let fraction = engine.duration > 0 ? min(max(seconds / engine.duration, 0), 1) : 0
        let at = Int64(Double(length) * fraction)
        return max(0, at - (2 << 20))..<min(length, at + (6 << 20))
    }

    /// Asks the swarm for a seek target while the finger is still moving or the taps are still coming, so the
    /// player finds the data there when it's asked to go. Forgotten after a while; by then the player reads it
    /// itself or never will.
    private func prefetchSeek(to seconds: Double) {
        guard engine.duration > 0, request.file.length > 0 else { return }
        let torrent = request.torrent
        torrent.want(fileIndex: request.file.index, ranges: [seekRange(seconds)], urgency: .now, tag: Self.seekTag)
        seekWantTask?.cancel()
        seekWantTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(20))
            guard !Task.isCancelled else { return }
            torrent.clearWants(tag: Self.seekTag)
        }
    }

    // MARK: chapters

    private func chapter(at t: Double) -> Chapter? {
        engine.chapters.last { $0.start <= t + 0.5 }
    }

    // MARK: panels

    private var episodesAvailable: Bool {
        guard let ctx = request.show, !ctx.isMovie, let d = shows.details[ctx.show.id] else { return false }
        return d.seasons.reduce(0) { $0 + $1.episodes.count } > 1
    }

    @ViewBuilder
    private func panelLayer(_ p: PlayerPanel, landscape: Bool, size: CGSize) -> some View {
        ZStack(alignment: landscape ? .trailing : .bottom) {
            Color.black.opacity(0.2)
                .ignoresSafeArea()
                .onTapGesture { panel = nil }
                .accessibilityHidden(true)
            Group {
                switch p {
                case .tracks:
                    PlayerPanelFrame(title: "Audio & Subtitles", isLandscape: landscape,
                                     isWide: true, onClose: { panel = nil }) {
                        TracksPanel(engine: engine, secondary: secondary, isLandscape: landscape) { importing = true }
                    }
                case .chapters:
                    PlayerPanelFrame(title: "Chapters", isLandscape: landscape, onClose: { panel = nil }) {
                        ChaptersPanel(chapters: engine.chapters, current: chapter(at: engine.currentTime)?.id) { c in
                            engine.seek(to: c.start)
                            panel = nil
                        }
                    }
                case .episodes:
                    if let ctx = request.show, let d = shows.details[ctx.show.id] {
                        PlayerPanelFrame(title: "Episodes", isLandscape: landscape, onClose: { panel = nil }) {
                            EpisodesPanel(details: d, playing: ctx) { s, e in
                                panel = nil
                                switchEpisode(d, s, e)
                            }
                        }
                    }
                }
            }
            .frame(height: landscape ? nil : size.height * 0.62)
            .frame(maxHeight: landscape ? .infinity : nil)
            .padding(landscape ? Space.m : Space.s)
        }
    }

    // MARK: lock

    @ViewBuilder
    private var lockLayer: some View {
        if showUnlock {
            VStack {
                Spacer()
                Button {
                    locked = false
                    showUnlock = false
                    reveal()
                } label: {
                    Label("Unlock", systemImage: "lock.open")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, Space.l)
                        .frame(minHeight: PlayerMetrics.control)
                        .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .glassEffect(.regular.interactive(), in: .capsule)
                .padding(.bottom, Space.xl)
            }
            .transition(.opacity)
        }
    }

    private func flashUnlock() {
        withAnimation(Motion.role(Motion.standard, reduce: reduceMotion)) { showUnlock = true }
        Task { @MainActor in
            try? await Task.sleep(for: .seconds(3))
            withAnimation(Motion.role(Motion.exit, reduce: reduceMotion)) { showUnlock = false }
        }
    }

    // MARK: end of playback

    @ViewBuilder
    private var finishedOverlay: some View {
        HStack(spacing: Space.l) {
            Button { engine.replay(); scheduleHide() } label: {
                Label("Watch Again", systemImage: "arrow.counterclockwise")
            }
            .buttonStyle(.glass)
            Button { dismiss() } label: {
                Label("Done", systemImage: "checkmark")
            }
            .buttonStyle(.glassProminent)
        }
        .controlSize(.large)
    }

    private func handleFinish() {
        reveal(autoHide: false)
        if sleep == .endOfEpisode {
            setSleep(.off)
            return
        }
        guard upNext != nil, !nextDismissed, UserDefaults.standard.bool(forKey: SettingsKey.autoPlayNext) else { return }
        countdown = NextEpisodeCard.countdownSeconds
        countdownTask?.cancel()
        countdownTask = Task { @MainActor in
            while let c = countdown, c > 0 {
                try? await Task.sleep(for: .seconds(1))
                if Task.isCancelled { return }
                withAnimation(Motion.role(Motion.fast, reduce: reduceMotion)) { countdown = c - 1 }
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
        engine.pause()
        Task { @MainActor in
            let req = await next.resolve()
            resolvingNext = false
            if let req {
                onNext(req)
            } else {
                nextDismissed = true
                engine.play()
                model.showToast("\(next.title) couldn’t be started", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    // MARK: switching

    /// The catalog episode playing, for choosing another version of it.
    private var episodeTarget: EpisodeTarget? {
        guard let ctx = request.show, let d = shows.details[ctx.show.id], let s = d.season(id: ctx.seasonID),
              let e = s.episodes.first(where: { $0.number == ctx.episode }) else { return nil }
        return EpisodeTarget(details: d, season: s, episode: e)
    }

    /// Restarts the episode from another release at the same moment.
    private func switchVersion(_ target: EpisodeTarget, to source: EpisodeSource) {
        guard source.result.infoHash?.lowercased() != request.torrent.infoHashHex else { return }
        let at = engine.currentTime
        engine.pause()
        model.showToast("Switching to \(source.group ?? "another version")", systemImage: "arrow.triangle.2.circlepath")
        Task { @MainActor in
            do {
                let req = try await shows.request(target.details, target.season, target.episode, source: source,
                                                  resumeAt: at > 1 ? at : nil, status: { _ in })
                onNext(req)
            } catch {
                engine.play()
                model.showToast("That version couldn’t be started", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    private func switchEpisode(_ d: ShowDetails, _ s: ShowSeason, _ e: ShowEpisode) {
        engine.pause()
        model.showToast("Starting \(ShowsModel.episodeLabel(d, s, e))", systemImage: "play.fill")
        Task { @MainActor in
            do {
                onNext(try await shows.request(d, s, e, source: nil, resumeAt: nil, status: { _ in }))
            } catch {
                engine.play()
                model.showToast("That episode couldn’t be started", systemImage: "exclamationmark.triangle.fill")
            }
        }
    }

    private func importSubtitle(_ result: Result<[URL], Error>) {
        guard case .success(let urls) = result, let url = urls.first else { return }
        let scoped = url.startAccessingSecurityScopedResource()
        defer { if scoped { url.stopAccessingSecurityScopedResource() } }
        let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
        try? FileManager.default.removeItem(at: dest)
        if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { engine.addSubtitleFile(dest) }
    }

    // MARK: sleep

    private func setSleep(_ value: SleepTimer) {
        sleep = value
        sleepTask?.cancel()
        sleepTask = nil
        guard case .minutes(let m) = value else { return }
        sleepTask = Task { @MainActor in
            try? await Task.sleep(for: .seconds(m * 60))
            guard !Task.isCancelled else { return }
            engine.pause()
            sleep = .off
        }
    }

    // MARK: errors

    private func errorPanel(_ message: String) -> some View {
        VStack(spacing: Space.l) {
            VStack(spacing: Space.s) {
                Text("Can’t Play This Video").font(.headline)
                Text(message)
                    .font(.subheadline)
                    .foregroundStyle(.white.opacity(0.75))
                    .multilineTextAlignment(.center)
            }
            VStack(spacing: Space.s) {
                if let target = episodeTarget {
                    Button { versions = target } label: {
                        Text("Choose Another Version").frame(maxWidth: .infinity)
                    }
                    .buttonStyle(.glassProminent)
                }
                Button { dismiss() } label: {
                    Text("Close").frame(maxWidth: .infinity)
                }
                .buttonStyle(.glass)
            }
            .controlSize(.large)
        }
        .padding(Space.xl)
        .frame(maxWidth: PlayerMetrics.cardWidth)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: Radius.large))
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
            guard !Task.isCancelled, engine.isPlaying, panel == nil, scrub == nil, !engine.didFinish else { return }
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
