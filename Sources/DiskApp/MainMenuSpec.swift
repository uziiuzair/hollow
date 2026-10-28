import Foundation

/// The app's main menu as data, so its shortcuts and actions can be tested. It matters only
/// while the map window makes the app a regular app; an accessory app shows no menu bar.
public enum MainMenuSpec {
    public struct Item: Equatable, Sendable {
        public var title: String
        public var key: String
        public var modifiers: KeyModifiers
        /// A standard AppKit action, sent to the first responder (or NSApp).
        public var selector: String

        public init(title: String, key: String, modifiers: KeyModifiers = .command, selector: String) {
            self.title = title
            self.key = key
            self.modifiers = modifiers
            self.selector = selector
        }
    }

    public enum Entry: Equatable, Sendable {
        case item(Item)
        case separator
    }

    public struct Menu: Equatable, Sendable {
        public var title: String
        public var items: [Entry]
        /// AppKit lists open windows in this menu.
        public var isWindowsMenu: Bool
    }

    public static func menus(appName: String) -> [Menu] {
        func i(_ title: String, _ key: String, _ selector: String, _ modifiers: KeyModifiers = .command) -> Entry {
            .item(Item(title: title, key: key, modifiers: modifiers, selector: selector))
        }
        return [
            Menu(title: appName, items: [
                i("About \(appName)", "", "orderFrontStandardAboutPanel:"),
                .separator,
                i("Settings\u{2026}", ",", "openSettings:"),
                .separator,
                i("Hide \(appName)", "h", "hide:"),
                i("Hide Others", "h", "hideOtherApplications:", [.command, .option]),
                i("Show All", "", "unhideAllApplications:"),
                .separator,
                // terminate: goes through applicationShouldTerminate, which cools the drives.
                i("Quit \(appName)", "q", "terminate:"),
            ], isWindowsMenu: false),
            Menu(title: "Edit", items: [
                i("Undo", "z", "undo:"),
                i("Redo", "z", "redo:", [.command, .shift]),
                .separator,
                i("Cut", "x", "cut:"),
                i("Copy", "c", "copy:"),
                i("Paste", "v", "paste:"),
                i("Select All", "a", "selectAll:"),
            ], isWindowsMenu: false),
            Menu(title: "Window", items: [
                i("Minimize", "m", "performMiniaturize:"),
                i("Zoom", "", "performZoom:"),
                .separator,
                i("Close", "w", "performClose:"),
                .separator,
                i("Bring All to Front", "", "arrangeInFront:"),
            ], isWindowsMenu: true),
        ]
    }
}
