import SwiftUI
import AVKit
import UniformTypeIdentifiers
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

struct PlayerScreen: View {
    let request: PlaybackRequest
    @EnvironmentObject var model: AppModel

    var body: some View {
        Group {
            #if canImport(MobileVLCKit)
            if model.playerEngine == .vlc {
                VLCPlayerScreen(request: request)
            } else {
                ApplePlayerScreen(request: request)
            }
            #else
            ApplePlayerScreen(request: request)
            #endif
        }
        .onAppear { UIApplication.shared.isIdleTimerDisabled = true }
        .onDisappear { UIApplication.shared.isIdleTimerDisabled = false }
    }
}

/// Live torrent statistics for the file being played.
@MainActor
final class StreamStatsModel: ObservableObject {
    @Published var status: StreamStatus?
    private var timer: Timer?

    func start(torrent: Torrent, fileIndex: Int) {
        status = torrent.streamStatus(fileIndex: fileIndex)
        timer = Timer.scheduledTimer(withTimeInterval: 1, repeats: true) { [weak self] _ in
            let s = torrent.streamStatus(fileIndex: fileIndex)
            Task { @MainActor in self?.status = s }
        }
    }

    func stop() { timer?.invalidate(); timer = nil }
}

struct StreamStatsLabel: View {
    let status: StreamStatus?

    var body: some View {
        if let s = status {
            HStack(spacing: 10) {
                Label("\(s.connectedPeers)", systemImage: "person.2.fill")
                Label(Format.rate(s.downloadRate), systemImage: "arrow.down")
                Label(Format.bytes(s.bufferedAhead) + " ahead", systemImage: "forward.fill")
                Text("\(Int(s.fileProgress * 100))%")
            }
            .labelStyle(CompactLabelStyle())
            .font(.caption2.monospacedDigit())
            .foregroundStyle(.white.opacity(0.85))
        }
    }
}

struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: 3) { configuration.icon; configuration.title }
    }
}

// MARK: - Apple AVPlayer

struct ApplePlayerScreen: View {
    let request: PlaybackRequest
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var model: AppModel
    @StateObject private var stats = StreamStatsModel()
    @State private var player: AVPlayer?

    var body: some View {
        ZStack(alignment: .topLeading) {
            Color.black.ignoresSafeArea()
            if let player = player {
                AVPlayerControllerView(player: player).ignoresSafeArea()
            }
            HStack(spacing: 12) {
                Button { dismiss() } label: {
                    Image(systemName: "xmark").font(.headline).padding(10).background(.ultraThinMaterial, in: Circle())
                }
                StreamStatsLabel(status: stats.status)
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(.black.opacity(0.5), in: Capsule())
                Spacer()
                Button {
                    player?.pause()
                    ExternalPlayer.openInVLC(request) { model.errorMessage = $0 }
                } label: {
                    Label("VLC", systemImage: "arrow.up.forward.app").font(.subheadline.bold())
                        .padding(.horizontal, 10).padding(.vertical, 8).background(.ultraThinMaterial, in: Capsule())
                }
            }
            .foregroundStyle(.white)
            .padding()
        }
        .onAppear {
            stats.start(torrent: request.torrent, fileIndex: request.file.index)
            let p = AVPlayer(url: request.url)
            p.automaticallyWaitsToMinimizeStalling = true
            player = p
            p.play()
        }
        .onDisappear {
            stats.stop()
            player?.pause()
            player = nil
        }
    }
}

struct AVPlayerControllerView: UIViewControllerRepresentable {
    let player: AVPlayer

    func makeUIViewController(context: Context) -> AVPlayerViewController {
        let vc = AVPlayerViewController()
        vc.player = player
        vc.allowsPictureInPicturePlayback = true
        vc.canStartPictureInPictureAutomaticallyFromInline = true
        return vc
    }

    func updateUIViewController(_ vc: AVPlayerViewController, context: Context) {
        if vc.player !== player { vc.player = player }
    }
}

// MARK: - VLC

#if canImport(MobileVLCKit)

struct MediaTrack: Identifiable, Hashable {
    let id: Int32
    let name: String
}

final class VLCPlayerModel: ObservableObject {
    let player = VLCMediaPlayer()
    @Published var isPlaying = false
    @Published var isStalled = true
    @Published var position: Double = 0
    @Published var timeMs: Int64 = 0
    @Published var lengthMs: Int64 = 0
    @Published var audioTracks: [MediaTrack] = []
    @Published var subtitleTracks: [MediaTrack] = []
    @Published var currentAudio: Int32 = -1
    @Published var currentSubtitle: Int32 = -1
    @Published var subtitleDelayMs = 0
    @Published var audioDelayMs = 0
    @Published var rate: Float = 1
    @Published var errorText: String?
    var isScrubbing = false

    private var timer: Timer?
    private var lastTime: Int32 = -1
    private var lastTimeChange = Date()
    private var autoSelectedSubtitle = false

    init(request: PlaybackRequest) {
        let media = VLCMedia(url: request.url)
        // Generous network cache: the torrent may deliver in bursts.
        media.addOption(":network-caching=4000")
        media.addOption(":http-reconnect")
        player.media = media
        for s in request.subtitles {
            player.addPlaybackSlave(s.url, type: .subtitle, enforce: false)
        }
    }

    func attach(_ view: UIView) { player.drawable = view }

    func start() {
        player.play()
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
        isPlaying = player.isPlaying
        let t = player.time.intValue
        if t != lastTime { lastTime = t; lastTimeChange = Date() }
        let state = player.state
        isStalled = state == .opening || state == .buffering && Date().timeIntervalSince(lastTimeChange) > 0.75
            || (player.isPlaying && Date().timeIntervalSince(lastTimeChange) > 1.5)
        if state == .error { errorText = "VLC could not play this stream." }
        timeMs = Int64(t)
        lengthMs = Int64(player.media?.length.intValue ?? 0)
        if !isScrubbing { position = Double(player.position) }

        let aNames = player.audioTrackNames.compactMap { $0 as? String }
        let aIDs = player.audioTrackIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let a = zip(aIDs, aNames).map { MediaTrack(id: $0, name: $1) }
        if a != audioTracks { audioTracks = a }
        currentAudio = player.currentAudioTrackIndex

        let sNames = player.videoSubTitlesNames.compactMap { $0 as? String }
        let sIDs = player.videoSubTitlesIndexes.compactMap { ($0 as? NSNumber)?.int32Value }
        let s = zip(sIDs, sNames).map { MediaTrack(id: $0, name: $1) }
        if s != subtitleTracks { subtitleTracks = s }
        currentSubtitle = player.currentVideoSubTitleIndex
    }

    func togglePlay() { player.isPlaying ? player.pause() : player.play() }

    func seek(to fraction: Double) {
        player.position = Float(min(max(fraction, 0), 0.999))
        lastTimeChange = Date()
    }

    func jump(_ seconds: Int32) {
        if seconds > 0 { player.jumpForward(seconds) } else { player.jumpBackward(-seconds) }
    }

    func selectAudio(_ id: Int32) { player.currentAudioTrackIndex = id; currentAudio = id }
    func selectSubtitle(_ id: Int32) { player.currentVideoSubTitleIndex = id; currentSubtitle = id }

    func setSubtitleDelay(_ ms: Int) {
        subtitleDelayMs = ms
        player.currentVideoSubTitleDelay = ms * 1000
    }

    func setAudioDelay(_ ms: Int) {
        audioDelayMs = ms
        player.currentAudioPlaybackDelay = ms * 1000
    }

    func setRate(_ r: Float) { rate = r; player.rate = r }

    func addSubtitleFile(_ url: URL) {
        player.addPlaybackSlave(url, type: .subtitle, enforce: true)
    }
}

struct VLCVideoView: UIViewRepresentable {
    let model: VLCPlayerModel

    func makeUIView(context: Context) -> UIView {
        let v = UIView()
        v.backgroundColor = .black
        model.attach(v)
        return v
    }

    func updateUIView(_ uiView: UIView, context: Context) {}
}

struct VLCPlayerScreen: View {
    let request: PlaybackRequest
    @Environment(\.dismiss) private var dismiss
    @EnvironmentObject var appModel: AppModel
    @StateObject private var vlc: VLCPlayerModel
    @StateObject private var stats = StreamStatsModel()
    @State private var showControls = true
    @State private var showTracks = false
    @State private var hideWork: DispatchWorkItem?

    init(request: PlaybackRequest) {
        self.request = request
        _vlc = StateObject(wrappedValue: VLCPlayerModel(request: request))
    }

    var body: some View {
        ZStack {
            Color.black.ignoresSafeArea()
            VLCVideoView(model: vlc).ignoresSafeArea()
                .contentShape(Rectangle())
                .onTapGesture { withAnimation { showControls.toggle() }; scheduleHide() }

            if vlc.isStalled {
                VStack(spacing: 10) {
                    ProgressView().controlSize(.large).tint(.white)
                    Text("Buffering from peers…").font(.subheadline).foregroundStyle(.white)
                    StreamStatsLabel(status: stats.status)
                }
                .padding(20)
                .background(.black.opacity(0.55), in: RoundedRectangle(cornerRadius: 16))
                .allowsHitTesting(false)
            }

            if showControls { controls.transition(.opacity) }

            if let err = vlc.errorText {
                VStack(spacing: 12) {
                    Text(err).foregroundStyle(.white)
                    Button("Close") { dismiss() }.buttonStyle(.borderedProminent)
                }
                .padding().background(.black.opacity(0.8), in: RoundedRectangle(cornerRadius: 12))
            }
        }
        .statusBarHidden(!showControls)
        .persistentSystemOverlays(.hidden)
        .onAppear {
            stats.start(torrent: request.torrent, fileIndex: request.file.index)
            vlc.start()
            scheduleHide()
        }
        .onDisappear {
            stats.stop()
            vlc.shutdown()
        }
        .sheet(isPresented: $showTracks) {
            TracksSheet(vlc: vlc, request: request)
                .presentationDetents([.medium, .large])
        }
    }

    private var controls: some View {
        VStack {
            HStack(spacing: 16) {
                Button { dismiss() } label: { Image(systemName: "xmark").font(.title3.weight(.semibold)) }
                VStack(alignment: .leading, spacing: 2) {
                    Text(request.file.fileName).font(.subheadline.bold()).lineLimit(1)
                    StreamStatsLabel(status: stats.status)
                }
                Spacer()
                Button { showTracks = true } label: { Image(systemName: "captions.bubble").font(.title3) }
                    .accessibilityLabel("Audio & Subtitles")
                Button {
                    vlc.player.pause()
                    ExternalPlayer.openInVLC(request) { appModel.errorMessage = $0 }
                } label: { Image(systemName: "arrow.up.forward.app").font(.title3) }
                    .accessibilityLabel("Open in VLC app")
            }
            .padding()
            .background(LinearGradient(colors: [.black.opacity(0.7), .clear], startPoint: .top, endPoint: .bottom))

            Spacer()

            HStack(spacing: 56) {
                Button { vlc.jump(-10); scheduleHide() } label: { Image(systemName: "gobackward.10").font(.title) }
                Button { vlc.togglePlay(); scheduleHide() } label: {
                    Image(systemName: vlc.isPlaying ? "pause.fill" : "play.fill").font(.system(size: 44))
                }
                Button { vlc.jump(10); scheduleHide() } label: { Image(systemName: "goforward.10").font(.title) }
            }

            Spacer()

            VStack(spacing: 4) {
                Slider(value: $vlc.position, in: 0...1) { editing in
                    vlc.isScrubbing = editing
                    if !editing { vlc.seek(to: vlc.position) }
                    scheduleHide()
                }
                .tint(.white)
                HStack {
                    Text(Format.time(vlc.isScrubbing ? Int64(vlc.position * Double(vlc.lengthMs)) : vlc.timeMs))
                    Spacer()
                    Text("-" + Format.time(max(0, vlc.lengthMs - vlc.timeMs)))
                }
                .font(.caption.monospacedDigit())
            }
            .padding()
            .background(LinearGradient(colors: [.clear, .black.opacity(0.7)], startPoint: .top, endPoint: .bottom))
        }
        .foregroundStyle(.white)
    }

    private func scheduleHide() {
        hideWork?.cancel()
        let work = DispatchWorkItem { if vlc.isPlaying && !showTracks { withAnimation { showControls = false } } }
        hideWork = work
        DispatchQueue.main.asyncAfter(deadline: .now() + 4, execute: work)
    }
}

/// Audio track, subtitle track, delays, speed, and loading subtitle files.
struct TracksSheet: View {
    @ObservedObject var vlc: VLCPlayerModel
    let request: PlaybackRequest
    @Environment(\.dismiss) private var dismiss
    @State private var importing = false

    var body: some View {
        NavigationStack {
            List {
                Section("Audio") {
                    if vlc.audioTracks.isEmpty { Text("No audio tracks yet").foregroundStyle(.secondary) }
                    ForEach(vlc.audioTracks) { t in
                        trackRow(t.name, selected: t.id == vlc.currentAudio) { vlc.selectAudio(t.id) }
                    }
                }
                Section {
                    if vlc.subtitleTracks.isEmpty { Text("No subtitles found").foregroundStyle(.secondary) }
                    ForEach(vlc.subtitleTracks) { t in
                        trackRow(t.name, selected: t.id == vlc.currentSubtitle) { vlc.selectSubtitle(t.id) }
                    }
                    Button { importing = true } label: { Label("Load Subtitle File…", systemImage: "doc.badge.plus") }
                    if !request.subtitles.isEmpty {
                        Menu {
                            ForEach(request.subtitles, id: \.self) { s in
                                Button(s.name) { vlc.addSubtitleFile(s.url) }
                            }
                        } label: { Label("Subtitle files in this torrent (\(request.subtitles.count))", systemImage: "captions.bubble") }
                    }
                } header: { Text("Subtitles") } footer: {
                    Text("Embedded subtitles (MKV/MP4) and subtitle files shipped in the torrent show up here automatically.")
                }
                Section("Sync") {
                    Stepper(value: Binding(get: { vlc.subtitleDelayMs }, set: { vlc.setSubtitleDelay($0) }), in: -60_000...60_000, step: 100) {
                        LabeledContent("Subtitle delay", value: String(format: "%+.1f s", Double(vlc.subtitleDelayMs) / 1000))
                    }
                    Stepper(value: Binding(get: { vlc.audioDelayMs }, set: { vlc.setAudioDelay($0) }), in: -10_000...10_000, step: 50) {
                        LabeledContent("Audio delay", value: String(format: "%+.2f s", Double(vlc.audioDelayMs) / 1000))
                    }
                }
                Section("Playback speed") {
                    Picker("Speed", selection: Binding(get: { vlc.rate }, set: { vlc.setRate($0) })) {
                        ForEach([Float(0.5), 0.75, 1, 1.25, 1.5, 2], id: \.self) { r in Text(String(format: "%gx", r)).tag(r) }
                    }
                    .pickerStyle(.segmented)
                }
            }
            .navigationTitle("Audio & Subtitles")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar { ToolbarItem(placement: .confirmationAction) { Button("Done") { dismiss() } } }
            .fileImporter(isPresented: $importing, allowedContentTypes: [.item], allowsMultipleSelection: false) { result in
                guard case .success(let urls) = result, let url = urls.first else { return }
                let scoped = url.startAccessingSecurityScopedResource()
                defer { if scoped { url.stopAccessingSecurityScopedResource() } }
                let dest = FileManager.default.temporaryDirectory.appendingPathComponent(url.lastPathComponent)
                try? FileManager.default.removeItem(at: dest)
                if (try? FileManager.default.copyItem(at: url, to: dest)) != nil { vlc.addSubtitleFile(dest) }
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

#endif
