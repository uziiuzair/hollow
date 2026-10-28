import Foundation

public struct ReviewRow: Equatable, Sendable {
    public var path: String
    public var name: String
    /// The parent folder, or "Drive root".
    public var location: String
    public var size: String
    public var explanation: String
    /// What to do instead, for an item another app manages (or one holding such an item). Such a row has no checkbox.
    public var instruction: String?
    public var isChecked: Bool
    public var isCheckable: Bool { instruction == nil }

    public init(path: String, name: String, location: String, size: String, explanation: String, instruction: String?, isChecked: Bool) {
        self.path = path
        self.name = name
        self.location = location
        self.size = size
        self.explanation = explanation
        self.instruction = instruction
        self.isChecked = isChecked
    }
}

/// The list the user checks before anything moves to the Trash.
public struct ReviewSheet: Equatable, Sendable {
    public var rows: [ReviewRow]
    public var selectedTotal: UInt64
    public var selectedLabel: String
    public var buttonTitle: String
    public var canTrash: Bool
    public var notice: String?

    public static let title = "Review before moving to Trash"
    public static let subtitle = "Nothing is deleted. Items go to the Trash, and you can put them back from there."
    static let notKnown = "Not a known item. Make sure you don't need it."
    static let managedFallback = "Manage it in the app it belongs to."

    public init(rows: [ReviewRow], selectedTotal: UInt64, selectedLabel: String, buttonTitle: String, canTrash: Bool, notice: String?) {
        self.rows = rows
        self.selectedTotal = selectedTotal
        self.selectedLabel = selectedLabel
        self.buttonTitle = buttonTitle
        self.canTrash = canTrash
        self.notice = notice
    }

    /// `protected` is the drive's app-managed hits: an item that is one, is inside one or holds one gets no checkbox.
    public static func make(items: [BasketItem], unchecked: Set<String>, protected: [LensHit], rules: LensRules = .bundled,
                            driveName: String, driveConnected: Bool) -> ReviewSheet {
        let rows = items.map { item -> ReviewRow in
            let instruction = refusal(for: item, protected: protected, rules: rules)
            let parent = item.path.split(separator: "/").dropLast().joined(separator: "/")
            return ReviewRow(path: item.path, name: item.name, location: parent.isEmpty ? "Drive root" : parent,
                             size: Format.gb(item.size), explanation: rule(for: item, rules: rules)?.explanation ?? notKnown,
                             instruction: instruction, isChecked: instruction == nil && !unchecked.contains(item.path))
        }
        let selected = trashable(items, unchecked: unchecked, protected: protected, rules: rules)
        let total = selected.reduce(0) { $0 + $1.size }
        let n = selected.count
        return ReviewSheet(rows: rows, selectedTotal: total, selectedLabel: Format.gb(total) + " selected",
                           buttonTitle: n == 0 ? "Move to Trash" : n == 1 ? "Move 1 item to Trash" : "Move \(n) items to Trash",
                           canTrash: n > 0 && driveConnected,
                           notice: driveConnected ? nil : "\(driveName) is disconnected. Plug it back in to move these items.")
    }

    /// The checked items that are not app-managed and hold nothing app-managed.
    public static func trashable(_ items: [BasketItem], unchecked: Set<String>, protected: [LensHit],
                                 rules: LensRules = .bundled) -> [BasketItem] {
        items.filter { !unchecked.contains($0.path) && refusal(for: $0, protected: protected, rules: rules) == nil }
    }

    /// By the item's rule ID; only an item without one is looked up by path, and then never by a rule for its contents.
    static func rule(for item: BasketItem, rules: LensRules) -> LensRule? {
        if let id = item.ruleID { return rules.rule(id: id) }
        return rules.rule(covering: item.path, includeParents: false)
    }

    /// The instruction shown instead of a checkbox, or nil when the item may be trashed.
    static func refusal(for item: BasketItem, protected: [LensHit], rules: LensRules) -> String? {
        let rule = rule(for: item, rules: rules)
        if item.safety == .appManaged || rule?.safety == .appManaged {
            return rule?.instruction ?? managedFallback
        }
        if let hit = item.managingHit(in: protected) {
            return rules.rule(id: hit.ruleID)?.instruction ?? managedFallback
        }
        if let hit = item.containedHit(in: protected) {
            let hitRule = rules.rule(id: hit.ruleID)
            return "Contains \(hitRule?.name ?? hit.name). " + (hitRule?.instruction ?? managedFallback)
        }
        return nil
    }
}
