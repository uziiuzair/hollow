import Foundation
import DiskEngine

public enum MenuBarStyle: String, Codable, Sendable { case ringAndNumber, iconOnly }

/// What the Settings window edits. Persisted as one JSON blob.
public struct AppSettings: Codable, Equatable, Sendable {
    public var menuBarStyle: MenuBarStyle = .ringAndNumber
    /// Amber below this many percent free.
    public var lowPercent = 15
    /// Red below this many percent free.
    public var criticalPercent = 5
    /// Absolute paths of folders the scan leaves out.
    public var excludedFolders: [String] = []

    public init() {}

    public init(menuBarStyle: MenuBarStyle = .ringAndNumber, lowPercent: Int = 15, criticalPercent: Int = 5,
                excludedFolders: [String] = []) {
        self.menuBarStyle = menuBarStyle
        self.lowPercent = lowPercent
        self.criticalPercent = criticalPercent
        self.excludedFolders = excludedFolders
    }

    public func normalized() -> AppSettings {
        var s = self
        s.lowPercent = min(max(lowPercent, 2), 50)
        s.criticalPercent = min(max(criticalPercent, 1), s.lowPercent - 1)
        s.excludedFolders = Array(Set(excludedFolders.compactMap { path in
            var p = path
            while p.count > 1, p.hasSuffix("/") { p.removeLast() }
            return p.isEmpty ? nil : p
        })).sorted()
        return s
    }

    static let internalRoot = "/System/Volumes/Data"

    /// The skipped folders as paths relative to `root`, in the form `DriveController.setExclusions` takes.
    /// The drive's own root is never excluded. On the internal Data volume a folder outside it
    /// (`/Users/...`, `/Library/...`) maps through the firmlink when it exists there.
    public func exclusions(under root: String,
                           exists: (String) -> Bool = { FileManager.default.fileExists(atPath: $0) }) -> Set<String> {
        var base = root
        while base.count > 1, base.hasSuffix("/") { base.removeLast() }
        let prefix = base == "/" ? "/" : base + "/"
        var out = Set<String>()
        for path in excludedFolders {
            if path.hasPrefix(prefix), path.count > prefix.count {
                out.insert(String(path.dropFirst(prefix.count)))
            } else if base == Self.internalRoot, path.hasPrefix("/"), !path.hasPrefix("/Volumes/"),
                      path != base, exists(base + path) {
                out.insert(String(path.dropFirst()))
            }
        }
        return ExclusionPaths.normalized(out)
    }

    public static func decode(_ data: Data?) -> AppSettings {
        data.flatMap { try? JSONDecoder().decode(AppSettings.self, from: $0) } ?? AppSettings()
    }

    public func encoded() -> Data {
        let enc = JSONEncoder()
        enc.outputFormatting = [.prettyPrinted, .sortedKeys]
        return (try? enc.encode(self)) ?? Data()
    }
}

/// Holds the settings and saves them (normalized) on every change.
@MainActor
public final class SettingsStore: ObservableObject {
    @Published public var settings: AppSettings {
        didSet {
            let n = settings.normalized()
            if n != settings { settings = n }
            write(n.encoded())
        }
    }
    private let write: (Data) -> Void

    public init(read: @escaping () -> Data?, write: @escaping (Data) -> Void) {
        self.write = write
        settings = AppSettings.decode(read()).normalized()
    }

    public convenience init(defaults: UserDefaults = .standard) {
        let key = "settings.v1"
        self.init(read: { defaults.data(forKey: key) }, write: { defaults.set($0, forKey: key) })
    }
}
