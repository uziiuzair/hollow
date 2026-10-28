import Foundation
import Testing
import DiskEngine
@testable import DiskApp

@Test func commandBracketAndCommandUpGoUpAndCommandDownGoesIn() {
    #expect(MapKey.command(keyCode: 33, modifiers: .command, searchFocused: false) == .zoomOut)
    #expect(MapKey.command(keyCode: 126, modifiers: .command, searchFocused: false) == .zoomOut)
    #expect(MapKey.command(keyCode: 125, modifiers: .command, searchFocused: false) == .zoomIn)
    #expect(MapKey.command(keyCode: 126, modifiers: [], searchFocused: false) == .selectPrevious)
    #expect(MapKey.command(keyCode: 53, modifiers: [], searchFocused: false) == .zoomOut)
}

@Test func searchFieldKeepsItsKeysFromTheNavigationShortcuts() {
    #expect(MapKey.command(keyCode: 33, modifiers: .command, searchFocused: true) == nil)
    #expect(MapKey.command(keyCode: 126, modifiers: .command, searchFocused: true) == nil)
    #expect(MapKey.command(keyCode: 125, modifiers: .command, searchFocused: true) == nil)
}

@Test func onlyADoubleClickOnAFolderOpensIt() {
    #expect(MapClick.opensFolder(clickCount: 2, isFolder: true))
    #expect(!MapClick.opensFolder(clickCount: 1, isFolder: true))
    #expect(!MapClick.opensFolder(clickCount: 3, isFolder: true))
    #expect(!MapClick.opensFolder(clickCount: 2, isFolder: false))
}

private func node(folder: Bool, kind: ContentKind? = .documents) -> MapNode {
    MapNode(key: "a", name: "a", kind: kind, growth: 0, isFolder: folder)
}

@Test func aFolderGetsOpenAndAFileDoesNot() {
    let folder = MapContextMenu.items(for: node(folder: true), canBasket: true, moving: false)
    let file = MapContextMenu.items(for: node(folder: false), canBasket: true, moving: false)
    #expect(folder.map(\.action).contains(.open))
    #expect(!file.map(\.action).contains(.open))
    #expect(folder.map(\.title) == ["Open", "Show in Finder", "Copy Path", "", "Add to Basket", "Move to Trash\u{2026}"])
    #expect(file.map(\.title) == ["Show in Finder", "Copy Path", "", "Add to Basket", "Move to Trash\u{2026}"])
}

@Test func moveToTrashIsDisabledWhileMovingOrWhenTheBasketRefuses() {
    func trash(canBasket: Bool, moving: Bool) -> MapContextItem? {
        MapContextMenu.items(for: node(folder: false), canBasket: canBasket, moving: moving).first { $0.action == .moveToTrash }
    }
    #expect(trash(canBasket: true, moving: false)?.isEnabled == true)
    #expect(trash(canBasket: true, moving: true)?.isEnabled == false)
    #expect(trash(canBasket: false, moving: false)?.isEnabled == false)
    let add = MapContextMenu.items(for: node(folder: false), canBasket: false, moving: false).first { $0.action == .addToBasket }
    #expect(add?.isEnabled == false)
}

@Test func aBucketGetsNoMenu() {
    #expect(MapContextMenu.items(for: node(folder: false, kind: nil), canBasket: false, moving: false).isEmpty)
}

@Test func aMenuTargetFollowsItsKeyThroughARebuild() {
    let a = MapNode(key: "Users/u/a", name: "a", kind: .other, growth: 0, isFolder: true)
    let b = MapNode(key: "Users/u/b", name: "b", kind: .media, growth: 0, isFolder: false)
    let small = MapNode(key: "Users/u#small", name: "Small files", kind: nil, growth: 0, isFolder: false)
    #expect(level([a, b], sizes: [9, 5]).topLevelRect(forKey: "Users/u/a") == 0)
    // Rebuilt while the menu was open: a moved to rect 1, so the old index would now be b.
    #expect(level([b, a], sizes: [12, 9]).topLevelRect(forKey: "Users/u/a") == 1)
    // Gone from this level: nothing to act on.
    #expect(level([b, small], sizes: [12, 1]).topLevelRect(forKey: "Users/u/a") == nil)
}
