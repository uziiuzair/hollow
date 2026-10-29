// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import CoreGraphics
import Testing
@testable import DiskApp

@Test func sideListIsThirtyPercentClamped() {
    #expect(MapWindowLayout.listWidth(windowWidth: 1000) == 300)
    #expect(MapWindowLayout.listWidth(windowWidth: 760) == 240)
    #expect(MapWindowLayout.listWidth(windowWidth: 2000) == 360)
}

@Test func hoverCardSitsBelowRightAndFlipsInside() {
    let card = CGSize(width: 236, height: 100)
    let bounds = CGSize(width: 800, height: 500)
    #expect(MapWindowLayout.cardOrigin(pointer: CGPoint(x: 100, y: 50), card: card, in: bounds) == CGPoint(x: 114, y: 64))
    // Near the right and bottom edges it goes left of and above the pointer.
    #expect(MapWindowLayout.cardOrigin(pointer: CGPoint(x: 700, y: 450), card: card, in: bounds) == CGPoint(x: 450, y: 336))
    // Never outside the map, even when neither side fits.
    #expect(MapWindowLayout.cardOrigin(pointer: CGPoint(x: 120, y: 60), card: card, in: CGSize(width: 300, height: 140))
        == CGPoint(x: 0, y: 0))
}

@Test func longBreadcrumbsCollapseTheEarliest() {
    let crumbs = (1...6).map { Crumb(name: "c\($0)", path: (1...$0).map { "c\($0)" }.joined(separator: "/")) }
    let short = MapWindowLayout.crumbItems(Array(crumbs.prefix(4)))
    let all: [MapWindowLayout.CrumbItem] = crumbs.prefix(4).map { .crumb($0) }
    #expect(short == all)
    let long = MapWindowLayout.crumbItems(crumbs)
    let tail: [MapWindowLayout.CrumbItem] = crumbs.suffix(4).map { .crumb($0) }
    #expect(long == [.collapsed(Array(crumbs.prefix(2)))] + tail)
    #expect(MapWindowLayout.crumbItems([]).isEmpty)
}

@Test func eventFlagsDropFunctionAndKeypadBits() {
    // Arrow keys carry .function and .numericPad; they must still read as "no modifiers".
    #expect(KeyModifiers(eventFlags: [.function, .numericPad]) == [])
    #expect(KeyModifiers(eventFlags: [.capsLock]) == [])
    #expect(KeyModifiers(eventFlags: [.command, .function]) == .command)
    #expect(KeyModifiers(eventFlags: [.shift, .option, .control]) == [.shift, .option, .control])
    #expect(MapKey.command(keyCode: 126, modifiers: KeyModifiers(eventFlags: [.function, .numericPad]), searchFocused: false) == .selectPrevious)
}
