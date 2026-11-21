import SwiftUI
import UIKit
import ImageIO
import CatalogKit

/// Posters, banners and episode stills. Each is downloaded once however many views ask for it, kept on disk
/// (catalog image URLs never change content), decoded off the main thread at the size it's drawn rather than full
/// size, and kept decoded in memory, so a poster scrolled back into view or shown on the next screen appears on
/// the first frame with no placeholder and no fade.
final class ImagePipeline: @unchecked Sendable {
    static let shared = ImagePipeline()

    private let memory = NSCache<NSString, UIImage>()
    private let session: URLSession
    private let directory: URL
    private let lock = NSLock()
    private var running: [URL: Task<Data, Error>] = [:]
    /// The last decoded variant of each image, so a view can show something before it knows its size.
    private var latest: [URL: NSString] = [:]
    private static let diskLimit: Int64 = 250 << 20

    private init() {
        memory.totalCostLimit = 150 << 20
        let config = URLSessionConfiguration.default
        // Our own disk cache keeps images; URLCache would only store them a second time.
        config.urlCache = nil
        config.requestCachePolicy = .reloadIgnoringLocalCacheData
        config.httpMaximumConnectionsPerHost = 8
        config.timeoutIntervalForRequest = 20
        session = URLSession(configuration: config)
        directory = FileManager.default.urls(for: .cachesDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("Images", isDirectory: true)
        try? FileManager.default.createDirectory(at: directory, withIntermediateDirectories: true)
        let dir = directory
        DispatchQueue.global(qos: .background).asyncAfter(deadline: .now() + 20) { Self.trim(dir, limit: Self.diskLimit) }
    }

    // MARK: memory

    private func key(_ url: URL, _ pixels: CGSize) -> NSString {
        "\(Int(pixels.width))x\(Int(pixels.height))|\(url.absoluteString)" as NSString
    }

    /// Sizes are rounded up so views a point or two apart share a decode.
    static func bucket(_ pixels: CGSize) -> CGSize {
        func up(_ v: CGFloat) -> CGFloat { (v / 32).rounded(.up) * 32 }
        return CGSize(width: up(pixels.width), height: up(pixels.height))
    }

    /// A decoded image for exactly this size, if in memory.
    func cached(_ url: URL, pixels: CGSize) -> UIImage? {
        memory.object(forKey: key(url, Self.bucket(pixels)))
    }

    /// Whatever decode of the image is in memory, for the first frame of a view.
    func anyCached(_ url: URL) -> UIImage? {
        guard let k = lock.withLock({ latest[url] }) else { return nil }
        return memory.object(forKey: k)
    }

    private func remember(_ image: UIImage, _ url: URL, _ pixels: CGSize) {
        let k = key(url, pixels)
        let cg = image.cgImage
        memory.setObject(image, forKey: k, cost: (cg?.bytesPerRow ?? 0) * (cg?.height ?? 0))
        lock.withLock { latest[url] = k }
    }

    // MARK: loading

    /// The image decoded to cover `pixels` (aspect fill), never larger than the original.
    func image(_ url: URL, pixels: CGSize, priority: Float = URLSessionTask.highPriority) async -> UIImage? {
        let size = Self.bucket(pixels)
        if let hit = memory.object(forKey: key(url, size)) { return hit }
        guard let data = try? await data(url, priority: priority) else { return nil }
        let decoded = await Task.detached(priority: .userInitiated) { Self.decode(data, fill: size) }.value
        if let decoded { remember(decoded, url, size) }
        return decoded
    }

    /// The file's bytes, from disk or the network. Concurrent requests share one download.
    func data(_ url: URL, priority: Float = URLSessionTask.defaultPriority) async throws -> Data {
        let file = fileURL(url)
        if let d = await Task.detached(priority: .userInitiated, operation: { try? Data(contentsOf: file) }).value, !d.isEmpty {
            return d
        }
        let task: Task<Data, Error> = lock.withLock {
            if let t = running[url] { return t }
            let session = self.session
            let t = Task.detached(priority: .userInitiated) { () throws -> Data in
                let (d, response) = try await HTTP.data(session, for: URLRequest(url: url), priority: priority)
                if let http = response as? HTTPURLResponse, !(200..<300).contains(http.statusCode) {
                    throw URLError(.badServerResponse)
                }
                guard !d.isEmpty else { throw URLError(.zeroByteResource) }
                try? d.write(to: file, options: .atomic)
                return d
            }
            running[url] = t
            return t
        }
        defer { lock.withLock { running[url] = nil } }
        return try await task.value
    }

    /// Downloads images about to be shown. With a size, they are also decoded so they appear on the first frame.
    func prefetch(_ urls: [URL], pixels: CGSize? = nil) {
        var seen = Set<URL>()
        for url in urls where seen.insert(url).inserted {
            Task.detached(priority: .utility) {
                if let pixels {
                    _ = await self.image(url, pixels: pixels, priority: URLSessionTask.lowPriority)
                } else {
                    _ = try? await self.data(url, priority: URLSessionTask.lowPriority)
                }
            }
        }
    }

    /// A much smaller version of an AniList cover that arrives in one round trip, shown while the full one loads.
    static func preview(of url: URL) -> URL? {
        guard url.host?.hasSuffix("anilist.co") == true, url.path.contains("/cover/large/") else { return nil }
        return URL(string: url.absoluteString.replacingOccurrences(of: "/cover/large/", with: "/cover/small/"))
    }

    /// Whether the full image is on disk already (no preview needed).
    func isOnDisk(_ url: URL) -> Bool {
        FileManager.default.fileExists(atPath: fileURL(url).path)
    }

    // MARK: decoding

    /// Decodes straight to a bitmap of the needed size: ImageIO reads only what it needs from the JPEG, and the
    /// result is drawn without further work on the main thread.
    static func decode(_ data: Data, fill pixels: CGSize) -> UIImage? {
        guard let source = CGImageSourceCreateWithData(data as CFData, [kCGImageSourceShouldCache: false] as CFDictionary) else {
            return nil
        }
        var maxSide = max(pixels.width, pixels.height)
        if let props = CGImageSourceCopyPropertiesAtIndex(source, 0, nil) as? [CFString: Any],
           let w = (props[kCGImagePropertyPixelWidth] as? NSNumber)?.doubleValue,
           let h = (props[kCGImagePropertyPixelHeight] as? NSNumber)?.doubleValue, w > 0, h > 0 {
            let scale = min(1, max(pixels.width / w, pixels.height / h))
            maxSide = max(w, h) * scale
        }
        let options: [CFString: Any] = [
            kCGImageSourceCreateThumbnailFromImageAlways: true,
            kCGImageSourceCreateThumbnailWithTransform: true,
            kCGImageSourceShouldCacheImmediately: true,
            kCGImageSourceThumbnailMaxPixelSize: max(1, Int(maxSide.rounded(.up))),
        ]
        guard let cg = CGImageSourceCreateThumbnailAtIndex(source, 0, options as CFDictionary) else { return nil }
        return UIImage(cgImage: cg)
    }

    // MARK: disk

    private func fileURL(_ url: URL) -> URL {
        var h: UInt64 = 0xcbf2_9ce4_8422_2325
        for b in url.absoluteString.utf8 { h = (h ^ UInt64(b)) &* 0x100_0000_01b3 }
        return directory.appendingPathComponent(String(h, radix: 16))
    }

    /// Drops the least recently written files beyond `limit` bytes.
    private static func trim(_ dir: URL, limit: Int64) {
        let keys: [URLResourceKey] = [.contentModificationDateKey, .totalFileAllocatedSizeKey]
        guard let files = try? FileManager.default.contentsOfDirectory(at: dir, includingPropertiesForKeys: keys) else { return }
        var entries = files.compactMap { u -> (URL, Date, Int64)? in
            guard let v = try? u.resourceValues(forKeys: Set(keys)) else { return nil }
            return (u, v.contentModificationDate ?? .distantPast, Int64(v.totalFileAllocatedSize ?? 0))
        }
        var total = entries.reduce(0) { $0 + $1.2 }
        guard total > limit else { return }
        entries.sort { $0.1 < $1.1 }
        for (u, _, size) in entries where total > limit {
            try? FileManager.default.removeItem(at: u)
            total -= size
        }
    }
}

/// An image loaded through `ImagePipeline`, filling its frame. Shows a decoded copy from memory on the first
/// frame when there is one; otherwise fades in once loaded.
struct PipelineImage: View {
    let url: URL
    @Environment(\.displayScale) private var displayScale
    @State private var image: UIImage?
    @State private var imageURL: URL?
    @State private var isPreview = false
    @State private var size: CGSize = .zero

    init(url: URL) {
        self.url = url
        let hit = ImagePipeline.shared.anyCached(url)
        _image = State(initialValue: hit)
        _imageURL = State(initialValue: hit == nil ? nil : url)
    }

    private struct LoadKey: Equatable {
        let url: URL
        let size: CGSize
    }

    var body: some View {
        let shown = imageURL == url ? image : ImagePipeline.shared.anyCached(url)
        ZStack {
            if let shown {
                Image(uiImage: shown)
                    .resizable()
                    .scaledToFill()
                    .transition(.opacity)
            }
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .onGeometryChange(for: CGSize.self) { $0.size } action: { size = $0 }
        .task(id: LoadKey(url: url, size: ImagePipeline.bucket(size))) { await load() }
    }

    private func load() async {
        guard size.width > 0, size.height > 0 else { return }
        let pixels = CGSize(width: size.width * displayScale, height: size.height * displayScale)
        let pipeline = ImagePipeline.shared
        let url = self.url
        if imageURL == url, !isPreview, let image, pipeline.cached(url, pixels: pixels) === image { return }
        let showing = (imageURL == url && image != nil) || pipeline.anyCached(url) != nil
        // A tiny version first when the full one has to come over the network.
        let preview = showing || pipeline.isOnDisk(url) ? nil : ImagePipeline.preview(of: url)
        await withTaskGroup(of: (full: Bool, image: UIImage?).self) { group in
            group.addTask { (true, await pipeline.image(url, pixels: pixels)) }
            if let preview { group.addTask { (false, await pipeline.image(preview, pixels: pixels)) } }
            for await result in group {
                guard !Task.isCancelled, let got = result.image else { continue }
                if result.full {
                    let fade = !showing && imageURL != url
                    withAnimation(fade ? Motion.standard : nil) {
                        image = got
                        imageURL = url
                        isPreview = false
                    }
                    group.cancelAll()
                    return
                } else if imageURL != url {
                    withAnimation(Motion.standard) {
                        image = got
                        imageURL = url
                        isPreview = true
                    }
                }
            }
        }
    }
}
