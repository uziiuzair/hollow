import AppKit
import CoreText
import DiskApp

/// One label line as the GPU sees it. Field for field the same as `LabelQuad` in `TreemapScene.shaderSource`.
struct LabelQuad: Equatable, Sendable {
    /// x, y, w, h in points, top-left origin.
    var rect: SIMD4<Float>
    /// u0, v0, u1, v1 in the atlas, top-left origin.
    var uv: SIMD4<Float>
    var topLevel: Int32
}

/// Every label line of a snapshot, rasterized once into one premultiplied BGRA image.
/// Built off main, read on main; all fields are immutable.
final class LabelAtlas: @unchecked Sendable {
    let image: CGImage?
    let quads: [LabelQuad]

    private init(image: CGImage?, quads: [LabelQuad]) {
        self.image = image
        self.quads = quads
    }

    private struct Item {
        var line: CTLine
        var descent: CGFloat
        /// Points, top-left origin, in the map.
        var origin: CGPoint
        var pixelSize: (w: Int, h: Int)
        var topLevel: Int32
        var slot = (x: 0, y: 0)
    }

    private static func font(_ style: LabelStyle) -> CTFont {
        switch style {
        case .name: NSFont.systemFont(ofSize: 13, weight: .semibold)
        case .nameLarge: NSFont.systemFont(ofSize: 17, weight: .semibold)
        case .size: NSFont.monospacedDigitSystemFont(ofSize: 12, weight: .regular)
        case .sizeLarge: NSFont.monospacedDigitSystemFont(ofSize: 13, weight: .regular)
        case .growth: NSFont.systemFont(ofSize: 12, weight: .semibold)
        }
    }

    private static func line(_ text: String, _ style: LabelStyle, color: CGColor) -> CTLine {
        var color = color
        if style == .size || style == .sizeLarge { color = color.copy(alpha: color.alpha * 0.8) ?? color }
        let attributes: [NSAttributedString.Key: Any] = [
            NSAttributedString.Key(kCTFontAttributeName as String): font(style),
            NSAttributedString.Key(kCTForegroundColorAttributeName as String): color,
        ]
        return CTLineCreateWithAttributedString(NSAttributedString(string: text, attributes: attributes))
    }

    /// Labels depth-1 rects (in their header when they have one) and childless deeper rects.
    /// Packs rows tallest first into an atlas at most `maxPixels` on a side, and skips what no longer fits.
    /// `darkText[i]` picks near-black over white for rect i (from `TreemapScene.darkLabels`).
    static func build(snapshot: MapSnapshot, scale: CGFloat, darkText: [Bool], maxPixels: Int = 4096) -> LabelAtlas {
        let layout = snapshot.layout
        let white = CGColor(srgbRed: 1, green: 1, blue: 1, alpha: 1)
        // The mockup's light-mode text color.
        let ink = CGColor(srgbRed: 0x16 / 255, green: 0x16 / 255, blue: 0x1D / 255, alpha: 0.9)
        // A header folder keeps its label in its top band (preflight C12).
        let headerHeight = TreemapOptions().headerHeight
        let mapArea = layout.bounds.width * layout.bounds.height
        let measure: (String, LabelStyle) -> CGFloat = { text, style in
            CGFloat(CTLineGetTypographicBounds(line(text, style, color: white), nil, nil, nil))
        }

        var items: [Item] = []
        var tops = [Int32](repeating: 0, count: layout.rects.count)
        for (i, r) in layout.rects.enumerated() {
            tops[i] = r.parent < 0 ? Int32(i) : (r.parent < i ? tops[r.parent] : Int32(layout.topLevel(of: i)))
            guard r.depth == 1 || r.childCount == 0, i < snapshot.nodes.count else { continue }
            let node = snapshot.nodes[i]
            let frame = r.hasHeader && r.childCount > 0
                ? CGRect(x: r.frame.minX, y: r.frame.minY, width: r.frame.width, height: headerHeight)
                : r.frame
            let growth = node.growth >= TreemapScene.stripeThreshold
                ? Format.signedGB(node.growth) + " " + Format.periodWords(snapshot.period) : nil
            let large = mapArea > 0 && r.frame.width * r.frame.height >= 0.2 * mapArea
            guard let plan = LabelFit.plan(name: node.name, size: Format.gb(r.size), growth: growth,
                                           frame: frame, large: large, measure: measure) else { continue }
            let color = i < darkText.count && darkText[i] ? ink : white
            for l in plan.lines {
                let ct = line(l.text, l.style, color: color)
                var ascent: CGFloat = 0, descent: CGFloat = 0, leading: CGFloat = 0
                let width = CTLineGetTypographicBounds(ct, &ascent, &descent, &leading)
                let w = Int((CGFloat(width) * scale).rounded(.up)) + 2
                let h = Int(((ascent + descent) * scale).rounded(.up)) + 2
                items.append(Item(line: ct, descent: descent,
                                  origin: CGPoint(x: frame.minX + l.origin.x, y: frame.minY + l.origin.y),
                                  pixelSize: (w, h), topLevel: tops[i]))
            }
        }

        // Shelf packing, tallest first.
        let order = items.indices.sorted {
            items[$0].pixelSize.h != items[$1].pixelSize.h ? items[$0].pixelSize.h > items[$1].pixelSize.h
                : items[$0].pixelSize.w > items[$1].pixelSize.w
        }
        var placed: [Int] = []
        var x = 0, y = 0, rowHeight = 0, usedWidth = 0
        for index in order {
            let (w, h) = items[index].pixelSize
            guard w <= maxPixels else { continue }
            if x + w > maxPixels { y += rowHeight; x = 0; rowHeight = 0 }
            guard y + h <= maxPixels else { continue }
            items[index].slot = (x, y)
            x += w
            rowHeight = max(rowHeight, h)
            usedWidth = max(usedWidth, x)
            placed.append(index)
        }
        let height = y + rowHeight
        guard !placed.isEmpty, usedWidth > 0, height > 0,
              let context = CGContext(data: nil, width: usedWidth, height: height, bitsPerComponent: 8, bytesPerRow: 0,
                                      space: CGColorSpace(name: CGColorSpace.sRGB)!,
                                      bitmapInfo: CGImageAlphaInfo.premultipliedFirst.rawValue | CGBitmapInfo.byteOrder32Little.rawValue)
        else { return LabelAtlas(image: nil, quads: []) }

        context.setShouldSmoothFonts(false)
        context.scaleBy(x: scale, y: scale)
        var quads: [LabelQuad] = []
        quads.reserveCapacity(placed.count)
        let atlasW = Float(usedWidth), atlasH = Float(height)
        for index in placed {
            let item = items[index]
            let (w, h) = item.pixelSize
            let (sx, sy) = item.slot
            // The context's origin is bottom left; the slot is measured from the top.
            context.textPosition = CGPoint(x: (CGFloat(sx) + 1) / scale,
                                           y: (CGFloat(height - sy - h) + 1) / scale + item.descent)
            CTLineDraw(item.line, context)
            quads.append(LabelQuad(
                rect: SIMD4(Float(item.origin.x - 1 / scale), Float(item.origin.y - 1 / scale), Float(w) / Float(scale), Float(h) / Float(scale)),
                uv: SIMD4(Float(sx) / atlasW, Float(sy) / atlasH, Float(sx + w) / atlasW, Float(sy + h) / atlasH),
                topLevel: item.topLevel))
        }
        return LabelAtlas(image: context.makeImage(), quads: quads)
    }
}
