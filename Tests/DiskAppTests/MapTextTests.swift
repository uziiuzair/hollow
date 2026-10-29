// SPDX-License-Identifier: GPL-3.0-or-later

import CoreGraphics
import Foundation
import Testing
@testable import DiskApp

@Test func hoverExplanationsComeFromTheRules() {
    let rules = LensRules.bundled
    #expect(rules.explanation(for: "Users/u/Library/Containers/com.docker.docker/Data/vms/0/data/Docker.raw")
        == "The virtual disk Docker runs on. It grows but never shrinks by itself. Reclaim space in Docker \u{203A} Settings \u{203A} Resources.")
    #expect(rules.explanation(for: "Users/u/Library/Developer/Xcode/DerivedData") == "Xcode build products. Safe to clear. Rebuilds itself.")
    #expect(rules.explanation(for: "Users/u/code/site/node_modules") == "Packages for a JavaScript project. Safe to clear. Reinstall them with npm install.")
    #expect(rules.explanation(for: "Users/u/Pictures/Photos Library.photoslibrary") == "Your Photos library. Shrink it from inside Photos, not here.")
    #expect(rules.explanation(for: "Users/u/Library/Caches") == "App caches. Safe to clear. Apps rebuild what they need.")
    #expect(rules.explanation(for: "Users/u/Library/Caches/Yarn/v6") == "Yarn's download cache. Safe to clear. Yarn fetches what it needs again.")
    #expect(rules.explanation(for: "Users/u/Downloads/Old.dmg") == nil)
    #expect(rules.explanation(for: "Users/u/Documents") == nil)
}

@Test func hoverCards() {
    let docker = MapNode(key: "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw", name: "Docker.raw", kind: .virtualMachines, growth: 8_100_000_000, isFolder: false)
    let card = HoverCard.make(node: docker, size: 92_000_000_000, period: 1)
    #expect(card.title == "Docker.raw" && card.detail == "92 GB" && card.change == "up 8.1 GB today" && card.changeIsGrowth)
    #expect(card.explanation?.hasPrefix("The virtual disk Docker runs on.") == true)
    let trash = MapNode(key: "Users/u/.Trash", name: ".Trash", kind: .other, growth: -600_000_000, isFolder: true)
    #expect(HoverCard.make(node: trash, size: 2_000_000_000, period: 7).change == "down 0.6 GB this week")
    let quiet = MapNode(key: "a", name: "a", kind: .other, growth: 50_000_000, isFolder: true)
    #expect(HoverCard.make(node: quiet, size: 1_000_000_000, period: 7).change == nil)
    let small = MapNode(key: "Users/u#small", name: "Small files", kind: nil, growth: 0, isFolder: false)
    #expect(HoverCard.make(node: small, size: 1, period: 1).explanation == "Files under 1 MB and items too small to draw, shown as one block.")
    let more = MapNode(key: "Users/u#more", name: "More", kind: nil, growth: 0, isFolder: false)
    #expect(HoverCard.make(node: more, size: 1, period: 1).explanation == "Too many items to draw one by one here. Zoom in to see them.")
}

@Test func labelsTruncateAndDropLines() throws {
    let measure: (String, LabelStyle) -> CGFloat = { s, _ in CGFloat(s.count) * 7 }
    let p = try #require(LabelFit.plan(name: "Application Support", size: "27 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 100, height: 50), large: false, measure: measure))
    #expect(p.lines == [LabelLine(text: "Applicati\u{2026}", style: .name, origin: CGPoint(x: 12, y: 10)),
                        LabelLine(text: "27 GB", style: .size, origin: CGPoint(x: 12, y: 27))])
    #expect(LabelFit.plan(name: "Mail", size: "14 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 200, height: 40), large: false, measure: measure)?.lines.map(\.text) == ["Mail"])
    #expect(LabelFit.plan(name: "Mail", size: "14 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 30, height: 50), large: false, measure: measure) == nil)
    #expect(LabelFit.plan(name: "Docker", size: "92 GB", growth: "+8.1 GB today", frame: CGRect(x: 0, y: 0, width: 300, height: 120), large: true, measure: measure)?
        .lines.map(\.style) == [.nameLarge, .sizeLarge, .growth])
    #expect(LabelFit.plan(name: "Docker", size: "92 GB", growth: "+8.1 GB today", frame: CGRect(x: 0, y: 0, width: 300, height: 60), large: false, measure: measure)?
        .lines.map(\.style) == [.name, .size])
    #expect(LabelFit.plan(name: "Docker", size: "92 GB", growth: "+8.1 GB today", frame: CGRect(x: 0, y: 0, width: 300, height: 120), large: false, measure: measure)?
        .lines.last?.origin == CGPoint(x: 12, y: 46))
    // Not even one character fits.
    #expect(LabelFit.plan(name: "Docker", size: "92 GB", growth: nil, frame: CGRect(x: 0, y: 0, width: 40, height: 50), large: false, measure: { _, _ in 100 }) == nil)
}

@Test func commandsFilterAndGoTo() {
    #expect(MapCommands.items(query: "", hasSelection: true, canZoomOut: true, children: []).map(\.title) == ["Reveal in Finder", "Copy Path", "Zoom to Parent"])
    #expect(MapCommands.items(query: "", hasSelection: false, canZoomOut: false, children: []).isEmpty)
    #expect(MapCommands.items(query: "doc", hasSelection: true, canZoomOut: true, children: [("Docker", "Users/u/Docker"), ("Mail", "Users/u/Mail")])
        == [CommandItem(title: "Go to Docker", shortcut: nil, action: .goTo(key: "Users/u/Docker"))])
    #expect(MapCommands.items(query: "PATH", hasSelection: true, canZoomOut: false, children: []).map(\.action) == [.copyPath])
    #expect(MapCommands.items(query: "", hasSelection: false, canZoomOut: true, children: []).first?.shortcut == "Esc")
    #expect(MapCommands.items(query: "cafe", hasSelection: false, canZoomOut: false, children: [("Caf\u{00E9}", "c")]).map(\.title) == ["Go to Caf\u{00E9}"])
    let many = (0..<12).map { ("item\($0)", "k\($0)") }
    #expect(MapCommands.items(query: "item", hasSelection: false, canZoomOut: false, children: many).count == 8)
}

@Test func keys() {
    #expect(MapKey.command(keyCode: 36, modifiers: [], searchFocused: false) == .zoomIn)
    #expect(MapKey.command(keyCode: 53, modifiers: [], searchFocused: false) == .zoomOut)
    #expect(MapKey.command(keyCode: 49, modifiers: [], searchFocused: false) == .quickLook)
    #expect(MapKey.command(keyCode: 40, characters: "k", modifiers: .command, searchFocused: false) == .openCommands)
    #expect(MapKey.command(keyCode: 126, modifiers: [], searchFocused: false) == .selectPrevious)
    #expect(MapKey.command(keyCode: 125, modifiers: [], searchFocused: false) == .selectNext)
    #expect(MapKey.command(keyCode: 53, modifiers: [], searchFocused: true) == .closeSearch)
    #expect(MapKey.command(keyCode: 36, modifiers: [], searchFocused: true) == .runCommand)
    #expect(MapKey.command(keyCode: 126, modifiers: [], searchFocused: true) == .commandUp)
    #expect(MapKey.command(keyCode: 125, modifiers: [], searchFocused: true) == .commandDown)
    #expect(MapKey.command(keyCode: 49, modifiers: [], searchFocused: true) == nil)
    #expect(MapKey.command(keyCode: 40, modifiers: [], searchFocused: false) == nil)
}

// ⌘K follows the character, not the key's position: on Dvorak "k" is the QWERTY "v" key (9),
// and the QWERTY "k" key (40) types "t".
@Test func commandKFollowsTheLayout() {
    #expect(MapKey.command(keyCode: 9, characters: "k", modifiers: .command, searchFocused: false) == .openCommands)
    #expect(MapKey.command(keyCode: 40, characters: "t", modifiers: .command, searchFocused: false) == nil)
    #expect(MapKey.command(keyCode: 40, characters: "K", modifiers: .command, searchFocused: false) == .openCommands)
    #expect(MapKey.command(keyCode: 40, characters: "k", modifiers: [.command, .shift], searchFocused: false) == nil)
    #expect(MapKey.command(keyCode: 40, characters: "k", modifiers: [], searchFocused: false) == nil)
}

@Test func deleteAddsToBasketUnlessTyping() {
    #expect(MapKey.command(keyCode: 51, modifiers: [], searchFocused: false) == .addToBasket)
    #expect(MapKey.command(keyCode: 51, modifiers: [], searchFocused: true) == nil)
    #expect(MapKey.command(keyCode: 51, modifiers: .command, searchFocused: false) == nil)
}

@Test func commandBarOffersAddToBasket() {
    let add = CommandItem(title: "Add to Basket", shortcut: "⌫", action: .addToBasket)
    #expect(MapCommands.items(query: "", hasSelection: true, canZoomOut: false, children: [], canAddToBasket: true).first == add)
    #expect(MapCommands.items(query: "bask", hasSelection: true, canZoomOut: false, children: [], canAddToBasket: true) == [add])
    #expect(!MapCommands.items(query: "", hasSelection: true, canZoomOut: false, children: []).contains(add))
}
