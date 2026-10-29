import Testing
@testable import DiskApp

@Test func mainMenuHasAppEditAndWindowMenus() {
    let menus = MainMenuSpec.menus(appName: "Hollow")
    #expect(menus.map(\.title) == ["Hollow", "Edit", "Window"])
    func item(_ menu: Int, _ title: String) -> MainMenuSpec.Item? {
        menus[menu].items.first { if case .item(let i) = $0 { i.title == title } else { false } }
            .flatMap { if case .item(let i) = $0 { i } else { nil } }
    }
    #expect(item(0, "Quit Hollow") == .init(title: "Quit Hollow", key: "q", selector: "terminate:"))
    #expect(item(0, "Settings…") == .init(title: "Settings…", key: ",", selector: "openSettings:"))
    #expect(item(0, "Hide Hollow")?.selector == "hide:")
    #expect(item(0, "Hide Others") == .init(title: "Hide Others", key: "h", modifiers: [.command, .option], selector: "hideOtherApplications:"))
    #expect(item(1, "Undo")?.selector == "undo:")
    #expect(item(1, "Redo") == .init(title: "Redo", key: "z", modifiers: [.command, .shift], selector: "redo:"))
    for (t, k, s) in [("Cut", "x", "cut:"), ("Copy", "c", "copy:"), ("Paste", "v", "paste:"), ("Select All", "a", "selectAll:")] {
        #expect(item(1, t) == .init(title: t, key: k, selector: s))
    }
    #expect(item(2, "Minimize") == .init(title: "Minimize", key: "m", selector: "performMiniaturize:"))
    #expect(item(2, "Zoom")?.selector == "performZoom:")
    #expect(item(2, "Close") == .init(title: "Close", key: "w", selector: "performClose:"))
    #expect(menus[2].isWindowsMenu && !menus[0].isWindowsMenu)
}
