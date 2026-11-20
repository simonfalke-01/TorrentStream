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

/// Fixed geometry shared by list rows.
enum Metrics {
    static let rowArtwork = CGSize(width: 48, height: 64)
    static let headerArtwork = CGSize(width: 96, height: 128)
    static let rowIcon: CGFloat = 28
    static let indicator: CGFloat = 22
    static let touchTarget: CGFloat = 44
    static let watchedBar: CGFloat = 120
}

// MARK: - Formatting

enum Format {
    static func bytes(_ v: Int64) -> String {
        ByteCountFormatter.string(fromByteCount: v, countStyle: .file)
    }

    static func rate(_ v: Double) -> String { bytes(Int64(v)) + "/s" }

    static func time(_ ms: Int64) -> String {
        let s = max(0, ms / 1000)
        let h = s / 3600, m = (s % 3600) / 60, sec = s % 60
        return h > 0 ? String(format: "%d:%02d:%02d", h, m, sec) : String(format: "%d:%02d", m, sec)
    }

    static func seconds(_ s: Double) -> String {
        time(s.isFinite ? Int64(max(0, s) * 1000) : 0)
    }

    static func percent(_ fraction: Double) -> String {
        "\(Int((min(max(fraction, 0), 1) * 100).rounded(.down)))%"
    }

    static func peers(_ n: Int) -> String { n == 1 ? "1 peer" : "\(n) peers" }

    static func count(_ n: Int) -> String { n.formatted(.number) }

    static func videos(_ n: Int) -> String { n == 1 ? "1 video" : "\(count(n)) videos" }

    /// Folder rows: "12 videos, 4.2 GB", or "3 of 12 watched, 4.2 GB" once watching has started.
    static func folderSummary(videos n: Int, watched: Int, bytes: Int64) -> String {
        let lead = watched > 0 ? "\(count(watched)) of \(count(n)) watched" : videos(n)
        return "\(lead), \(Format.bytes(bytes))"
    }

    /// "3 days ago".
    static func age(_ date: Date) -> String {
        date.formatted(.relative(presentation: .named, unitsStyle: .abbreviated))
    }

    /// "12 min", one unit.
    static func duration(_ seconds: Double) -> String? {
        guard seconds.isFinite, seconds >= 1 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .short
        f.maximumUnitCount = 1
        return f.string(from: seconds)
    }

    /// "12 min left", or nil when the rate is too low to estimate.
    static func eta(remaining: Int64, rate: Double) -> String? {
        guard rate > 1024, remaining > 0 else { return nil }
        return duration(Double(remaining) / rate).map { "\($0) left" }
    }
}

extension MediaKind {
    var symbol: String {
        switch self {
        case .video: return "film"
        case .audio: return "music.note"
        case .subtitle: return "captions.bubble"
        case .other: return "doc"
        }
    }
}

extension TorrentFile {
    var kind: MediaKind { MediaKind(fileExtension: fileExtension) }
    var isImage: Bool { ["jpg", "jpeg", "png", "webp", "heic"].contains(fileExtension) }
    /// Readable name for rows and the player: no extension, release-group tag or checksum.
    var title: String { MediaTitle.clean(fileName) }
    /// "MKV", or nil for files without an extension.
    var formatTag: String? { fileExtension.isEmpty || fileExtension.count > 5 ? nil : fileExtension.uppercased() }
    /// Folder inside the torrent, for rows that list files from several folders.
    var folderPath: String? { path.count > 1 ? path.dropLast().joined(separator: " / ") : nil }
}

// MARK: - Status vocabulary (the only place user-facing state strings are built)

extension TorrentStatus {
    private var activeRemaining: Int64 {
        files.filter { $0.isDownloading && !$0.file.isPadding }
            .reduce(Int64(0)) { $0 + $1.file.length - $1.downloadedBytes }
    }

    /// Whether a progress bar is meaningful for this torrent right now.
    var showsProgress: Bool {
        phase == .ready && !isComplete && downloadedBytes > 0 && (hasActiveDownloads || isPaused)
    }

    /// One line for library rows.
    var summaryText: String {
        switch phase {
        case .fetchingMetadata: return connectedPeers > 0 ? "Fetching file list" : "Looking for peers"
        case .failed(let message): return message
        case .ready:
            if isComplete { return "Downloaded" }
            if isPaused { return "Paused at \(Format.percent(progress))" }
            if hasActiveDownloads {
                if connectedPeers == 0 { return "Waiting for peers" }
                return Format.eta(remaining: activeRemaining, rate: downloadRate) ?? "Downloading"
            }
            return sizeText
        }
    }

    private var videoCount: Int { files.filter { $0.file.kind == .video && !$0.file.isPadding }.count }

    /// Size line for the detail header and idle library rows: "12 videos, 14.2 GB".
    var sizeText: String {
        let amount = isComplete || downloadedBytes == 0
            ? Format.bytes(totalLength)
            : "\(Format.bytes(downloadedBytes)) of \(Format.bytes(totalLength))"
        return videoCount > 1 ? "\(Format.videos(videoCount)), \(amount)" : amount
    }

    /// Live activity for the detail header, nil when idle.
    var activityText: String? {
        guard phase == .ready else { return nil }
        if isComplete { return "Downloaded" }
        if isPaused { return "Paused" }
        guard hasActiveDownloads else { return nil }
        if connectedPeers == 0 { return "Waiting for peers" }
        let speed = "\(Format.rate(downloadRate)) from \(Format.peers(connectedPeers))"
        if let eta = Format.eta(remaining: activeRemaining, rate: downloadRate) { return "\(speed), \(eta)" }
        return speed
    }
}

extension FileStatus {
    /// Secondary row text: "MKV, 1.4 GB". Download state itself is shown by `FileStateIndicator`.
    var detailText: String {
        let amount = isComplete || downloadedBytes == 0
            ? Format.bytes(file.length)
            : "\(Format.bytes(downloadedBytes)) of \(Format.bytes(file.length))"
        return file.formatTag.map { "\($0), \(amount)" } ?? amount
    }

    /// Media rows: "Watched, MKV, 1.4 GB" once the file has been watched to the end.
    func detailText(watched: Bool) -> String {
        watched ? "Watched, \(detailText)" : detailText
    }

    var accessibilityState: String {
        if isComplete { return "Downloaded" }
        if isDownloading { return "Downloading, \(Format.percent(progress))" }
        if downloadedBytes > 0 { return "\(Format.percent(progress)) downloaded" }
        return "Not downloaded"
    }
}

// MARK: - Primitives

/// Poster art shipped inside the torrent (poster.jpg, cover.png, ...), or a neutral placeholder.
struct ArtworkView: View {
    let url: URL?
    let symbol: String
    var cornerRadius: CGFloat = Radius.small

    var body: some View {
        ZStack {
            Rectangle().fill(.fill.tertiary)
            Image(systemName: symbol)
                .font(.title3)
                .foregroundStyle(.secondary)
            if let url {
                AsyncImage(url: url) { phase in
                    if let image = phase.image { image.resizable().scaledToFill() }
                }
            }
        }
        .clipShape(.rect(cornerRadius: cornerRadius, style: .continuous))
        .accessibilityHidden(true)
    }
}

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 2.5
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(.quaternary, lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
        }
    }
}

/// Download state at the trailing edge of a row: a checkmark when finished, a ring while downloading,
/// nothing otherwise.
struct StateIndicator: View {
    let isComplete: Bool
    let isDownloading: Bool
    let progress: Double
    var paused = false

    var body: some View {
        Group {
            if isComplete {
                Image(systemName: "checkmark.circle.fill")
                    .font(.title3)
                    .foregroundStyle(.green)
            } else if isDownloading {
                ProgressRing(progress: progress, tint: paused ? .secondary : .accentColor)
                    .padding(Space.xxs)
            }
        }
        .frame(width: Metrics.indicator, height: Metrics.indicator)
        .accessibilityHidden(true)
    }
}

struct FileStateIndicator: View {
    let status: FileStatus
    var paused = false

    var body: some View {
        StateIndicator(isComplete: status.isComplete, isDownloading: status.isDownloading,
                       progress: status.progress, paused: paused)
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
