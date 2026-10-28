import Foundation

public enum LensSafety: String, Codable, Sendable, CaseIterable {
    case regenerates
    case review
    case appManaged = "app-managed"
}

public struct LensRule: Codable, Equatable, Sendable {
    public var id: String
    public var name: String
    public var pattern: String
    public var safety: LensSafety
    public var explanation: String
    public var instruction: String?
    /// A file rule: `pattern` names a folder, and the hits are its stored files whose lowercased name matches one of these globs.
    public var files: [String]?
    public var minAgeDays: Int?
    /// Patterns for folders this rule never looks inside (app bundles, global installs).
    public var skipUnder: [String]?

    public init(id: String, name: String, pattern: String, safety: LensSafety, explanation: String,
                instruction: String? = nil, files: [String]? = nil, minAgeDays: Int? = nil, skipUnder: [String]? = nil) {
        self.id = id
        self.name = name
        self.pattern = pattern
        self.safety = safety
        self.explanation = explanation
        self.instruction = instruction
        self.files = files
        self.minAgeDays = minAgeDays
        self.skipUnder = skipUnder
    }

    /// The explanation, then the instruction when there is one.
    public var hoverText: String { instruction.map { explanation + " " + $0 } ?? explanation }

    public var isFileRule: Bool { files != nil }
}

/// A path pattern over lowercased components, compiled to a small state machine. Bit `i` of a mask means
/// "the path so far matched the first `i` parts".
public struct LensPattern: Equatable, Sendable {
    enum Part: Equatable, Sendable {
        case literal(String), glob(String), one, anyDepth
    }

    static let maxParts = 63
    let parts: [Part]

    public init(_ pattern: String) {
        parts = pattern.lowercased().split(separator: "/").map { component -> Part in
            let s = String(component)
            if s == "**" { return .anyDepth }
            if s == "*" { return .one }
            if s.contains(where: { "*?[".contains($0) }) { return .glob(s) }
            return .literal(s)
        }
    }

    /// False when the pattern is empty or has more components than a mask holds.
    var isValid: Bool { !parts.isEmpty && parts.count <= Self.maxParts }

    public var literalCount: Int {
        parts.reduce(0) { if case .literal = $1 { return $0 + 1 } else { return $0 } }
    }

    private func closure(_ m: UInt64) -> UInt64 {
        var m = m
        for (i, p) in parts.enumerated() where p == .anyDepth && m & (1 << UInt64(i)) != 0 { m |= 1 << UInt64(i + 1) }
        return m
    }

    var start: UInt64 { closure(1) }

    func step(_ m: UInt64, _ name: String) -> UInt64 {
        var out: UInt64 = 0
        for (i, p) in parts.enumerated() where m & (1 << UInt64(i)) != 0 {
            let next: UInt64 = 1 << UInt64(i + 1)
            switch p {
            case .anyDepth: out |= 1 << UInt64(i)
            case .one: out |= next
            case .literal(let s): if s == name { out |= next }
            case .glob(let g): if fnmatch(g, name, 0) == 0 { out |= next }
            }
        }
        return closure(out)
    }

    func accepts(_ m: UInt64) -> Bool { m & (1 << UInt64(parts.count)) != 0 }

    public func matches(_ relativePath: String) -> Bool {
        var mask = start
        for part in relativePath.lowercased().split(separator: "/") {
            mask = step(mask, String(part))
            if mask == 0 { return false }
        }
        return accepts(mask)
    }
}

public struct LensRules: Sendable {
    public struct RulesError: Error, Equatable { public var message: String }

    public let rules: [LensRule]
    let patterns: [LensPattern]
    let skips: [[LensPattern]]
    /// Folders no rule ever looks inside (Time Machine backups). A path one of these accepts kills every mask for its subtree.
    let globalSkips: [LensPattern]

    /// Rules with an unusable pattern (empty, or over 63 components) are dropped, and so are unusable global skips.
    public init(rules: [LensRule], skipUnder: [String] = []) {
        let valid = rules.filter { Self.isValid($0) }
        self.rules = valid
        patterns = valid.map { LensPattern($0.pattern) }
        skips = valid.map { ($0.skipUnder ?? []).map(LensPattern.init) }
        globalSkips = skipUnder.map(LensPattern.init).filter(\.isValid)
    }

    /// Reads `{"version": 1, "skipUnder": [...], "rules": [...]}`; the file-level `skipUnder` is optional and applies to every rule.
    /// Throws on any other version, or on a rule or skip with an unusable pattern.
    public init(json: Data) throws {
        struct File: Decodable { var version: Int; var skipUnder: [String]?; var rules: [LensRule] }
        let file = try JSONDecoder().decode(File.self, from: json)
        guard file.version == 1 else { throw RulesError(message: "unsupported lenses.json version \(file.version)") }
        if let bad = file.rules.first(where: { !Self.isValid($0) }) {
            throw RulesError(message: "rule \(bad.id) has an unusable pattern")
        }
        if let bad = (file.skipUnder ?? []).first(where: { !LensPattern($0).isValid }) {
            throw RulesError(message: "skip \(bad) is an unusable pattern")
        }
        self.init(rules: file.rules, skipUnder: file.skipUnder ?? [])
    }

    private static func isValid(_ rule: LensRule) -> Bool {
        LensPattern(rule.pattern).isValid && (rule.skipUnder ?? []).allSatisfy { LensPattern($0).isValid }
    }

    /// The rules file inside the app's `Resources`. Debug builds (tests, `swift run`) fall back to the SwiftPM resource bundle;
    /// release builds never touch `Bundle.module`, whose accessor traps when its bundle is missing.
    public static let bundled: LensRules = {
        var url = Bundle.main.url(forResource: "lenses", withExtension: "json")
        #if DEBUG
        if url == nil { url = Bundle.module.url(forResource: "lenses", withExtension: "json") }
        #endif
        guard let url, let data = try? Data(contentsOf: url) else {
            NSLog("Diskinventory: lenses.json is missing; the junk lens is empty")
            return LensRules(rules: [])
        }
        do {
            return try LensRules(json: data)
        } catch {
            NSLog("Diskinventory: lenses.json is unreadable (\(error)); the junk lens is empty")
            return LensRules(rules: [])
        }
    }()

    public func rule(id: String) -> LensRule? { rules.first { $0.id == id } }

    /// The best of `candidates` (rule indices): most literal components, then listed first.
    func best<S: Sequence>(_ candidates: S) -> Int? where S.Element == Int {
        var winner: Int?
        for r in candidates {
            guard let w = winner else { winner = r; continue }
            if patterns[r].literalCount > patterns[w].literalCount || (patterns[r].literalCount == patterns[w].literalCount && r < w) {
                winner = r
            }
        }
        return winner
    }

    var folderRuleIndices: [Int] { rules.indices.filter { !rules[$0].isFileRule } }

    /// Masks for every rule's pattern, then every rule's skip patterns flattened in rule order, then the global skips.
    func startMasks() -> [UInt64] {
        patterns.map(\.start) + skips.flatMap { $0.map(\.start) } + globalSkips.map(\.start)
    }

    /// One component down. A rule whose skip pattern accepts the new path is dead for the whole subtree: its masks go to 0.
    /// A global skip that accepts the new path kills every mask.
    func step(_ masks: [UInt64], _ lowercasedName: String) -> [UInt64] {
        var next = [UInt64](repeating: 0, count: masks.count)
        let globalBase = masks.count - globalSkips.count
        for (k, skip) in globalSkips.enumerated() where masks[globalBase + k] != 0 {
            let s = skip.step(masks[globalBase + k], lowercasedName)
            if skip.accepts(s) { return [UInt64](repeating: 0, count: masks.count) }
            next[globalBase + k] = s
        }
        var skipBase = patterns.count
        for r in patterns.indices {
            defer { skipBase += skips[r].count }
            guard masks[r] != 0 else { continue }
            let m = patterns[r].step(masks[r], lowercasedName)
            guard m != 0 else { continue }
            var skipped = false
            for (k, skip) in skips[r].enumerated() {
                let s = masks[skipBase + k] == 0 ? 0 : skip.step(masks[skipBase + k], lowercasedName)
                if skip.accepts(s) { skipped = true }
                next[skipBase + k] = s
            }
            if skipped {
                for k in skips[r].indices { next[skipBase + k] = 0 }
            } else {
                next[r] = m
            }
        }
        return next
    }

    func isLive(_ masks: [UInt64]) -> Bool { masks.prefix(patterns.count).contains { $0 != 0 } }

    func accepting(_ masks: [UInt64], among indices: [Int]) -> [Int] {
        indices.filter { patterns[$0].accepts(masks[$0]) }
    }

    /// The folder rule that covers a path: the best rule at the first prefix some rule accepts. With `includeParents`, a path no
    /// prefix of which is accepted gets the best rule that would accept one more component, so a contents rule's parent is explained.
    public func rule(covering relativePath: String, includeParents: Bool = false) -> LensRule? {
        let folderRules = folderRuleIndices
        var masks = startMasks()
        for part in relativePath.lowercased().split(separator: "/") {
            masks = step(masks, String(part))
            if let r = best(accepting(masks, among: folderRules)) { return rules[r] }
            if !isLive(masks) { return nil }
        }
        guard includeParents else { return nil }
        let probe = step(masks, "\u{1}")
        return best(accepting(probe, among: folderRules)).map { rules[$0] }
    }

    public func explanation(for relativePath: String) -> String? {
        rule(covering: relativePath, includeParents: true)?.hoverText
    }
}

public struct LensHit: Equatable, Sendable {
    public var ruleID: String
    /// Relative to the drive root.
    public var path: String
    public var name: String
    public var size: UInt64
    public var isFolder: Bool
    public var safety: LensSafety

    public init(ruleID: String, path: String, name: String, size: UInt64, isFolder: Bool, safety: LensSafety) {
        self.ruleID = ruleID
        self.path = path
        self.name = name
        self.size = size
        self.isFolder = isFolder
        self.safety = safety
    }
}

public struct LensReport: Equatable, Sendable {
    /// Largest first.
    public var hits: [LensHit]
    public var generation: Int

    public init(hits: [LensHit], generation: Int) {
        self.hits = hits
        self.generation = generation
    }

    public func total(_ safety: LensSafety) -> UInt64 {
        hits.reduce(0) { $1.safety == safety ? $0 + $1.size : $0 }
    }
}
