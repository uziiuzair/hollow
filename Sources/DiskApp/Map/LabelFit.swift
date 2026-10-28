import CoreGraphics
import Foundation

public enum LabelStyle: Sendable { case name, nameLarge, size, sizeLarge, growth }

public struct LabelLine: Equatable, Sendable {
    public var text: String
    public var style: LabelStyle
    /// Relative to the frame's top left.
    public var origin: CGPoint

    public init(text: String, style: LabelStyle, origin: CGPoint) {
        self.text = text
        self.style = style
        self.origin = origin
    }
}

public struct LabelPlan: Equatable, Sendable {
    public var lines: [LabelLine]

    public init(lines: [LabelLine]) { self.lines = lines }
}

public enum LabelFit {
    static let paddingLeft: CGFloat = 12
    static let paddingTop: CGFloat = 10

    /// Fonts (for the renderer): name 13 pt semibold (large 17), size 12 pt regular at 80% opacity (large 13),
    /// growth 12 pt semibold. `large` means the frame's area is at least 20% of the map.
    public static func plan(name: String, size: String, growth: String?, frame: CGRect, large: Bool,
                            measure: (String, LabelStyle) -> CGFloat) -> LabelPlan? {
        guard frame.width >= 40, frame.height >= 30 else { return nil }
        let nameStyle: LabelStyle = large ? .nameLarge : .name
        let sizeStyle: LabelStyle = large ? .sizeLarge : .size
        let nameHeight: CGFloat = large ? 21 : 17
        let sizeHeight: CGFloat = large ? 16 : 15
        let room = frame.width - 2 * paddingLeft

        let text: String
        if measure(name, nameStyle) <= room {
            text = name
        } else {
            var prefix = Substring(name)
            while !prefix.isEmpty, measure(prefix + "\u{2026}", nameStyle) > room { prefix = prefix.dropLast() }
            guard !prefix.isEmpty else { return nil }
            text = prefix + "\u{2026}"
        }
        var lines = [LabelLine(text: text, style: nameStyle, origin: CGPoint(x: paddingLeft, y: paddingTop))]

        let sizeNeeds = paddingTop + nameHeight + sizeHeight + 4
        guard frame.height >= sizeNeeds else { return LabelPlan(lines: lines) }
        lines.append(LabelLine(text: size, style: sizeStyle, origin: CGPoint(x: paddingLeft, y: paddingTop + nameHeight)))

        if let growth, frame.height >= sizeNeeds + 20 {
            lines.append(LabelLine(text: growth, style: .growth,
                                   origin: CGPoint(x: paddingLeft, y: paddingTop + nameHeight + sizeHeight + 4)))
        }
        return LabelPlan(lines: lines)
    }
}
