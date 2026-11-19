import SwiftUI
import TorrentKit

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

    static func eta(remaining: Int64, rate: Double) -> String? {
        guard rate > 1024, remaining > 0 else { return nil }
        let f = DateComponentsFormatter()
        f.allowedUnits = [.hour, .minute, .second]
        f.unitsStyle = .abbreviated
        f.maximumUnitCount = 2
        return f.string(from: Double(remaining) / rate).map { "\($0) left" }
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
}

/// Deterministic accent colour per torrent so placeholders are distinguishable.
func torrentTint(for hash: String) -> Color {
    let palette: [Color] = [.indigo, .purple, .pink, .orange, .teal, .blue, .mint, .cyan, .red]
    let v = hash.unicodeScalars.reduce(0) { ($0 &* 31 &+ Int($1.value)) & 0xffff }
    return palette[v % palette.count]
}

/// Poster art: an image shipped in the torrent (poster.jpg, cover.png, ...) or a tinted placeholder.
struct ArtworkView: View {
    let hash: String
    let url: URL?
    let symbol: String
    var cornerRadius: CGFloat = 12

    var body: some View {
        let tint = torrentTint(for: hash)
        ZStack {
            LinearGradient(colors: [tint.opacity(0.9), tint.opacity(0.45)], startPoint: .topLeading, endPoint: .bottomTrailing)
            Image(systemName: symbol)
                .font(.system(size: 28, weight: .semibold))
                .foregroundStyle(.white.opacity(0.9))
            if let url {
                AsyncImage(url: url, transaction: Transaction(animation: .easeInOut)) { phase in
                    if let image = phase.image {
                        image.resizable().scaledToFill()
                    }
                }
            }
        }
        .clipShape(RoundedRectangle(cornerRadius: cornerRadius, style: .continuous))
    }
}

struct ProgressRing: View {
    let progress: Double
    var lineWidth: CGFloat = 3
    var tint: Color = .accentColor

    var body: some View {
        ZStack {
            Circle().stroke(tint.opacity(0.2), lineWidth: lineWidth)
            Circle()
                .trim(from: 0, to: max(0.02, min(progress, 1)))
                .stroke(tint, style: StrokeStyle(lineWidth: lineWidth, lineCap: .round))
                .rotationEffect(.degrees(-90))
                .animation(.easeInOut(duration: 0.4), value: progress)
        }
    }
}

/// Small glass capsule with an icon and a value (peers, speed, ...).
struct StatChip: View {
    let systemImage: String
    let text: String

    var body: some View {
        Label(text, systemImage: systemImage)
            .font(.caption.weight(.medium).monospacedDigit())
            .labelStyle(.titleAndIcon)
            .padding(.horizontal, 10)
            .padding(.vertical, 6)
            .glassEffect(.regular, in: .capsule)
    }
}

/// Download state of a single file, shown at the trailing edge of rows.
struct FileStateIndicator: View {
    let status: FileStatus

    var body: some View {
        if status.isComplete {
            Image(systemName: "checkmark.circle.fill")
                .font(.title3)
                .foregroundStyle(.green)
                .accessibilityLabel("Downloaded")
        } else if status.isDownloading {
            ProgressRing(progress: status.progress)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Downloading \(Int(status.progress * 100)) percent")
        } else if status.downloadedBytes > 0 {
            ProgressRing(progress: status.progress, tint: .secondary)
                .frame(width: 22, height: 22)
                .accessibilityLabel("Partially downloaded")
        }
    }
}

extension FileStatus {
    /// Human readable state line, e.g. "1.2 GB · Downloaded".
    var stateText: String {
        let size = Format.bytes(file.length)
        if isComplete { return "\(size) · Downloaded" }
        if isDownloading { return "\(size) · Downloading \(Int(progress * 100))%" }
        if downloadedBytes > 0 { return "\(size) · \(Int(progress * 100))% cached" }
        return size
    }
}

/// Transient confirmation message ("Saved to Photos").
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
            .padding(.horizontal, 18)
            .padding(.vertical, 12)
            .glassEffect(.regular, in: .capsule)
            .transition(.move(edge: .top).combined(with: .opacity))
    }
}
