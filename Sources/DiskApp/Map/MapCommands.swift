// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum MapAction: Equatable, Sendable {
    case addToBasket, revealInFinder, copyPath, zoomToParent, goTo(key: String)
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
    /// `canAddToBasket` is true when the selection can go in the basket (not the root, a bucket or something already in it).
    public static func items(query: String, hasSelection: Bool, canZoomOut: Bool,
                             children: [(name: String, key: String)], canAddToBasket: Bool = false) -> [CommandItem] {
        var base: [CommandItem] = []
        if canAddToBasket { base.append(CommandItem(title: "Add to Basket", shortcut: "⌫", action: .addToBasket)) }
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
    case zoomIn, zoomOut, quickLook, openCommands, selectPrevious, selectNext, addToBasket
    case closeSearch, runCommand, commandUp, commandDown
}

public enum MapKey {
    /// `keyCode` names the non-character keys (Return, Escape, Space, arrows); `characters` is the
    /// event's `charactersIgnoringModifiers`, which matches letters on any keyboard layout.
    public static func command(keyCode: UInt16, characters: String? = nil, modifiers: KeyModifiers,
                               searchFocused: Bool) -> MapKeyCommand? {
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
        // By character (the event's charactersIgnoringModifiers), so ⌘K works on any layout.
        if modifiers == .command {
            // Finder's: ⌘[ and ⌘↑ go to the enclosing folder, ⌘↓ opens.
            switch keyCode {
            case 33, 126: return .zoomOut
            case 125: return .zoomIn
            default: return characters?.lowercased() == "k" ? .openCommands : nil
            }
        }
        guard modifiers.isEmpty else { return nil }
        switch keyCode {
        case 36: return .zoomIn
        case 53: return .zoomOut
        case 49: return .quickLook
        case 51: return .addToBasket
        case 126: return .selectPrevious
        case 125: return .selectNext
        default: return nil
        }
    }
}

public enum MapClick {
    /// A double-click on a folder opens it; a triple-click doesn't open it again.
    public static func opensFolder(clickCount: Int, isFolder: Bool) -> Bool {
        clickCount == 2 && isFolder
    }
}

public enum MapContextAction: Equatable, Sendable {
    case open, showInFinder, copyPath, addToBasket, moveToTrash, separator
}

public struct MapContextItem: Equatable, Sendable {
    public var title: String
    public var action: MapContextAction
    public var isEnabled: Bool

    public init(title: String, action: MapContextAction, isEnabled: Bool = true) {
        self.title = title
        self.action = action
        self.isEnabled = isEnabled
    }
}

public enum MapContextMenu {
    /// The right-click menu for a block or list row. `canBasket` is true when the basket would accept it.
    /// Buckets get no menu. "Move to Trash…" only queues the item and opens the review sheet; it moves nothing itself.
    public static func items(for node: MapNode, canBasket: Bool, moving: Bool) -> [MapContextItem] {
        guard node.kind != nil else { return [] }
        var result: [MapContextItem] = []
        if node.isFolder { result.append(MapContextItem(title: "Open", action: .open)) }
        result.append(MapContextItem(title: "Show in Finder", action: .showInFinder))
        result.append(MapContextItem(title: "Copy Path", action: .copyPath))
        result.append(MapContextItem(title: "", action: .separator))
        result.append(MapContextItem(title: "Add to Basket", action: .addToBasket, isEnabled: canBasket))
        result.append(MapContextItem(title: "Move to Trash\u{2026}", action: .moveToTrash, isEnabled: canBasket && !moving))
        return result
    }
}
