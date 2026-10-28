import CoreGraphics
import DiskEngine

/// One block as the GPU sees it. Field for field the same as `BlockInstance` in `TreemapScene.shaderSource`.
public struct BlockInstance: Equatable, Sendable {
    /// x, y, w, h in points, top-left origin.
    public var rect: SIMD4<Float>
    /// sRGB, straight alpha.
    public var color: SIMD4<Float>
    /// Share of the width, from the right edge, that the growth strip covers.
    public var stripe: Float
    /// Index of the depth-1 ancestor.
    public var topLevel: Int32
    /// Bit 0: top-level block. Bit 1: bucket (small files or "N more items"). Bit 2: the growth
    /// strip of a folder with children, drawn over them (transparent but for the strip).
    public var flags: UInt32
    public var pad: Float

    public init(rect: SIMD4<Float>, color: SIMD4<Float>, stripe: Float, topLevel: Int32, flags: UInt32, pad: Float = 0) {
        self.rect = rect
        self.color = color
        self.stripe = stripe
        self.topLevel = topLevel
        self.flags = flags
        self.pad = pad
    }

    public static let topLevelFlag: UInt32 = 1
    public static let bucketFlag: UInt32 = 2
    public static let stripFlag: UInt32 = 4
}

/// Per-frame values. Field for field the same as `Uniforms` in `TreemapScene.shaderSource` (stride 48).
public struct TreemapUniforms: Equatable, Sendable {
    /// The view's size in points.
    public var viewport: SIMD2<Float>
    /// The zoom transform: a point is drawn at `p * scale + offset`.
    public var scale: SIMD2<Float>
    public var offset: SIMD2<Float>
    public var pixelsPerPoint: Float
    /// -1 means none.
    public var hoveredTop: Int32
    /// -1 means none.
    public var outlinedTop: Int32
    public var labelAlpha: Float
    /// 1 adds a dark ring inside the white outline, so it reads on light fills (light mode).
    public var outlineRing: Float

    public init(viewport: SIMD2<Float> = .zero, scale: SIMD2<Float> = .one, offset: SIMD2<Float> = .zero,
                pixelsPerPoint: Float = 2, hoveredTop: Int32 = -1, outlinedTop: Int32 = -1, labelAlpha: Float = 1,
                outlineRing: Float = 0) {
        self.viewport = viewport
        self.scale = scale
        self.offset = offset
        self.pixelsPerPoint = pixelsPerPoint
        self.hoveredTop = hoveredTop
        self.outlinedTop = outlinedTop
        self.labelAlpha = labelAlpha
        self.outlineRing = outlineRing
    }
}

/// GPU-free half of the treemap renderer: what each block looks like, and the shader that draws it.
public enum TreemapScene {
    /// Growth below this draws no strip.
    public static let stripeThreshold: Int64 = 100_000_000

    /// One instance per rect, in rect order (parents before children), then one per folder with
    /// children that grew: its growth strip, drawn over the children along the folder's right edge,
    /// full height. A folder's own block would have it under its children (blocks draw in order).
    public static func instances(snapshot: MapSnapshot, dark: Bool) -> [BlockInstance] {
        let layout = snapshot.layout
        let bucket: SIMD4<Float> = dark ? SIMD4(1, 1, 1, 0.22) : SIMD4(0, 0, 0, 0.22)
        var out: [BlockInstance] = []
        var strips: [BlockInstance] = []
        out.reserveCapacity(layout.rects.count)
        for (i, r) in layout.rects.enumerated() {
            let top = r.parent < 0 ? i : (r.parent < i ? Int(out[r.parent].topLevel) : layout.topLevel(of: i))
            let node = i < snapshot.nodes.count ? snapshot.nodes[i] : nil
            var flags: UInt32 = r.parent < 0 ? BlockInstance.topLevelFlag : 0
            let color: SIMD4<Float>
            switch r.ref {
            case .small, .more:
                flags |= BlockInstance.bucketFlag
                color = bucket
            case .folder, .file:
                color = shaded(Palette.hex(node?.kind ?? .other), depth: r.depth)
            }
            let f = r.frame
            let rect = SIMD4(Float(f.minX), Float(f.minY), Float(f.width), Float(f.height))
            let share = stripe(growth: node?.growth ?? 0, size: r.size)
            let recursed = r.childCount > 0
            out.append(BlockInstance(rect: rect, color: color, stripe: recursed ? 0 : share,
                                     topLevel: Int32(top), flags: flags))
            if recursed, share > 0 {
                // White with no fill: the shader draws only the ruled strip.
                strips.append(BlockInstance(rect: rect, color: SIMD4(1, 1, 1, 0), stripe: share,
                                            topLevel: Int32(top), flags: BlockInstance.stripFlag))
            }
        }
        return out + strips
    }

    /// The kind's color, 10 points darker per level below 1, never below 0.7.
    static func shaded(_ hex: UInt32, depth: Int) -> SIMD4<Float> {
        let shade = max(Float(0.7), 1 - 0.1 * Float(depth - 1))
        return SIMD4(Float((hex >> 16) & 0xFF) / 255 * shade,
                     Float((hex >> 8) & 0xFF) / 255 * shade,
                     Float(hex & 0xFF) / 255 * shade,
                     1)
    }

    /// The strip's share of the block's width: growth over size, drawn to scale.
    public static func stripe(growth: Int64, size: UInt64) -> Float {
        guard growth >= stripeThreshold, size > 0 else { return 0 }
        return min(1, Float(Double(growth) / Double(size)))
    }

    /// The window color the map is drawn on (the renderer's clear color), sRGB grey.
    static func background(dark: Bool) -> Float { dark ? 0.196 : 0.925 }

    /// Whether each rect's label should be dark (near-black) rather than white: true when the
    /// fill under it, composited over its parents and the window, is light. Parents come
    /// before children in `layout.rects`.
    public static func darkLabels(instances: [BlockInstance], layout: TreemapLayout, dark: Bool) -> [Bool] {
        let window = SIMD3<Float>(repeating: background(dark: dark))
        var fills: [SIMD3<Float>] = []
        fills.reserveCapacity(instances.count)
        var out: [Bool] = []
        out.reserveCapacity(instances.count)
        // The strip pass after the rects has no labels.
        for (i, inst) in instances.prefix(layout.rects.count).enumerated() {
            let p = i < layout.rects.count ? layout.rects[i].parent : -1
            let under = p >= 0 && p < fills.count ? fills[p] : window
            let c = inst.color
            let fill = SIMD3(c.x, c.y, c.z) * c.w + under * (1 - c.w)
            fills.append(fill)
            out.append(luminance(fill) > 0.4)
        }
        return out
    }

    /// WCAG relative luminance of an sRGB color.
    static func luminance(_ rgb: SIMD3<Float>) -> Float {
        func linear(_ v: Float) -> Float { v <= 0.04045 ? v / 12.92 : pow((v + 0.055) / 1.055, 2.4) }
        return 0.2126 * linear(rgb.x) + 0.7152 * linear(rgb.y) + 0.0722 * linear(rgb.z)
    }

    /// The uniform for the hover outline's dark ring: on in light mode only.
    public static func outlineRing(dark: Bool) -> Float { dark ? 0 : 1 }

    public struct Appearance: Equatable, Sendable {
        public var dimmed: Bool
        /// Width in points of the white inner outline, 0 for none.
        public var outline: Float

        public init(dimmed: Bool, outline: Float) {
            self.dimmed = dimmed
            self.outline = outline
        }
    }

    /// The rule `blockVertex` applies. -1 means no hovered or outlined block.
    public static func appearance(_ i: BlockInstance, hoveredTop: Int32, outlinedTop: Int32) -> Appearance {
        Appearance(dimmed: hoveredTop >= 0 && i.topLevel != hoveredTop,
                   outline: i.flags & BlockInstance.topLevelFlag != 0 && i.topLevel == outlinedTop ? 2 : 0)
    }

    /// Blocks: one instanced triangle strip of 4 vertices per `BlockInstance`, buffer 0 the instances,
    /// buffer 1 (vertex) and 0 (fragment) the uniforms. Labels: the same with `LabelQuad`s and the atlas
    /// at texture 0. Output is premultiplied alpha.
    public static let shaderSource = """
    #include <metal_stdlib>
    using namespace metal;

    struct BlockInstance {
        float4 rect;
        float4 color;
        float stripe;
        int topLevel;
        uint flags;
        float pad;
    };

    struct LabelQuad {
        float4 rect;
        float4 uv;
        int topLevel;
    };

    struct Uniforms {
        float2 viewport;
        float2 scale;
        float2 offset;
        float pixelsPerPoint;
        int hoveredTop;
        int outlinedTop;
        float labelAlpha;
        float outlineRing;
    };

    static float4 toClip(float2 p, constant Uniforms &u) {
        return float4(p.x / u.viewport.x * 2.0 - 1.0, 1.0 - p.y / u.viewport.y * 2.0, 0.0, 1.0);
    }

    static float3 dimmed(float3 rgb) {
        float luma = dot(rgb, float3(0.2126, 0.7152, 0.0722));
        return mix(float3(luma), rgb, 0.7) * 0.78;
    }

    static float2 cornerOf(uint vid) {
        return float2(float(vid & 1u), float(vid >> 1));
    }

    struct BlockOut {
        float4 position [[position]];
        float2 local;
        float2 size [[flat]];
        float4 color [[flat]];
        float stripe [[flat]];
        float outline [[flat]];
        float dim [[flat]];
    };

    vertex BlockOut blockVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device BlockInstance *blocks [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
        BlockInstance b = blocks[iid];
        float2 origin = b.rect.xy * u.scale + u.offset;
        float2 size = b.rect.zw * u.scale;
        // One pixel of slack on each side for the antialiased edge.
        float pad = 1.0 / u.pixelsPerPoint;
        float2 local = cornerOf(vid) * (size + 2.0 * pad) - pad;
        BlockOut o;
        o.position = toClip(origin + local, u);
        o.local = local;
        o.size = size;
        o.color = b.color;
        o.stripe = b.stripe;
        o.outline = ((b.flags & 1u) != 0u && b.topLevel == u.outlinedTop) ? 2.0 : 0.0;
        o.dim = (u.hoveredTop >= 0 && b.topLevel != u.hoveredTop) ? 1.0 : 0.0;
        return o;
    }

    fragment float4 blockFragment(BlockOut in [[stage_in]], constant Uniforms &u [[buffer(0)]]) {
        // Rounded rect, 4 pt corners in screen points, so the zoom does not scale them.
        float2 hs = in.size * 0.5;
        float r = min(4.0, min(hs.x, hs.y));
        float2 q = abs(in.local - hs) - (hs - r);
        float d = length(max(q, 0.0)) + min(max(q.x, q.y), 0.0) - r;
        float coverage = saturate(0.5 - d * u.pixelsPerPoint);
        if (coverage <= 0.0) { discard_fragment(); }

        float3 rgb = in.color.rgb;
        float a = in.color.a;

        // Growth strip: a 1 pt line, then 1 pt at 0.34 and 2 pt at 0.16, repeating every 3 pt.
        if (in.stripe > 0.0) {
            float dx = in.local.x - in.size.x * (1.0 - in.stripe);
            if (dx >= 0.0) {
                float w = dx < 1.0 ? 0.7 : (fmod(dx - 1.0, 3.0) < 1.0 ? 0.34 : 0.16);
                rgb = mix(rgb, float3(1.0), w);
                a = mix(a, 1.0, w);
            }
        }

        // White inner outline; in light mode a 1 pt dark ring just inside it.
        if (in.outline > 0.0) {
            float o = saturate((d + in.outline) * u.pixelsPerPoint + 0.5);
            float ring = (saturate((d + in.outline + 1.0) * u.pixelsPerPoint + 0.5) - o) * u.outlineRing;
            rgb = mix(rgb, float3(0.086, 0.086, 0.114), ring * 0.85);
            rgb = mix(rgb, float3(1.0), o);
            a = mix(a, 1.0, max(o, ring));
        }

        if (in.dim > 0.0) { rgb = dimmed(rgb); }

        a *= coverage;
        return float4(rgb * a, a);
    }

    struct LabelOut {
        float4 position [[position]];
        float2 uv;
        float dim [[flat]];
    };

    vertex LabelOut labelVertex(uint vid [[vertex_id]], uint iid [[instance_id]],
                                const device LabelQuad *quads [[buffer(0)]],
                                constant Uniforms &u [[buffer(1)]]) {
        LabelQuad l = quads[iid];
        float2 corner = cornerOf(vid);
        // Snap to the pixel grid so the atlas maps one to one.
        float2 origin = round((l.rect.xy * u.scale + u.offset) * u.pixelsPerPoint) / u.pixelsPerPoint;
        LabelOut o;
        o.position = toClip(origin + corner * l.rect.zw, u);
        o.uv = mix(l.uv.xy, l.uv.zw, corner);
        o.dim = (u.hoveredTop >= 0 && l.topLevel != u.hoveredTop) ? 1.0 : 0.0;
        return o;
    }

    fragment float4 labelFragment(LabelOut in [[stage_in]], texture2d<float> atlas [[texture(0)]],
                                  constant Uniforms &u [[buffer(0)]]) {
        constexpr sampler s(filter::nearest, address::clamp_to_edge);
        float4 c = atlas.sample(s, in.uv);
        // Premultiplied: the dim is linear in rgb, so it applies directly.
        if (in.dim > 0.0) { c.rgb = dimmed(c.rgb); }
        return c * u.labelAlpha;
    }
    """
}
