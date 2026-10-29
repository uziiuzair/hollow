// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics

/// A drag of one map block or side-list row toward the basket bar, tracked by the window itself (no pasteboard, so it can
/// never land in Finder or the Dock's Trash). It becomes a drag once the pointer is `threshold` points from where it went
/// down, and stays one; anything less is a click.
public struct BasketDrag: Equatable, Sendable {
    public static let threshold: CGFloat = 4

    /// The dragged map rect, in the snapshot shown when the press began.
    public var item: Int
    /// The pressed node's key. A drop resolves the item by this key in the snapshot shown then, so a rebuild during the
    /// drag can never put a different node in the basket.
    public var key: String?
    /// Where the pointer is now, in the window's coordinate space.
    public var location: CGPoint
    public private(set) var isActive = false
    private let origin: CGPoint

    public init(at origin: CGPoint, item: Int, key: String? = nil) {
        self.item = item
        self.key = key
        self.origin = origin
        self.location = origin
    }

    public mutating func move(to point: CGPoint) {
        location = point
        if !isActive, hypot(point.x - origin.x, point.y - origin.y) >= Self.threshold { isActive = true }
    }

    public func dropsOnBasket(_ frame: CGRect) -> Bool { isActive && frame.contains(location) }
}
