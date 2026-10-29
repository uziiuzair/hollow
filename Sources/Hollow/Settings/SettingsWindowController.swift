// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DiskApp
import SwiftUI

/// The Settings window: fixed width, never resizable. One instance lives as long as the app.
@MainActor
final class SettingsWindowController: NSWindowController, NSWindowDelegate {
    var onClose: (() -> Void)?
    private let store: SettingsStore

    init(store: SettingsStore, drives: SettingsDrives, setTint: @escaping (String, Int) -> Void) {
        self.store = store
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 460, height: 400),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = "Settings"
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let view = SettingsView(store: store, drives: drives, setTint: setTint, addFolders: { [weak self] in self?.chooseFolders() })
        let hosting = NSHostingController(rootView: view)
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        if !window.setFrameUsingName("Settings") { window.center() }
        window.setFrameAutosaveName("Settings")
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not used") }

    private func chooseFolders() {
        let panel = NSOpenPanel()
        panel.canChooseDirectories = true
        panel.canChooseFiles = false
        panel.allowsMultipleSelection = true
        panel.prompt = "Skip"
        panel.message = "Choose folders to leave out of the map."
        let apply: (NSApplication.ModalResponse) -> Void = { [weak self] response in
            guard response == .OK, let self else { return }
            let chosen = panel.urls.map { $0.resolvingSymlinksInPath().path(percentEncoded: false) }
            self.store.settings.excludedFolders += chosen
        }
        if let window { panel.beginSheetModal(for: window, completionHandler: apply) } else { panel.begin(completionHandler: apply) }
    }

    func windowWillClose(_ notification: Notification) {
        onClose?()
    }
}
