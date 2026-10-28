import Foundation

public enum MapAction: Equatable, Sendable {
    case revealInFinder, copyPath, zoomToParent, goTo(key: String)
}

public struct CommandItem: Equatable, Sendable {
    public var title: String
    public var shortcut: String?
    public var action: MapAction

    public init(title: String, shortcut: String?, action: MapAction) {
        self.title = title
        self.shortcut = shortcut
        self.action = action
    }
}

public enum MapCommands {
    /// The caller passes `hasSelection && !isBucket`: Reveal and Copy need a real file or folder.
    public static func items(query: String, hasSelection: Bool, canZoomOut: Bool,
                             children: [(name: String, key: String)]) -> [CommandItem] {
        var base: [CommandItem] = []
        if hasSelection {
            base.append(CommandItem(title: "Reveal in Finder", shortcut: nil, action: .revealInFinder))
            base.append(CommandItem(title: "Copy Path", shortcut: nil, action: .copyPath))
        }
        if canZoomOut { base.append(CommandItem(title: "Zoom to Parent", shortcut: "Esc", action: .zoomToParent)) }
        guard !query.isEmpty else { return base }

        var result = base.filter { contains($0.title, query) }
        let goTo = children.filter { contains($0.name, query) }.prefix(8)
        result += goTo.map { CommandItem(title: "Go to \($0.name)", shortcut: nil, action: .goTo(key: $0.key)) }
        return result
    }

    private static func contains(_ text: String, _ query: String) -> Bool {
        text.range(of: query, options: [.caseInsensitive, .diacriticInsensitive]) != nil
    }
}

public struct KeyModifiers: OptionSet, Sendable {
    public let rawValue: Int
    public init(rawValue: Int) { self.rawValue = rawValue }
    public static let command = KeyModifiers(rawValue: 1 << 0)
    public static let shift = KeyModifiers(rawValue: 1 << 1)
    public static let option = KeyModifiers(rawValue: 1 << 2)
    public static let control = KeyModifiers(rawValue: 1 << 3)
}

public enum MapKeyCommand: Equatable, Sendable {
    case zoomIn, zoomOut, quickLook, openCommands, selectPrevious, selectNext
    case closeSearch, runCommand, commandUp, commandDown
}

public enum MapKey {
    public static func command(keyCode: UInt16, modifiers: KeyModifiers, searchFocused: Bool) -> MapKeyCommand? {
        if searchFocused {
            guard modifiers.isEmpty else { return nil }
            switch keyCode {
            case 36: return .runCommand
            case 53: return .closeSearch
            case 126: return .commandUp
            case 125: return .commandDown
            default: return nil
            }
        }
        if keyCode == 40 { return modifiers == .command ? .openCommands : nil }
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 36: return .zoomIn
        case 53: return .zoomOut
        case 49: return .quickLook
        case 126: return .selectPrevious
        case 125: return .selectNext
        default: return nil
        }
    }
}
