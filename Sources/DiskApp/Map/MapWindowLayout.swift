import AppKit
import CoreGraphics

/// The map window's geometry rules that don't need a window to check.
public enum MapWindowLayout {
    /// The side list takes 30% of the window, between 240 and 360 pt.
    public static func listWidth(windowWidth: CGFloat) -> CGFloat {
        min(max(windowWidth * 0.3, 240), 360)
    }

    /// The hover card's top-left: `offset` right of and below the pointer, flipped to the
    /// other side of the pointer on an axis where it would leave `bounds`, and kept inside.
    public static func cardOrigin(pointer: CGPoint, card: CGSize, in bounds: CGSize, offset: CGFloat = 14) -> CGPoint {
        func axis(_ p: CGFloat, _ length: CGFloat, _ limit: CGFloat) -> CGFloat {
            var v = p + offset
            if v + length > limit { v = p - offset - length }
            return max(0, min(v, limit - length))
        }
        return CGPoint(x: axis(pointer.x, card.width, bounds.width), y: axis(pointer.y, card.height, bounds.height))
    }

    public enum CrumbItem: Equatable, Sendable {
        case crumb(Crumb)
        /// The earliest crumbs, shown as a "…" menu.
        case collapsed([Crumb])
    }

    /// More than `visible` crumbs collapse the earliest into one "…" item.
    public static func crumbItems(_ crumbs: [Crumb], visible: Int = 4) -> [CrumbItem] {
        guard crumbs.count > visible else { return crumbs.map { .crumb($0) } }
        let cut = crumbs.count - visible
        return [.collapsed(Array(crumbs.prefix(cut)))] + crumbs.suffix(visible).map { .crumb($0) }
    }
}

extension KeyModifiers {
    /// Only ⌘ ⇧ ⌥ ⌃; the function-key, keypad and caps-lock bits that arrow keys carry are dropped.
    public init(eventFlags: NSEvent.ModifierFlags) {
        var m: KeyModifiers = []
        if eventFlags.contains(.command) { m.insert(.command) }
        if eventFlags.contains(.shift) { m.insert(.shift) }
        if eventFlags.contains(.option) { m.insert(.option) }
        if eventFlags.contains(.control) { m.insert(.control) }
        self = m
    }
}
