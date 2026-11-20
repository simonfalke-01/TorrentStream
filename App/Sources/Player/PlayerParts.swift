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
    @Binding var scrub: Double?
    let onCommit: (Double) -> Void
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private let height: CGFloat = 32
    private let restingBar: CGFloat = 5
    private let activeBar: CGFloat = 10
    private let restingThumb: CGFloat = 13
    private let activeThumb: CGFloat = 20
    private let bubbleLift: CGFloat = 40
    private let bubbleMaxWidth: CGFloat = 220

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
                        .offset(y: -bubbleLift)
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

    private func bubble(_ s: Double) -> some View {
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
        .padding(.horizontal, Space.m)
        .padding(.vertical, Space.xs)
        .frame(maxWidth: bubbleMaxWidth)
        .glassEffect(.regular, in: .capsule)
        .fixedSize()
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

/// A run of double-tap seeks on one side: how far in total, and where each tap landed.
struct SeekFlash: Equatable {
    let forward: Bool
    var seconds = 0
    /// Counts taps, so the chevrons run again on each one.
    var taps = 0
    var ripples: [Ripple] = []

    struct Ripple: Equatable, Identifiable {
        let id = UUID()
        let point: CGPoint
    }
}

/// The side of the screen that was double-tapped lights up as an arc; each tap sends a ripple out from the finger,
/// the chevrons run in the direction of travel, and the total counts up.
struct SeekFeedbackView: View {
    let flash: SeekFlash

    var body: some View {
        GeometryReader { geo in
            let size = geo.size
            let arc = SeekArc(forward: flash.forward)
            ZStack {
                arc.fill(.white.opacity(0.1))
                ZStack {
                    ForEach(flash.ripples) { r in
                        SeekRipple(point: r.point, radius: max(size.width, size.height) * 0.5)
                    }
                }
                .clipShape(arc)
                VStack(spacing: Space.s) {
                    SeekChevrons(forward: flash.forward, trigger: flash.taps)
                    Text("\(flash.forward ? "+" : "−")\(flash.seconds) s")
                        .font(.subheadline.weight(.semibold).monospacedDigit())
                        .contentTransition(.numericText(value: Double(flash.seconds)))
                }
                .shadow(color: .black.opacity(0.35), radius: PlayerMetrics.glyphShadow)
                .position(x: size.width * (flash.forward ? SeekArc.labelCenter : 1 - SeekArc.labelCenter), y: size.height / 2)
            }
            .foregroundStyle(.white)
        }
        .ignoresSafeArea()
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}

/// The lit side for a double-tap seek: the outer part of the screen, bounded by a shallow curve.
struct SeekArc: Shape {
    let forward: Bool
    /// Where the curve meets the vertical middle, as a fraction of the width from the near edge.
    static let depth: CGFloat = 0.38
    /// Middle of the lit area, from the leading edge for a forward seek.
    static let labelCenter: CGFloat = 1 - depth / 2

    func path(in rect: CGRect) -> Path {
        let a = rect.width * 0.5
        let b = rect.height * 0.85
        let innerX = forward ? rect.maxX - rect.width * Self.depth : rect.minX + rect.width * Self.depth
        let centerX = forward ? innerX + a : innerX - a
        return Path(ellipseIn: CGRect(x: centerX - a, y: rect.midY - b, width: a * 2, height: b * 2))
    }
}

private struct SeekRipple: View {
    let point: CGPoint
    let radius: CGFloat
    @State private var grown = false

    var body: some View {
        Circle()
            .fill(.white.opacity(grown ? 0 : 0.25))
            .frame(width: radius * 2, height: radius * 2)
            .scaleEffect(grown ? 1 : 0.1)
            .position(point)
            .onAppear { withAnimation(.easeOut(duration: 0.55)) { grown = true } }
    }
}

/// Three chevrons that light one after another in the direction of the seek.
private struct SeekChevrons: View {
    let forward: Bool
    let trigger: Int

    var body: some View {
        PhaseAnimator([-1, 0, 1, 2], trigger: trigger) { lit in
            HStack(spacing: 0) {
                ForEach(0..<3, id: \.self) { i in
                    Image(systemName: forward ? "arrowtriangle.forward.fill" : "arrowtriangle.backward.fill")
                        .opacity(lit == (forward ? i : 2 - i) ? 1 : 0.4)
                }
            }
            .font(.footnote)
        } animation: { _ in .easeOut(duration: 0.09) }
    }
}
