import SwiftUI

/// Player-only geometry.
enum PlayerMetrics {
    static let control: CGFloat = 44
    static let skipGlyph: CGFloat = 64
    static let playGlyph: CGFloat = 84
    static let titleMaxWidth: CGFloat = 520
    static let cardWidth: CGFloat = 340
    static let thumbWidth: CGFloat = 128
    static let panelSideWidth: CGFloat = 400
    static let panelWideWidth: CGFloat = 720
    /// Below this width Chapters and Episodes move into More, so the title beside the toolbar keeps its room.
    static let compactWidth: CGFloat = 560
    /// Side margins for the chrome on a wide screen, where the default margin would crowd the edges.
    static let wideMargin: CGFloat = 40
    /// Text over video keeps a soft shadow so it reads on white frames too.
    static let glyphShadow: CGFloat = 6
}

/// Speeds offered by the player, and how they are labelled.
enum PlaybackSpeed {
    static let all: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static func label(_ r: Float) -> String { String(format: "%g×", r) }
}

/// Contact feedback for controls drawn over video: dims the instant a finger lands, eases back on release.
/// Geometry never changes, so nothing shifts under the finger.
struct PlayerPressStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .opacity(configuration.isPressed ? 0.45 : 1)
            .animation(configuration.isPressed ? nil : .easeOut(duration: 0.1), value: configuration.isPressed)
    }
}

/// A round glass control on its own, like Close.
struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            PlayerGlyph(systemImage: systemImage)
        }
        .buttonStyle(PlayerPressStyle())
        .glassEffect(.clear, in: .circle)
        .accessibilityLabel(label)
    }
}

/// An icon in a player toolbar, at full touch size.
struct PlayerGlyph: View {
    let systemImage: String

    var body: some View {
        Image(systemName: systemImage)
            .font(.body.weight(.semibold))
            .contentTransition(.symbolEffect(.replace))
            .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
            .contentShape(.rect)
    }
}

/// Related controls sharing one glass capsule, as in a system toolbar.
struct PlayerToolbar<Content: View>: View {
    @ViewBuilder let content: Content

    var body: some View {
        HStack(spacing: 0) { content }
            .buttonStyle(PlayerPressStyle())
            .foregroundStyle(.white)
            .glassEffect(.clear, in: .capsule)
            .fixedSize()
    }
}

/// Seek bar showing what's loaded, chapter boundaries, and while dragging, the time and chapter under the finger.
struct StreamScrubber: View {
    let progress: Double
    let availability: [Double]
    let duration: Double
    /// Chapter starts as fractions of the duration.
    var marks: [Double] = []
    /// The chapter at a fraction, for the drag bubble.
    var chapterName: (Double) -> String? = { _ in nil }
    /// The picture at a time in seconds, for the drag bubble; nil when this video gets no previews.
    var preview: ((Double) -> UIImage?)? = nil
    /// Height over width of the video, so the preview's frame doesn't change shape when its picture arrives.
    var previewAspect: CGFloat = 9 / 16
    @Binding var scrub: Double?
    let onCommit: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 32
    private let restingBar: CGFloat = 5
    private let activeBar: CGFloat = 10
    private let restingThumb: CGFloat = 13
    private let activeThumb: CGFloat = 20
    private let bubbleGap: CGFloat = 22
    private let bubbleMaxWidth: CGFloat = 220
    private let previewWidth: CGFloat = 176

    var body: some View {
        GeometryReader { geo in
            let width = max(geo.size.width, 1)
            let shown = min(max(scrub ?? progress, 0), 1)
            let barHeight = scrub == nil ? restingBar : activeBar
            let thumb = scrub == nil ? restingThumb : activeThumb

            ZStack(alignment: .leading) {
                Capsule().fill(.white.opacity(0.22))
                Canvas { ctx, size in
                    guard !availability.isEmpty else { return }
                    let w = size.width / CGFloat(availability.count)
                    for (i, a) in availability.enumerated() where a > 0 {
                        let rect = CGRect(x: CGFloat(i) * w, y: 0, width: w + 0.5, height: size.height)
                        ctx.fill(Path(rect), with: .color(.white.opacity(0.18 + 0.2 * a)))
                    }
                }
                .clipShape(.capsule)
                Capsule().fill(.white).frame(width: max(barHeight, width * shown))
            }
            .frame(height: barHeight)
            // Chapter boundaries cut small gaps into the bar.
            .mask {
                Canvas { ctx, size in
                    ctx.fill(Path(CGRect(origin: .zero, size: size)), with: .color(.black))
                    ctx.blendMode = .destinationOut
                    for m in marks where m > 0.005 && m < 0.995 {
                        ctx.fill(Path(CGRect(x: size.width * m - 1, y: 0, width: 2, height: size.height)), with: .color(.black))
                    }
                }
            }
            .overlay(alignment: .leading) {
                Circle()
                    .fill(.white)
                    .frame(width: thumb, height: thumb)
                    .shadow(color: .black.opacity(0.3), radius: 3)
                    .offset(x: width * shown - thumb / 2)
            }
            .overlay(alignment: .leading) {
                if let s = scrub, duration > 0 {
                    bubble(s)
                        .alignmentGuide(.leading) { d in
                            let x = width * s - d.width / 2
                            return -min(max(x, 0), width - d.width)
                        }
                        // Bottom edge a fixed gap above the bar, however tall the bubble is.
                        .alignmentGuide(VerticalAlignment.center) { d in d.height + bubbleGap }
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
        .sensoryFeedback(.selection, trigger: scrub.map { s in marks.lastIndex { $0 <= s } ?? -1 }) { old, new in
            old != nil && new != nil && old != new
        }
        .accessibilityElement()
        .accessibilityLabel("Playback Position")
        .accessibilityValue("\(Format.seconds(progress * duration)) of \(Format.seconds(duration))")
        .accessibilityAdjustableAction { direction in
            let step = duration > 0 ? 10 / duration : 0
            onCommit(min(max(progress + (direction == .increment ? step : -step), 0), 1))
        }
    }

    @ViewBuilder
    private func bubble(_ s: Double) -> some View {
        if let preview {
            // The picture leads; time and chapter sit beneath it as its caption.
            VStack(spacing: Space.xs) {
                previewImage(preview(s * duration))
                caption(s)
                    .padding(.bottom, Space.xxs)
            }
            .padding(Space.xs)
            .frame(width: previewWidth + Space.xs * 2)
            .glassEffect(.regular, in: .rect(cornerRadius: Radius.small + Space.xs))
        } else {
            caption(s)
                .padding(.horizontal, Space.m)
                .padding(.vertical, Space.xs)
                .frame(maxWidth: bubbleMaxWidth)
                .glassEffect(.regular, in: .capsule)
                .fixedSize()
        }
    }

    private func previewImage(_ image: UIImage?) -> some View {
        ZStack {
            Rectangle().fill(.black.opacity(0.35))
            if let image {
                Image(uiImage: image)
                    .resizable()
                    .aspectRatio(contentMode: .fill)
                    .transition(.opacity)
            }
        }
        .frame(width: previewWidth, height: (previewWidth * previewAspect).rounded())
        .clipShape(.rect(cornerRadius: Radius.small))
        .animation(Motion.role(Motion.fast, reduce: reduceMotion), value: image == nil)
    }

    private func caption(_ s: Double) -> some View {
        VStack(spacing: 0) {
            Text(Format.seconds(s * duration))
                .font(.subheadline.weight(.semibold).monospacedDigit())
            if let name = chapterName(s) {
                Text(name)
                    .font(.caption)
                    .foregroundStyle(.white.opacity(0.75))
                    .lineLimit(1)
            }
        }
    }
}

/// "Skip Intro" and the like: the one action that matters while that part plays.
struct SkipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            HStack(spacing: Space.s) {
                Text(title)
                Image(systemName: "forward.end.fill")
                    .font(.footnote)
            }
            .font(.subheadline.weight(.semibold))
            .padding(.leading, Space.l)
            .padding(.trailing, Space.m)
            .frame(minHeight: PlayerMetrics.control)
            .contentShape(.capsule)
        }
        .buttonStyle(PlayerPressStyle())
        .glassEffect(.regular, in: .capsule)
    }
}

/// At the end credits: the next episode's still and name, and a button that plays it. While counting down, the
/// button fills from left to right until it starts.
struct NextEpisodeCard: View {
    let item: UpNextItem
    let countdown: Int?
    let isStarting: Bool
    let onPlay: () -> Void
    let onDismiss: () -> Void

    static let countdownSeconds = 5

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .center, spacing: Space.m) {
                PosterImage(url: item.imageURL, title: "", showsTitle: false, cornerRadius: Radius.small)
                    .frame(width: PlayerMetrics.thumbWidth, height: PlayerMetrics.thumbWidth * 9 / 16)
                    .overlay {
                        if item.imageURL == nil {
                            Image(systemName: "play.rectangle")
                                .font(.title2)
                                .foregroundStyle(.white.opacity(0.5))
                        }
                    }
                VStack(alignment: .leading, spacing: Space.xxs) {
                    Text(item.title)
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    if let name = item.subtitle, !name.isEmpty {
                        Text(name)
                            .font(.subheadline.weight(.semibold))
                            .lineLimit(2)
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)
            .accessibilityLabel("Next: \(item.title)\(item.subtitle.map { ", \($0)" } ?? "")")

            HStack(spacing: Space.s) {
                Button(action: onPlay) {
                    Group {
                        if isStarting {
                            ProgressView().tint(.black)
                        } else {
                            Label(countdown.map { "Playing in \($0)" } ?? "Play Next Episode", systemImage: "play.fill")
                                .monospacedDigit()
                                .contentTransition(.numericText(countsDown: true))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: PlayerMetrics.control)
                    .foregroundStyle(.black)
                    .background { countdownFill }
                    .clipShape(.capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(PlayerPressStyle())
                .disabled(isStarting)

                Button(action: onDismiss) {
                    PlayerGlyph(systemImage: "xmark")
                }
                .buttonStyle(PlayerPressStyle())
                .glassEffect(.clear, in: .circle)
                .accessibilityLabel(countdown != nil ? "Cancel" : "Hide")
            }
        }
        .padding(Space.m)
        .frame(width: PlayerMetrics.cardWidth)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: Radius.large))
    }

    /// Solid white, or while counting down, white filling a paler track as the seconds run out.
    private var countdownFill: some View {
        GeometryReader { geo in
            let done = countdown.map { 1 - Double($0) / Double(Self.countdownSeconds) } ?? 1
            ZStack(alignment: .leading) {
                Rectangle().fill(.white.opacity(0.6))
                Rectangle().fill(.white).frame(width: geo.size.width * done)
            }
            .animation(.linear(duration: 1), value: countdown)
        }
    }
}

// MARK: - Double-tap seek

/// A run of double-tap seeks on one side.
struct SeekFlash: Equatable {
    let forward: Bool
    var seconds = 0
    /// Counts taps, so the glyph turns again on each one.
    var taps = 0
}

/// The system skip glyph, drawn for any total: a glass disc on the tapped side whose arrow turns once per tap while
/// the number inside counts up, as `goforward.10` would read if it had every value.
struct SeekFeedbackView: View {
    let flash: SeekFlash
    @Environment(\.accessibilityReduceMotion) private var reduceMotion
    @State private var shown = false

    private let disc: CGFloat = 88

    var body: some View {
        GeometryReader { geo in
            ZStack {
                Image(systemName: flash.forward ? "goforward" : "gobackward")
                    .font(.system(size: 50, weight: .regular))
                    .symbolEffect(.rotate.byLayer, options: .speed(1.6), value: reduceMotion ? 0 : flash.taps)
                Text("\(flash.seconds)")
                    .font(.system(size: 15, weight: .semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(flash.seconds)))
                    .offset(y: 2)
            }
            .foregroundStyle(.white)
            .frame(width: disc, height: disc)
            .glassEffect(.regular, in: .circle)
            .scaleEffect(shown || reduceMotion ? 1 : 0.7)
            .opacity(shown || reduceMotion ? 1 : 0)
            .keyframeAnimator(initialValue: 1.0, trigger: reduceMotion ? 0 : flash.taps) { view, scale in
                view.scaleEffect(scale)
            } keyframes: { _ in
                KeyframeTrack {
                    SpringKeyframe(1.08, duration: 0.12, spring: .snappy)
                    SpringKeyframe(1.0, duration: 0.3, spring: .bouncy)
                }
            }
            .position(x: geo.size.width * (flash.forward ? 0.75 : 0.25), y: geo.size.height / 2)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .sensoryFeedback(.impact(weight: .light), trigger: flash.taps)
        .onAppear {
            withAnimation(.spring(response: 0.32, dampingFraction: 0.72)) { shown = true }
        }
        .accessibilityHidden(true)
    }
}
