import CoreGraphics

/// A drag of one map block or side-list row toward the basket bar, tracked by the window itself (no pasteboard, so it can
/// never land in Finder or the Dock's Trash). It becomes a drag once the pointer is `threshold` points from where it went
/// down, and stays one; anything less is a click.
public struct BasketDrag: Equatable, Sendable {
    public static let threshold: CGFloat = 4

    /// The dragged map rect.
    public var item: Int
    /// Where the pointer is now, in the window's coordinate space.
    public var location: CGPoint
    public private(set) var isActive = false
    private let origin: CGPoint

    public init(at origin: CGPoint, item: Int) {
        self.item = item
        self.origin = origin
        self.location = origin
    }

    public mutating func move(to point: CGPoint) {
        location = point
        if !isActive, hypot(point.x - origin.x, point.y - origin.y) >= Self.threshold { isActive = true }
    }

    public func dropsOnBasket(_ frame: CGRect) -> Bool { isActive && frame.contains(location) }
}
