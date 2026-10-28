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
