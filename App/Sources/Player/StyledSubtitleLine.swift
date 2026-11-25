import SwiftUI
import CoreText
import SubtitleKit

/// Fonts attached to the playing file, found by the names ASS styles give them. They're used straight from their
/// descriptors, so nothing is registered with the system.
enum SubtitleFonts {
    private static let lock = NSLock()
    private static var byName: [String: [CTFontDescriptor]] = [:]

    static func add(_ files: [Data]) {
        var found: [String: [CTFontDescriptor]] = [:]
        for data in files {
            guard let list = CTFontManagerCreateFontDescriptorsFromData(data as CFData) as? [CTFontDescriptor] else { continue }
            for d in list {
                for attribute in [kCTFontFamilyNameAttribute, kCTFontDisplayNameAttribute, kCTFontNameAttribute] {
                    if let name = CTFontDescriptorCopyAttribute(d, attribute) as? String {
                        found[name.lowercased(), default: []].append(d)
                    }
                }
            }
        }
        guard !found.isEmpty else { return }
        lock.lock()
        defer { lock.unlock() }
        for (k, v) in found { byName[k, default: []] += v }
    }

    /// The face for an ASS style: an attached font by family, full or PostScript name, else an installed one, else
    /// Helvetica Neue (libVLC's fallback for ASS on Apple platforms). Bold and italic are made up when the family
    /// has no such face, as libass does.
    static func font(named name: String, size: CGFloat, bold: Bool, italic: Bool) -> CTFont {
        let key = name.trimmingCharacters(in: .whitespaces).lowercased()
        lock.lock()
        let attached = byName[key.hasPrefix("@") ? String(key.dropFirst()) : key]
        lock.unlock()
        var base: CTFont
        if let attached, !attached.isEmpty {
            let best = attached.max { score($0, bold: bold, italic: italic) < score($1, bold: bold, italic: italic) }!
            base = CTFontCreateWithFontDescriptor(best, size, nil)
        } else if let installed = UIFont(name: name, size: size) {
            base = installed as CTFont
        } else {
            let family = UIFontDescriptor(fontAttributes: [.family: name])
            let match = UIFont(descriptor: family, size: size)
            base = match.familyName.caseInsensitiveCompare(name) == .orderedSame
                ? match as CTFont
                : CTFontCreateWithName("HelveticaNeue" as CFString, size, nil)
        }
        var wanted: CTFontSymbolicTraits = []
        if bold { wanted.insert(.traitBold) }
        if italic { wanted.insert(.traitItalic) }
        let has = CTFontGetSymbolicTraits(base)
        let missing = wanted.subtracting(has)
        if !missing.isEmpty, let styled = CTFontCreateCopyWithSymbolicTraits(base, size, nil, wanted, wanted) {
            base = styled
        }
        if missing.contains(.traitItalic), !CTFontGetSymbolicTraits(base).contains(.traitItalic) {
            var slant = CGAffineTransform(a: 1, b: 0, c: 0.2, d: 1, tx: 0, ty: 0)
            base = CTFontCreateCopyWithAttributes(base, size, &slant, nil)
        }
        return base
    }

    private static func score(_ d: CTFontDescriptor, bold: Bool, italic: Bool) -> Int {
        let traits = CTFontDescriptorCopyAttribute(d, kCTFontTraitsAttribute) as? [String: Any]
        let symbolic = CTFontSymbolicTraits(rawValue: (traits?[kCTFontSymbolicTrait as String] as? NSNumber)?.uint32Value ?? 0)
        var s = 0
        if symbolic.contains(.traitBold) == bold { s += 2 }
        if symbolic.contains(.traitItalic) == italic { s += 1 }
        return s
    }
}

/// One ASS line drawn the way libass draws it with its style: the style's font sized to the picture, its colours,
/// outline, shadow or box, and its alignment and margins within the picture.
struct StyledSubtitleLine: UIViewRepresentable {
    let text: String
    let style: ASSStyle
    let playRes: CGSize
    /// The picture's frame in this view's coordinates.
    let picture: CGRect

    func makeUIView(context: Context) -> Canvas {
        let v = Canvas()
        v.isOpaque = false
        v.backgroundColor = .clear
        v.isUserInteractionEnabled = false
        v.contentMode = .redraw
        return v
    }

    func updateUIView(_ v: Canvas, context: Context) {
        v.content = Canvas.Content(text: text, style: style, playRes: playRes, picture: picture)
    }

    final class Canvas: UIView {
        struct Content: Equatable {
            let text: String
            let style: ASSStyle
            let playRes: CGSize
            let picture: CGRect
        }

        var content: Content? {
            didSet { if content != oldValue { setNeedsDisplay() } }
        }

        override func draw(_ rect: CGRect) {
            guard let c = content, let ctx = UIGraphicsGetCurrentContext(),
                  c.playRes.width > 0, c.playRes.height > 0, c.picture.width > 0, c.picture.height > 0 else { return }
            let s = c.style
            let sx = c.picture.width / c.playRes.width
            let sy = c.picture.height / c.playRes.height

            // libass sizes a font so its ascender-to-descender height (as VSFilter measures it) is the style's size.
            let probe = SubtitleFonts.font(named: s.fontName, size: 100, bold: s.bold, italic: s.italic)
            let height = CTFontGetAscent(probe) + CTFontGetDescent(probe)
            let pointSize = max(4, CGFloat(s.fontSize) * sy * (height > 0 ? 100 / height : 1))
            let font = SubtitleFonts.font(named: s.fontName, size: pointSize, bold: s.bold, italic: s.italic)

            let paragraph = NSMutableParagraphStyle()
            switch (s.alignment - 1) % 3 {
            case 0: paragraph.alignment = .left
            case 2: paragraph.alignment = .right
            default: paragraph.alignment = .center
            }
            paragraph.lineBreakMode = .byWordWrapping
            var base: [NSAttributedString.Key: Any] = [.font: font, .paragraphStyle: paragraph]
            if s.spacing != 0 { base[.kern] = CGFloat(s.spacing) * sx }
            if s.scaleX != s.scaleY { base[.expansion] = log(CGFloat(s.scaleX / s.scaleY)) }

            // Where the picture is on screen, for placing the line (the picture may run past the screen when filled).
            let area = c.picture.intersection(bounds)
            guard !area.isNull else { return }
            let left = area.minX + CGFloat(s.marginL) * sx
            let width = max(40, area.width - CGFloat(s.marginL + s.marginR) * sx)
            let measured = NSAttributedString(string: c.text, attributes: base)
                .boundingRect(with: CGSize(width: width, height: .greatestFiniteMagnitude),
                              options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            let h = ceil(measured.height)
            let y: CGFloat
            switch s.alignment {
            case 7...9: y = area.minY + CGFloat(s.marginV) * sy
            case 4...6: y = area.midY - h / 2
            default: y = area.maxY - CGFloat(s.marginV) * sy - h
            }
            let box = CGRect(x: left, y: y, width: width, height: h)

            let outline = CGFloat(s.outline) * sy
            let shadow = CGFloat(s.shadow) * sy
            let primary = Self.color(s.primaryColour)
            let edge = Self.color(s.outlineColour)
            let back = Self.color(s.backColour)
            ctx.setLineJoin(.round)

            func draw(_ fill: UIColor, stroke: UIColor?, offset: CGFloat) {
                var a = base
                a[.foregroundColor] = fill
                if let stroke, outline > 0 {
                    a[.strokeColor] = stroke
                    // Negative: fill and stroke. The stroke is centered on the glyph edge, so twice the outline.
                    a[.strokeWidth] = -200 * outline / pointSize
                }
                NSAttributedString(string: c.text, attributes: a).draw(with: box.offsetBy(dx: offset, dy: offset),
                                                                       options: [.usesLineFragmentOrigin, .usesFontLeading], context: nil)
            }

            if s.borderStyle == 3 {
                // An opaque box in the outline colour around the text, its shadow in the back colour.
                let text = CGRect(x: box.minX + (box.width - ceil(measured.width)) * Self.boxShift(paragraph.alignment),
                                  y: box.minY, width: ceil(measured.width), height: h).insetBy(dx: -outline, dy: -outline)
                if shadow > 0 {
                    ctx.setFillColor(back.cgColor)
                    ctx.fill(text.offsetBy(dx: shadow, dy: shadow))
                }
                ctx.setFillColor(edge.cgColor)
                ctx.fill(text)
                draw(primary, stroke: nil, offset: 0)
            } else {
                if shadow > 0 { draw(back, stroke: back, offset: shadow) }
                if outline > 0 { draw(edge, stroke: edge, offset: 0) }
                draw(primary, stroke: nil, offset: 0)
            }
        }

        private static func boxShift(_ alignment: NSTextAlignment) -> CGFloat {
            switch alignment {
            case .left: return 0
            case .right: return 1
            default: return 0.5
            }
        }

        /// ASS colours are 0xAABBGGRR with alpha 0 opaque.
        static func color(_ v: UInt32) -> UIColor {
            UIColor(red: CGFloat(v & 0xFF) / 255, green: CGFloat((v >> 8) & 0xFF) / 255,
                    blue: CGFloat((v >> 16) & 0xFF) / 255, alpha: 1 - CGFloat((v >> 24) & 0xFF) / 255)
        }
    }
}
