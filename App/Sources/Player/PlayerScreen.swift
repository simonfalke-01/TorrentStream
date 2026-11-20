import SwiftUI
import TorrentKit
import CatalogKit
import SourceKit

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

    func update() {
        guard let torrent else { return }
        let complete = torrent.status().files.first { $0.file.index == fileIndex }?.isComplete ?? false
        availability = complete ? [1] : torrent.availability(fileIndex: fileIndex, buckets: 160)
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
    @State private var nowPlaying = NowPlaying()

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            if let engine {
                PlayerChrome(request: request, engine: engine, stats: stats, secondary: secondary, onNext: onNext)
            }
        }
        .onAppear {
            stats.start(torrent: request.torrent, fileIndex: request.file.index)
            guard engine == nil else { return }
            model.playbackStarted(request)
            shows.playbackStarted(request)
            let key = request.show.map { "show.\($0.show.id)" } ?? "torrent.\(request.torrent.infoHashHex)"
            let e = PlaybackEngine(request: request, memoryKey: key)
            engine = e
            e.start()
            e.showOnTV(ExternalDisplay.shared.isConnected)
            secondary.prepare(request)
            nowPlaying.activate(engine: e, title: request.title, subtitle: request.episode)
        }
        .onReceive(ExternalDisplay.shared.$isConnected.dropFirst()) { connected in
            engine?.showOnTV(connected)
        }
        .onDisappear {
            stats.stop()
            secondary.shutdown()
            nowPlaying.deactivate()
            if let e = engine {
                let position = e.didFinish ? e.duration : e.currentTime
                model.playbackEnded(torrent: request.torrent, file: request.file,
                                    positionSeconds: position, durationSeconds: e.duration)
                shows.playbackEnded(request, position: position, duration: e.duration)
                e.shutdown()
            }
        }
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

    @State private var sleep: SleepTimer = .off
    @State private var sleepTask: Task<Void, Never>?

    enum SleepTimer: Hashable {
        case off, minutes(Int), endOfEpisode
    }

    var body: some View {
        GeometryReader { geo in
            let landscape = geo.size.width > geo.size.height
            ZStack {
                video
                if let place = elsewhere, !controlsVisible { elsewhereNote(place).transition(.opacity) }
                gestureLayer

                if let flash = seekFlash {
                    SeekFlashView(flash: flash).transition(.opacity)
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

                VStack(spacing: 0) {
                    if controlsVisible {
                        topBar.transition(.opacity)
                        if showResumed, let at = request.resumeAt {
                            resumedPill(at)
                                .padding(.top, Space.m)
                                .transition(.opacity)
                        }
                    }
                    secondSubtitle
                    Spacer(minLength: 0)
                    moment
                        .frame(maxWidth: .infinity, alignment: .trailing)
                        .padding(.bottom, Space.m)
                    if controlsVisible {
                        bottomBar.transition(.opacity)
                    }
                }
                .padding(.horizontal, Space.l)
                .padding(.vertical, Space.s)
                .frame(maxWidth: PlayerMetrics.barMaxWidth + Space.l * 2)

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
        .animation(Motion.role(Motion.fast, reduce: reduceMotion), value: engine.isBuffering)
        .statusBarHidden(!controlsVisible)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            if request.resumeAt != nil { flashResumed() }
            upNext = nextItem()
            scheduleHide()
        }
        .onDisappear {
            countdownTask?.cancel()
            hideTask?.cancel()
            sleepTask?.cancel()
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
            shows.prefetchNext(after: request, duration: engine.duration)
            loadSkips()
        }
        .onChange(of: engine.chapters) { updateSkips() }
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
                .animation(Motion.role(Motion.standard, reduce: reduceMotion), value: zoom)
        }
        .ignoresSafeArea()
        .clipped()
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
        LinearGradient(stops: [.init(color: .black.opacity(0.55), location: 0),
                               .init(color: .black.opacity(0.15), location: 0.3),
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

    private func gestures(width: CGFloat) -> some View {
        Color.clear
            .contentShape(.rect)
            .onTapGesture(count: 2) { location in
                guard !engine.didFinish, !locked else { return }
                doubleTapSeek(forward: location.x > width / 2)
            }
            .onTapGesture {
                if locked {
                    flashUnlock()
                } else if panel != nil {
                    panel = nil
                } else if showControls {
                    showControls = false
                } else {
                    reveal()
                }
            }
            .gesture(
                MagnifyGesture().onEnded { v in
                    guard !locked else { return }
                    if v.magnification > 1.08 { fill = true } else if v.magnification < 0.92 { fill = false }
                }
            )
    }

    /// Each double tap on the same side within a moment adds ten more seconds.
    private func doubleTapSeek(forward: Bool) {
        engine.skip(by: forward ? 10 : -10)
        withAnimation(Motion.role(Motion.fast, reduce: reduceMotion)) {
            if var f = seekFlash, f.forward == forward {
                f.seconds += 10
                seekFlash = f
            } else {
                seekFlash = SeekFlash(forward: forward, seconds: 10)
            }
        }
        flashTask?.cancel()
        flashTask = Task { @MainActor in
            try? await Task.sleep(for: .milliseconds(700))
            guard !Task.isCancelled else { return }
            withAnimation(Motion.role(Motion.exit, reduce: reduceMotion)) { seekFlash = nil }
        }
    }

    // MARK: top

    private var topBar: some View {
        HStack(alignment: .center, spacing: Space.m) {
            PlayerIconButton(systemImage: "xmark", label: "Close") { dismiss() }
            if engine.canPictureInPicture && !engine.isOnTV {
                PlayerIconButton(systemImage: "pip.enter", label: "Picture in Picture") {
                    engine.togglePictureInPicture()
                }
            }

            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(request.title)
                    .font(.headline)
                    .lineLimit(1)
                if let episode = request.episode {
                    Text(episode)
                        .font(.subheadline)
                        .foregroundStyle(.white.opacity(0.75))
                        .lineLimit(1)
                }
            }
            .frame(maxWidth: PlayerMetrics.titleMaxWidth, alignment: .leading)
            .shadow(color: .black.opacity(0.4), radius: PlayerMetrics.glyphShadow)
            .accessibilityElement(children: .combine)

            Spacer(minLength: 0)

            AirPlayButton()
                .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                .glassEffect(.clear.interactive(), in: .circle)
                .accessibilityLabel("AirPlay")
            moreMenu
        }
    }

    private var moreMenu: some View {
        Menu {
            if let target = episodeTarget {
                Button {
                    versions = target
                } label: { Label("Choose Version…", systemImage: "slider.horizontal.3") }
            }
            if engine.videoSize.width > 0 && !engine.isOnTV {
                Button {
                    fill.toggle()
                } label: {
                    Label(fill ? "Fit to Screen" : "Fill Screen",
                          systemImage: fill ? "arrow.down.right.and.arrow.up.left" : "arrow.up.left.and.arrow.down.right")
                }
            }
            Picker(selection: Binding(get: { sleep }, set: { setSleep($0) })) {
                Text("Off").tag(SleepTimer.off)
                ForEach([15, 30, 45, 60], id: \.self) { m in
                    Text(m == 60 ? "1 Hour" : "\(m) Minutes").tag(SleepTimer.minutes(m))
                }
                Text("End of Episode").tag(SleepTimer.endOfEpisode)
            } label: {
                Label("Sleep Timer", systemImage: "moon")
            }
            .pickerStyle(.menu)
            Button {
                locked = true
                flashUnlock()
            } label: { Label("Lock Controls", systemImage: "lock") }
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

    private func resumedPill(_ at: Double) -> some View {
        HStack(spacing: Space.m) {
            Text("Resumed at \(Format.seconds(at))")
                .font(.subheadline.weight(.medium))
                .monospacedDigit()
            Button("Start Over") {
                engine.seek(to: 0)
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
        .buttonStyle(.plain)
        .shadow(color: .black.opacity(0.35), radius: PlayerMetrics.glyphShadow)
    }

    // MARK: bottom

    private var bottomBar: some View {
        VStack(spacing: Space.xs) {
            StreamScrubber(progress: engine.duration > 0 ? engine.currentTime / engine.duration : 0,
                           availability: stats.availability,
                           duration: engine.duration,
                           marks: engine.duration > 0 ? engine.chapters.map { $0.start / engine.duration } : [],
                           chapterName: { f in chapter(at: f * engine.duration)?.name },
                           scrub: $scrub) { fraction in
                engine.seek(to: fraction * engine.duration)
                scheduleHide()
            }
            .onChange(of: scrub != nil) { _, dragging in if dragging { hideTask?.cancel() } }

            HStack {
                Text(Format.seconds(displayedTime))
                Spacer()
                Text("-" + Format.seconds(max(0, engine.duration - displayedTime)))
            }
            .font(.caption.weight(.medium).monospacedDigit())
            .foregroundStyle(.white.opacity(0.8))

            actionRow
                .padding(.top, Space.xs)
        }
        .shadow(color: .black.opacity(0.3), radius: PlayerMetrics.glyphShadow)
    }

    private var displayedTime: Double { scrub.map { $0 * engine.duration } ?? engine.currentTime }

    /// Labelled where there's room; icons alone on a narrow screen.
    private var actionRow: some View {
        ViewThatFits(in: .horizontal) {
            actions(compact: false)
            actions(compact: true)
        }
        .frame(maxWidth: .infinity)
    }

    private func actions(compact: Bool) -> some View {
        HStack(spacing: compact ? Space.l : Space.xl) {
            Menu {
                Picker("Speed", selection: Binding(get: { engine.rate }, set: { engine.setRate($0); scheduleHide() })) {
                    ForEach(PlaybackSpeed.all, id: \.self) { r in Text(PlaybackSpeed.label(r)).tag(r) }
                }
            } label: {
                PlayerActionLabel(title: engine.rate == 1 ? "Speed" : "Speed (\(PlaybackSpeed.label(engine.rate)))",
                                  systemImage: "gauge.with.dots.needle.67percent", compact: compact)
            }

            if engine.chapters.count > 1 {
                Button { panel = .chapters } label: {
                    PlayerActionLabel(title: "Chapters", systemImage: "list.bullet", compact: compact)
                }
            }
            if episodesAvailable {
                Button { panel = .episodes } label: {
                    PlayerActionLabel(title: "Episodes", systemImage: "rectangle.stack", compact: compact)
                }
            }
            Button { panel = .tracks } label: {
                PlayerActionLabel(title: "Audio & Subtitles", systemImage: "captions.bubble", compact: compact)
            }
            if upNext != nil {
                Button { playNext() } label: {
                    PlayerActionLabel(title: "Next Episode", systemImage: "forward.end", compact: compact)
                }
                .disabled(resolvingNext)
            }
        }
        .buttonStyle(.plain)
        .foregroundStyle(.white)
        .fixedSize()
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

    // MARK: the moment: skip intro, next episode

    private var activeSkip: SkipSegment? {
        let t = engine.currentTime
        // At the credits the Next Episode card is the way on; without one, skip them like anything else.
        let nextCovers = upNext != nil && !nextDismissed
        return skips.first { s in
            t >= s.start && t < s.end - 1
                && !((s.kind == .credits || s.kind == .preview) && nextCovers)
        }
    }

    /// Where the end credits start, else the last 40 seconds.
    private var creditsStart: Double? {
        guard engine.duration > 120 else { return nil }
        if let c = skips.first(where: { $0.kind == .credits && $0.start > engine.duration * 0.5 }) { return c.start }
        return engine.duration - 40
    }

    private var showsNextCard: Bool {
        guard upNext != nil, !nextDismissed, panel == nil, !locked else { return false }
        if engine.didFinish { return true }
        guard let start = creditsStart, scrub == nil else { return false }
        return engine.currentTime >= start
    }

    private var momentID: String {
        if showsNextCard { return "next" }
        if let s = activeSkip, showControls || engine.currentTime - s.start < 8 { return "skip.\(s.start)" }
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
            .transition(.move(edge: .trailing).combined(with: .opacity))
        } else if let s = activeSkip, !locked, panel == nil, showControls || engine.currentTime - s.start < 8 {
            SkipButton(title: skipTitle(s.kind)) {
                engine.seek(to: s.end)
                scheduleHide()
            }
            .transition(.opacity)
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

    /// Times marked by viewers come first; the file's chapter names fill in whatever kinds they don't cover.
    private func updateSkips() {
        var out = catalogSkips
        if engine.duration > 0, !engine.chapters.isEmpty {
            let fromChapters = ChapterSkips.segments(engine.chapters.map { (name: $0.name, start: $0.start, end: $0.end) },
                                                     duration: engine.duration)
            let covered = Set(out.map(\.kind))
            out += fromChapters.filter { !covered.contains($0.kind) }
        }
        skips = out.sorted { $0.start < $1.start }
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
        countdown = 5
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
