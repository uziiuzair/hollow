// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// Geometry of the zoom transition. Drawing maps a point as `p * scale + offset`.
public struct ZoomAnimation: Equatable, Sendable {
    public static let duration = 0.2
    public var bounds: CGRect
    /// Where `bounds` is drawn at progress 0.
    public var start: CGRect

    public init(bounds: CGRect, start: CGRect) {
        self.bounds = bounds
        self.start = start
    }

    /// The new level grows out of the clicked block.
    public static func zoomIn(from block: CGRect, bounds: CGRect) -> ZoomAnimation {
        ZoomAnimation(bounds: bounds, start: block)
    }

    /// The old level shrinks into `child`: at progress 0 the rect that magnifies `child` to fill `bounds` is drawn.
    public static func zoomOut(to child: CGRect, bounds: CGRect) -> ZoomAnimation {
        let sx = bounds.width / child.width, sy = bounds.height / child.height
        let origin = CGPoint(x: bounds.minX + (bounds.minX - child.minX) * sx,
                             y: bounds.minY + (bounds.minY - child.minY) * sy)
        return ZoomAnimation(bounds: bounds, start: CGRect(x: origin.x, y: origin.y,
                                                           width: bounds.width * sx, height: bounds.height * sy))
    }

    public func transform(progress: Double) -> (scale: CGSize, offset: CGPoint) {
        let e = CGFloat(Self.eased(progress))
        let s0 = CGSize(width: start.width / bounds.width, height: start.height / bounds.height)
        let o0 = CGPoint(x: start.minX - bounds.minX * s0.width, y: start.minY - bounds.minY * s0.height)
        return (CGSize(width: s0.width + (1 - s0.width) * e, height: s0.height + (1 - s0.height) * e),
                CGPoint(x: o0.x * (1 - e), y: o0.y * (1 - e)))
    }

    public static func eased(_ t: Double) -> Double { 1 - pow(1 - t, 3) }
}
