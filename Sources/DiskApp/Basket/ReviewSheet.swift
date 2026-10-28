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

    static let structuralReason = "This is a system or account folder; remove things inside it instead."

    /// Why an item may not be trashed.
    enum Refusal: Equatable, Sendable {
        /// Another app manages it (it is, or is inside, an app-managed location). `Trasher` skips it silently.
        case managed(String)
        /// The drive root, or a system or account folder.
        case structural
        /// It holds, or may hold, an app-managed location. `Trasher` fails it.
        case holds(String)

        var instruction: String {
            switch self {
            case .managed(let s), .holds(let s): s
            case .structural: ReviewSheet.structuralReason
            }
        }
    }

    /// The one predicate both the review sheet and `Trasher` use. It needs no `protected` list to refuse app-managed
    /// locations: the rules' own patterns refuse them and every folder that could hold one.
    static func refusalKind(for item: BasketItem, protected: [LensHit], rules: LensRules) -> Refusal? {
        let rule = rule(for: item, rules: rules)
        if item.safety == .appManaged || rule?.safety == .appManaged {
            return .managed(rule?.instruction ?? managedFallback)
        }
        if let hit = item.managingHit(in: protected) {
            return .managed(rules.rule(id: hit.ruleID)?.instruction ?? managedFallback)
        }
        let scan = rules.appManagedScan(item.path)
        if case .inside(let r)? = scan { return .managed(r.instruction ?? managedFallback) }
        if StructuralFolders.contains(item.path) { return .structural }
        if let hit = item.containedHit(in: protected) {
            let hitRule = rules.rule(id: hit.ruleID)
            return .holds("Contains \(hitRule?.name ?? hit.name). " + (hitRule?.instruction ?? managedFallback))
        }
        if case .ancestor(let r)? = scan { return .holds("May contain \(r.name). " + (r.instruction ?? managedFallback)) }
        return nil
    }

    /// The instruction shown instead of a checkbox, or nil when the item may be trashed.
    static func refusal(for item: BasketItem, protected: [LensHit], rules: LensRules) -> String? {
        refusalKind(for: item, protected: protected, rules: rules)?.instruction
    }
}

/// Folders that are never trashed whole: the drive root, top-level system folders and each account's standard folders.
/// Relative to the drive root, compared case-insensitively.
enum StructuralFolders {
    static let patterns: [LensPattern] = [
        "Users/*", "Users/*/Library", "Users/*/.Trash",
        "Users/*/Desktop", "Users/*/Documents", "Users/*/Downloads", "Users/*/Movies", "Users/*/Music",
        "Users/*/Pictures", "Users/*/Public", "Users/*/Applications",
        "Users/*/Library/Mobile Documents", "Users/*/Library/CloudStorage",
        "Applications", "Library", "System", "Users", "Volumes", "private", "usr", "opt", "cores", "MobileSoftwareUpdate",
        ".Trashes", ".Spotlight-V100", ".fseventsd", ".DocumentRevisions-V100", ".TemporaryItems", "Backups.backupdb",
    ].map(LensPattern.init)

    static func contains(_ relativePath: String) -> Bool {
        relativePath.split(separator: "/").isEmpty || patterns.contains { $0.matches(relativePath) }
    }
}

extension LensRules {
    enum ManagedScan: Equatable {
        /// The path is, or is inside, a location this app-managed rule matches.
        case inside(LensRule)
        /// The path is a folder above a location this app-managed rule could match.
        case ancestor(LensRule)
    }

    /// Prefix-tests every app-managed rule's pattern against the path. Skip lists are ignored, on purpose.
    func appManagedScan(_ relativePath: String) -> ManagedScan? {
        let managed = rules.indices.filter { rules[$0].safety == .appManaged }
        var masks = managed.map { patterns[$0].start }
        for part in relativePath.lowercased().split(separator: "/") {
            for k in managed.indices where masks[k] != 0 {
                masks[k] = patterns[managed[k]].step(masks[k], String(part))
                if patterns[managed[k]].accepts(masks[k]) { return .inside(rules[managed[k]]) }
            }
        }
        return managed.indices.first { masks[$0] != 0 }.map { .ancestor(rules[managed[$0]]) }
    }
}
