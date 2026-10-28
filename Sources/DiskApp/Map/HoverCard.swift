import Foundation

public struct HoverCard: Equatable, Sendable {
    public var title: String
    public var detail: String
    public var change: String?
    public var changeIsGrowth: Bool
    public var explanation: String?

    public init(title: String, detail: String, change: String?, changeIsGrowth: Bool, explanation: String?) {
        self.title = title
        self.detail = detail
        self.change = change
        self.changeIsGrowth = changeIsGrowth
        self.explanation = explanation
    }

    static let changeThreshold: Int64 = 100_000_000

    public static func make(node: MapNode, size: UInt64, period: Int, rules: LensRules = .bundled) -> HoverCard {
        var change: String?
        if node.growth.magnitude >= UInt64(changeThreshold) {
            let words = Format.periodWords(period)
            change = node.growth > 0 ? "up \(Format.gb(node.growth.magnitude)) \(words)"
                                     : "down \(Format.gb(node.growth.magnitude)) \(words)"
        }
        let explanation: String?
        if node.key.hasSuffix("#small") {
            explanation = "Files under 1 MB and items too small to draw, shown as one block."
        } else if node.key.hasSuffix("#more") {
            explanation = "Too many items to draw one by one here. Zoom in to see them."
        } else {
            explanation = rules.explanation(for: node.key)
        }
        return HoverCard(title: node.name, detail: Format.gb(size), change: change,
                         changeIsGrowth: node.growth > 0, explanation: explanation)
    }
}
