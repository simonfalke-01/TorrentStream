import SwiftUI
import TorrentKit

// MARK: - Design tokens

/// 4-point spacing scale. Views use these roles instead of literal paddings.
enum Space {
    static let xxs: CGFloat = 2
    static let xs: CGFloat = 4
    static let s: CGFloat = 8
    static let m: CGFloat = 12
    static let l: CGFloat = 16
    static let xl: CGFloat = 24
    static let xxl: CGFloat = 32
}

enum Radius {
    /// Artwork thumbnails in rows.
    static let small: CGFloat = 8
    /// Artwork in headers.
    static let medium: CGFloat = 12
    /// Floating glass panels in the player.
    static let large: CGFloat = 24
}

/// Named motion roles. Routine changes stay under 250 ms and never bounce.
enum Motion {
    static let fast = Animation.easeOut(duration: 0.12)
    static let standard = Animation.timingCurve(0.2, 0, 0, 1, duration: 0.18)
    static let enter = Animation.timingCurve(0.16, 1, 0.3, 1, duration: 0.22)
    static let exit = Animation.timingCurve(0.4, 0, 1, 1, duration: 0.14)

    /// `nil` when Reduce Motion is on, so state changes land immediately.
    static func role(_ animation: Animation, reduce: Bool) -> Animation? { reduce ? nil : animation }
}

/// Fixed geometry shared by shelves, rows and headers.
enum Metrics {
    /// My List posters on Home.
    static let shelfPoster = CGSize(width: 120, height: 180)
    /// Continue Watching cards.
    static let wideCardWidth: CGFloat = 260
    /// Search result thumbnails.
    static let rowPoster = CGSize(width: 48, height: 72)
    /// Poster on a title page without a backdrop.
    static let headerPosterWidth: CGFloat = 200
    static let heroMaxWidth: CGFloat = 640
    static let contentMaxWidth: CGFloat = 720
    static let episodeNumber: CGFloat = 36
    static let indicator: CGFloat = 22
    static let touchTarget: CGFloat = 44
    static let playButtonHeight: CGFloat = 50
}

// MARK: - Formatting

enum Format {
    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    static func time(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func seconds(_ s: Double) -> String {
        time(s.isFinite ? Int64(max(0, s) * 1000) : 0)
    }

    static func count(_ n: Int) -> String { n.formatted(.number) }

    /// "3 days ago".
    static func age(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// "1 hr 5 min" or "24 min".
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = seconds >= 3600 ? [.hour, .minute] : [.minute]
        f.unitsStyle = .short
        f.maximumUnitCount = 2
        return f.string(from: max(seconds, 60))
    }

    /// "12 min left".
    static func remaining(_ seconds: Double) -> String? {
        duration(seconds).map { "\($0) left" }
    }

    static func episodes(_ n: Int) -> String { n == 1 ? "1 Episode" : "\(count(n)) Episodes" }
}

extension TorrentFile {
    var kind: MediaKind { MediaKind(fileExtension: fileExtension) }
    var isImage: Bool { ["jpg", "jpeg", "png", "webp", "heic"].contains(fileExtension) }
    /// Readable name: no extension, release-group tag or checksum.
    var title: String { MediaTitle.clean(fileName) }
}

// MARK: - Artwork

/// Poster or backdrop art. Without an image it shows the title on a neutral tile instead of invented art.
struct PosterImage: View {
    let url: URL?
    let title: String
    var showsTitle = true
    var cornerRadius: CGFloat = Radius.small
    var titleFont: Font = .subheadline.weight(.semibold)

    var body: some View {
        Rectangle()
            .fill(.fill.tertiary)
            .overlay {
                if showsTitle {
                    Text(title)
                        .font(titleFont)
                        .foregroundStyle(.secondary)
                        .multilineTextAlignment(.center)
                        .minimumScaleFactor(0.7)
                        .padding(Space.s)
                }
            }
            .overlay {
                if let url {
                    PipelineImage(url: url)
                }
            }
            .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
            .accessibilityHidden(true)
    }
}

// MARK: - Buttons and labels

/// The one primary action of a screen: a solid capsule in the primary color, like a "Play" button on TV apps.
struct PrimaryPlayButtonStyle: ButtonStyle {
    var fullWidth = true
    @Environment(\.isEnabled) private var isEnabled

    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .font(.headline)
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, Space.xl)
            .frame(maxWidth: fullWidth ? .infinity : nil, minHeight: Metrics.playButtonHeight)
            .foregroundStyle(Color(uiColor: .systemBackground))
            .background(Color.primary, in: .capsule)
            .opacity(isEnabled ? (configuration.isPressed ? 0.75 : 1) : 0.35)
            .contentShape(.capsule)
    }
}

/// Outlined resolution tag: "4K", "1080p".
struct QualityBadge: View {
    let resolution: String

    private var text: String { resolution == "2160p" ? "4K" : resolution }

    var body: some View {
        Text(text)
            .font(.caption2.weight(.semibold))
            .padding(.horizontal, Space.xs)
            .padding(.vertical, 1)
            .overlay(RoundedRectangle(cornerRadius: 3, style: .continuous).stroke(.secondary, lineWidth: 1))
            .accessibilityLabel(resolution == "2160p" ? "4K" : resolution)
    }
}

/// How well a search result will stream, from its seeder count.
struct AvailabilityLabel: View {
    let seeders: Int

    private var level: (text: String, bars: Double) {
        switch seeders {
        case ..<1: return ("Unavailable", 0)
        case 1..<5: return ("Slow", 0.34)
        case 5..<50: return ("Good", 0.67)
        default: return ("Fast", 1)
        }
    }

    var body: some View {
        Label {
            Text(level.text)
        } icon: {
            Image(systemName: "cellularbars", variableValue: level.bars)
        }
        .labelStyle(CompactLabelStyle())
        .foregroundStyle(seeders > 0 ? AnyShapeStyle(.secondary) : AnyShapeStyle(.tertiary))
        .accessibilityLabel("Availability: \(level.text)")
    }
}

/// Icon and text set tight together.
struct CompactLabelStyle: LabelStyle {
    func makeBody(configuration: Configuration) -> some View {
        HStack(spacing: Space.xs) {
            configuration.icon.imageScale(.small)
            configuration.title
        }
    }
}

/// Thin watched-progress bar under artwork and episode titles, or along the bottom of artwork.
struct WatchedBar: View {
    let fraction: Double
    var onArtwork = false

    var body: some View {
        GeometryReader { geo in
            ZStack(alignment: .leading) {
                if onArtwork {
                    Capsule().fill(.white.opacity(0.35))
                } else {
                    Capsule().fill(.fill.secondary)
                }
                Capsule().fill(.red).frame(width: max(3, geo.size.width * min(max(fraction, 0), 1)))
            }
        }
        .frame(height: onArtwork ? 4 : 3)
        .accessibilityLabel("Watched")
        .accessibilityValue("\(Int(min(max(fraction, 0), 1) * 100)) percent")
    }
}

/// A started show or title on Home: a wide still with how far along, the name, then the episode and time left.
struct ContinueCardLabel: View {
    let imageURL: URL?
    let title: String
    let detail: String?
    let progress: Double?
    var isLoading = false

    var body: some View {
        VStack(alignment: .leading, spacing: Space.s) {
            PosterImage(url: imageURL, title: title, cornerRadius: Radius.medium)
                .frame(width: Metrics.wideCardWidth, height: Metrics.wideCardWidth * 9 / 16)
                .overlay {
                    if isLoading { ProgressView().accessibilityLabel("Loading") }
                }
                .overlay(alignment: .bottom) {
                    if let progress, progress > 0.02 {
                        WatchedBar(fraction: progress, onArtwork: true)
                            .padding(Space.s)
                    }
                }
            VStack(alignment: .leading, spacing: Space.xxs) {
                Text(title)
                    .font(.subheadline.weight(.semibold))
                    .lineLimit(1)
                if let detail {
                    Text(detail)
                        .font(.footnote)
                        .foregroundStyle(.secondary)
                        .lineLimit(1)
                }
            }
        }
        .frame(width: Metrics.wideCardWidth, alignment: .leading)
        .contentShape(.rect)
    }
}

/// Transient confirmation ("Saved to Photos"). The result is also visible in place.
struct Toast: Equatable, Identifiable {
    let id = UUID()
    let message: String
    let systemImage: String
}

struct ToastView: View {
    let toast: Toast

    var body: some View {
        Label(toast.message, systemImage: toast.systemImage)
            .font(.subheadline.weight(.semibold))
            .padding(.horizontal, Space.l)
            .padding(.vertical, Space.m)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
            .accessibilityAddTraits(.isStaticText)
    }
}
