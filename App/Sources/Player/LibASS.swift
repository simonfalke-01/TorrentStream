import Foundation
import CoreGraphics
import SubtitleKit

/// libass as linked into VLCKit, which is what libVLC draws ASS subtitles with, reached by symbol name. A line the
/// app draws itself (one libVLC skipped at a seek) goes through the same renderer, so it looks exactly the same:
/// the script's fonts, styles, override tags, signs and placement.
private enum ASSSymbols {
    typealias LibraryInit = @convention(c) () -> OpaquePointer?
    typealias LibraryDone = @convention(c) (OpaquePointer?) -> Void
    typealias RendererInit = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias RendererDone = @convention(c) (OpaquePointer?) -> Void
    typealias SetSize = @convention(c) (OpaquePointer?, Int32, Int32) -> Void
    typealias SetFonts = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32,
                                         UnsafePointer<CChar>?, Int32) -> Void
    typealias AddFont = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, UnsafePointer<CChar>?, Int32) -> Void
    typealias NewTrack = @convention(c) (OpaquePointer?) -> OpaquePointer?
    typealias FreeTrack = @convention(c) (OpaquePointer?) -> Void
    typealias CodecPrivate = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32) -> Void
    typealias Chunk = @convention(c) (OpaquePointer?, UnsafePointer<CChar>?, Int32, Int64, Int64) -> Void
    typealias Render = @convention(c) (OpaquePointer?, OpaquePointer?, Int64, UnsafeMutablePointer<Int32>?) -> UnsafeRawPointer?

    struct Table {
        let libraryInit: LibraryInit
        let libraryDone: LibraryDone
        let rendererInit: RendererInit
        let rendererDone: RendererDone
        let setFrameSize: SetSize
        let setStorageSize: SetSize
        let setFonts: SetFonts
        let addFont: AddFont
        let newTrack: NewTrack
        let freeTrack: FreeTrack
        let flushEvents: FreeTrack
        let codecPrivate: CodecPrivate
        let chunk: Chunk
        let render: Render
    }

    static let table: Table? = {
        let all = UnsafeMutableRawPointer(bitPattern: -2) // RTLD_DEFAULT
        func f<T>(_ name: String, _: T.Type) -> T? {
            dlsym(all, name).map { unsafeBitCast($0, to: T.self) }
        }
        guard let libraryInit = f("ass_library_init", LibraryInit.self),
              let libraryDone = f("ass_library_done", LibraryDone.self),
              let rendererInit = f("ass_renderer_init", RendererInit.self),
              let rendererDone = f("ass_renderer_done", RendererDone.self),
              let setFrameSize = f("ass_set_frame_size", SetSize.self),
              let setStorageSize = f("ass_set_storage_size", SetSize.self),
              let setFonts = f("ass_set_fonts", SetFonts.self),
              let addFont = f("ass_add_font", AddFont.self),
              let newTrack = f("ass_new_track", NewTrack.self),
              let freeTrack = f("ass_free_track", FreeTrack.self),
              let flushEvents = f("ass_flush_events", FreeTrack.self),
              let codecPrivate = f("ass_process_codec_private", CodecPrivate.self),
              let chunk = f("ass_process_chunk", Chunk.self),
              let render = f("ass_render_frame", Render.self) else { return nil }
        return Table(libraryInit: libraryInit, libraryDone: libraryDone, rendererInit: rendererInit,
                     rendererDone: rendererDone, setFrameSize: setFrameSize, setStorageSize: setStorageSize,
                     setFonts: setFonts, addFont: addFont, newTrack: newTrack, freeTrack: freeTrack,
                     flushEvents: flushEvents, codecPrivate: codecPrivate, chunk: chunk, render: render)
    }()
}

/// A picture of the subtitles at one moment: the drawn part only, and where it goes in the video frame.
struct ASSPicture: Equatable {
    let image: CGImage
    /// In the video frame's pixels.
    let rect: CGRect
    /// The video frame it was drawn for.
    let frame: CGSize

    static func == (a: ASSPicture, b: ASSPicture) -> Bool {
        a.image === b.image && a.rect == b.rect && a.frame == b.frame
    }
}

/// One ASS track's renderer. Everything runs on its own queue; libass isn't thread-safe.
final class ASSRenderer: @unchecked Sendable {
    static var isAvailable: Bool { ASSSymbols.table != nil }

    private let queue = DispatchQueue(label: "subtitles.libass", qos: .userInitiated)
    private let s: ASSSymbols.Table
    private let library: OpaquePointer
    private let renderer: OpaquePointer
    private let track: OpaquePointer
    private var fontNames = Set<String>()
    private var frame = CGSize.zero

    /// - Parameter header: the track's CodecPrivate (the script without its events).
    init?(header: String) {
        guard let s = ASSSymbols.table, let library = s.libraryInit() else { return nil }
        guard let renderer = s.rendererInit(library) else {
            s.libraryDone(library)
            return nil
        }
        guard let track = s.newTrack(library) else {
            s.rendererDone(renderer)
            s.libraryDone(library)
            return nil
        }
        self.s = s
        self.library = library
        self.renderer = renderer
        self.track = track
        var bytes = Array(header.utf8)
        bytes.withUnsafeMutableBufferPointer { b in
            b.baseAddress!.withMemoryRebound(to: CChar.self, capacity: b.count) { s.codecPrivate(track, $0, Int32(b.count)) }
        }
        queue.async { self.loadFonts() }
    }

    deinit {
        let s = s, track = track, renderer = renderer, library = library
        queue.async {
            s.freeTrack(track)
            s.rendererDone(renderer)
            s.libraryDone(library)
        }
    }

    /// libVLC's own setup (modules/codec/libass.c): the system's fonts, Helvetica Neue when none fits.
    private func loadFonts() {
        s.setFonts(renderer, nil, "Helvetica Neue", 1 /* ASS_FONTPROVIDER_AUTODETECT */, nil, 1)
    }

    /// The file's attached fonts, which the styles name.
    func add(fonts: [(name: String, data: Data)]) {
        queue.async {
            var added = false
            for f in fonts where !self.fontNames.contains(f.name) {
                self.fontNames.insert(f.name)
                f.data.withUnsafeBytes { raw in
                    guard let base = raw.bindMemory(to: CChar.self).baseAddress else { return }
                    f.name.withCString { self.s.addFont(self.library, $0, base, Int32(raw.count)) }
                }
                added = true
            }
            if added { self.loadFonts() }
        }
    }

    /// Draws `events` (raw Matroska ASS events) as they look at `time`, for a video frame of `frame` pixels.
    func render(events: [SubtitleCue], at time: Double, frame: CGSize, completion: @escaping @Sendable (ASSPicture?) -> Void) {
        queue.async {
            completion(self.draw(events: events, at: time, frame: frame))
        }
    }

    private func draw(events: [SubtitleCue], at time: Double, frame: CGSize) -> ASSPicture? {
        let w = Int32(max(1, min(4096, frame.width.rounded())))
        let h = Int32(max(1, min(4096, frame.height.rounded())))
        if frame != self.frame {
            self.frame = frame
            s.setFrameSize(renderer, w, h)
            s.setStorageSize(renderer, w, h)
        }
        s.flushEvents(track)
        for e in events {
            guard let raw = e.raw else { continue }
            var bytes = Array(raw.utf8)
            let start = Int64((e.start * 1000).rounded())
            let length = Int64(((e.end - e.start) * 1000).rounded())
            bytes.withUnsafeMutableBufferPointer { b in
                guard let base = b.baseAddress else { return }
                base.withMemoryRebound(to: CChar.self, capacity: b.count) { s.chunk(track, $0, Int32(b.count), start, length) }
            }
        }
        var changed: Int32 = 0
        guard let first = s.render(renderer, track, Int64((time * 1000).rounded()), &changed) else { return nil }
        return Self.composite(first, frame: CGSize(width: Int(w), height: Int(h)))
    }

    /// ASS_Image: int w, h, stride; unsigned char *bitmap; uint32_t color (RGBA, A as transparency);
    /// int dst_x, dst_y; struct ass_image *next; int type.
    private struct Image {
        let w: Int, h: Int, stride: Int
        let bitmap: UnsafePointer<UInt8>
        let color: UInt32
        let x: Int, y: Int
        let next: UnsafeRawPointer?

        init(_ p: UnsafeRawPointer) {
            w = Int(p.load(fromByteOffset: 0, as: Int32.self))
            h = Int(p.load(fromByteOffset: 4, as: Int32.self))
            stride = Int(p.load(fromByteOffset: 8, as: Int32.self))
            bitmap = p.load(fromByteOffset: 16, as: UnsafePointer<UInt8>.self)
            color = p.load(fromByteOffset: 24, as: UInt32.self)
            x = Int(p.load(fromByteOffset: 28, as: Int32.self))
            y = Int(p.load(fromByteOffset: 32, as: Int32.self))
            next = p.load(fromByteOffset: 40, as: UnsafeRawPointer?.self)
        }
    }

    /// Blends libass's alpha bitmaps, back to front, into one premultiplied picture of just the drawn area.
    private static func composite(_ first: UnsafeRawPointer, frame: CGSize) -> ASSPicture? {
        var images: [Image] = []
        var p: UnsafeRawPointer? = first
        while let q = p, images.count < 10_000 {
            let i = Image(q)
            if i.w > 0, i.h > 0 { images.append(i) }
            p = i.next
        }
        guard !images.isEmpty else { return nil }
        let fw = Int(frame.width), fh = Int(frame.height)
        var minX = Int.max, minY = Int.max, maxX = Int.min, maxY = Int.min
        for i in images {
            minX = min(minX, i.x); minY = min(minY, i.y)
            maxX = max(maxX, i.x + i.w); maxY = max(maxY, i.y + i.h)
        }
        minX = max(0, minX); minY = max(0, minY)
        maxX = min(fw, maxX); maxY = min(fh, maxY)
        let width = maxX - minX, height = maxY - minY
        guard width > 0, height > 0 else { return nil }
        let rowBytes = width * 4
        var buffer = [UInt8](repeating: 0, count: rowBytes * height)
        buffer.withUnsafeMutableBufferPointer { out in
            for i in images {
                let r = UInt32(i.color >> 24), g = UInt32((i.color >> 16) & 0xFF), b = UInt32((i.color >> 8) & 0xFF)
                let opacity = 255 - UInt32(i.color & 0xFF)
                guard opacity > 0 else { continue }
                let x0 = max(i.x, minX), x1 = min(i.x + i.w, maxX)
                let y0 = max(i.y, minY), y1 = min(i.y + i.h, maxY)
                guard x0 < x1, y0 < y1 else { continue }
                for y in y0..<y1 {
                    let src = i.bitmap + (y - i.y) * i.stride - i.x
                    var o = (y - minY) * rowBytes + (x0 - minX) * 4
                    for x in x0..<x1 {
                        let k = UInt32(src[x])
                        if k != 0 {
                            let a = (k * opacity + 127) / 255
                            let keep = 255 - a
                            // BGRA, premultiplied.
                            out[o] = UInt8((b * a + UInt32(out[o]) * keep + 127) / 255)
                            out[o + 1] = UInt8((g * a + UInt32(out[o + 1]) * keep + 127) / 255)
                            out[o + 2] = UInt8((r * a + UInt32(out[o + 2]) * keep + 127) / 255)
                            out[o + 3] = UInt8(a + (UInt32(out[o + 3]) * keep + 127) / 255)
                        }
                        o += 4
                    }
                }
            }
        }
        let info = CGBitmapInfo(rawValue: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        guard let provider = CGDataProvider(data: Data(buffer) as CFData),
              let image = CGImage(width: width, height: height, bitsPerComponent: 8, bitsPerPixel: 32, bytesPerRow: rowBytes,
                                  space: CGColorSpaceCreateDeviceRGB(), bitmapInfo: info, provider: provider,
                                  decode: nil, shouldInterpolate: true, intent: .defaultIntent) else { return nil }
        return ASSPicture(image: image, rect: CGRect(x: minX, y: minY, width: width, height: height), frame: frame)
    }
}
