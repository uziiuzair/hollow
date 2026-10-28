import DiskEngine

public enum LabelLevel: Sendable { case normal, low, critical }

public struct MenuBarLabel: Equatable, Sendable {
    public let text: String
    public let level: LabelLevel
    public let fillFraction: Double

    public init(text: String, level: LabelLevel, fillFraction: Double) {
        self.text = text
        self.level = level
        self.fillFraction = fillFraction
    }

    /// Free space is `availableForImportantUsage`, the number Finder shows.
    public static func make(space: VolumeSpace, showNumber: Bool) -> MenuBarLabel {
        guard space.total > 0 else {
            return MenuBarLabel(text: showNumber ? Format.gb(0) : "", level: .normal, fillFraction: 0)
        }
        let free = min(space.availableForImportantUsage, space.total)
        let freeFraction = Double(free) / Double(space.total)
        let level: LabelLevel = freeFraction < 0.05 ? .critical : freeFraction < 0.15 ? .low : .normal
        return MenuBarLabel(
            text: showNumber ? Format.gb(free) : "",
            level: level,
            fillFraction: Double(space.total - free) / Double(space.total))
    }
}

/// What the status ring's fill stroke draws for a used fraction.
public enum RingFill: Equatable, Sendable {
    case none
    /// The whole circle.
    case full
    /// A clockwise arc from 12 o'clock (90 degrees, non-flipped) to `endAngle` degrees.
    case arc(endAngle: Double)

    public static func forFraction(_ fill: Double) -> RingFill {
        let fraction = min(max(fill, 0), 1)
        guard fraction > 0 else { return .none }
        // An arc from 90 to -270 degrees has zero length and draws nothing.
        guard fraction < 1 else { return .full }
        return .arc(endAngle: 90 - 360 * fraction)
    }
}
