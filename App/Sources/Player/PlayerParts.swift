import SwiftUI

/// Player-only geometry.
enum PlayerMetrics {
    static let control: CGFloat = 44
    static let skipGlyph: CGFloat = 64
    static let playGlyph: CGFloat = 84
    static let titleMaxWidth: CGFloat = 520
    static let barMaxWidth: CGFloat = 960
    static let cardWidth: CGFloat = 340
    static let thumbWidth: CGFloat = 128
    static let panelSideWidth: CGFloat = 400
    static let panelWideWidth: CGFloat = 720
    static let seekFlash: CGFloat = 96
    static let seekFlashInset: CGFloat = 56
    /// Text over video keeps a soft shadow so it reads on white frames too.
    static let glyphShadow: CGFloat = 6
}

/// Speeds offered by the player, and how they are labelled.
enum PlaybackSpeed {
    static let all: [Float] = [0.5, 0.75, 1, 1.25, 1.5, 2]
    static func label(_ r: Float) -> String { String(format: "%g×", r) }
}

/// A round glass control in the player's top bar.
struct PlayerIconButton: View {
    let systemImage: String
    let label: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Image(systemName: systemImage)
                .font(.body.weight(.semibold))
                .contentTransition(.symbolEffect(.replace))
                .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                .contentShape(.circle)
        }
        .buttonStyle(.plain)
        .glassEffect(.clear.interactive(), in: .circle)
        .accessibilityLabel(label)
    }
}

/// A labelled action in the row under the timeline: icon over a short name, like a toolbar.
struct PlayerActionLabel: View {
    let title: String
    let systemImage: String
    var compact = false

    var body: some View {
        Group {
            if compact {
                Image(systemName: systemImage)
                    .font(.body.weight(.semibold))
                    .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
            } else {
                Label(title, systemImage: systemImage)
                    .font(.footnote.weight(.semibold))
                    .labelStyle(.titleAndIcon)
                    .padding(.horizontal, Space.s)
                    .frame(minHeight: PlayerMetrics.control)
            }
        }
        .contentShape(.rect)
        .accessibilityLabel(title)
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

/// "Skip Intro", shown while the intro plays.
struct SkipButton: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Label(title, systemImage: "forward.fill")
                .font(.subheadline.weight(.semibold))
                .labelStyle(.titleAndIcon)
                .padding(.horizontal, Space.l)
                .frame(minHeight: PlayerMetrics.control)
                .contentShape(.capsule)
        }
        .buttonStyle(.plain)
        .glassEffect(.regular.interactive(), in: .capsule)
    }
}

/// At the end credits: the next episode's still and name, and a button that plays it.
struct NextEpisodeCard: View {
    let item: UpNextItem
    let countdown: Int?
    let isStarting: Bool
    let onPlay: () -> Void
    let onDismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: Space.m) {
            HStack(alignment: .top, spacing: Space.m) {
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
                    Text("Next Episode")
                        .font(.caption.weight(.semibold))
                        .foregroundStyle(.white.opacity(0.7))
                    Text(item.subtitle?.isEmpty == false ? item.subtitle! : item.title)
                        .font(.subheadline.weight(.semibold))
                        .lineLimit(2)
                    if item.subtitle?.isEmpty == false {
                        Text(item.title)
                            .font(.caption)
                            .foregroundStyle(.white.opacity(0.7))
                    }
                }
                Spacer(minLength: 0)
            }
            .accessibilityElement(children: .combine)

            HStack(spacing: Space.s) {
                Button(action: onPlay) {
                    Group {
                        if isStarting {
                            ProgressView().tint(.black)
                        } else {
                            Label(countdown.map { "Playing in \($0)" } ?? "Play Next Episode", systemImage: "play.fill")
                                .monospacedDigit()
                                .contentTransition(.numericText(countdown: true))
                        }
                    }
                    .font(.subheadline.weight(.semibold))
                    .frame(maxWidth: .infinity, minHeight: PlayerMetrics.control)
                    .foregroundStyle(.black)
                    .background(.white, in: .capsule)
                    .contentShape(.capsule)
                }
                .buttonStyle(.plain)
                .disabled(isStarting)

                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.subheadline.weight(.semibold))
                        .frame(width: PlayerMetrics.control, height: PlayerMetrics.control)
                        .contentShape(.circle)
                }
                .buttonStyle(.plain)
                .glassEffect(.clear.interactive(), in: .circle)
                .accessibilityLabel(countdown != nil ? "Cancel" : "Hide")
            }
        }
        .padding(Space.m)
        .frame(width: PlayerMetrics.cardWidth)
        .glassEffect(.regular.tint(.black.opacity(0.3)), in: .rect(cornerRadius: Radius.large))
    }
}

/// The ripple after a double tap: which way, and how far in total.
struct SeekFlash: Equatable {
    var id = UUID()
    let forward: Bool
    var seconds: Int
}

struct SeekFlashView: View {
    let flash: SeekFlash

    var body: some View {
        HStack {
            if flash.forward { Spacer() }
            VStack(spacing: Space.xs) {
                Image(systemName: flash.forward ? "forward.fill" : "backward.fill")
                    .font(.title3)
                Text("\(flash.seconds) s")
                    .font(.subheadline.weight(.semibold).monospacedDigit())
                    .contentTransition(.numericText(value: Double(flash.seconds)))
            }
            .foregroundStyle(.white)
            .frame(width: PlayerMetrics.seekFlash, height: PlayerMetrics.seekFlash)
            .glassEffect(.clear, in: .circle)
            .padding(.horizontal, PlayerMetrics.seekFlashInset)
            if !flash.forward { Spacer() }
        }
        .allowsHitTesting(false)
        .accessibilityHidden(true)
    }
}
