// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DiskApp
import SwiftUI

/// Shown once at launch when macOS denies Full Disk Access. It explains and links to System Settings; it changes nothing itself.
@MainActor
final class AccessExplainer: NSWindowController, NSWindowDelegate {
    static let defaultsKey = "didExplainFullDiskAccess"

    /// True when the explainer is due: access is denied and it has not been shown before.
    static func isDue(status: FDAStatus, defaults: UserDefaults = .standard) -> Bool {
        status == .denied && !defaults.bool(forKey: defaultsKey)
    }

    var onClose: (() -> Void)?

    init() {
        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 420, height: 100),
                              styleMask: [.titled, .closable], backing: .buffered, defer: false)
        window.title = AppIdentity.name
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self
        let hosting = NSHostingController(rootView: AccessExplainerView(
            openSettings: { [weak self] in
                NSWorkspace.shared.open(FullDiskAccess.settingsURL)
                self?.close()
            },
            dismiss: { [weak self] in self?.close() }))
        hosting.sizingOptions = [.preferredContentSize]
        window.contentViewController = hosting
        window.setContentSize(hosting.view.fittingSize)
        window.center()
    }

    required init?(coder: NSCoder) { fatalError("not used") }

    func windowWillClose(_ notification: Notification) { onClose?() }
}

struct AccessExplainerView: View {
    let openSettings: () -> Void
    let dismiss: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 12) {
            Text("Let Hollow see the whole disk").font(.headline)
            Text("macOS keeps Mail, Messages, Safari and some app data private until you allow Full Disk Access. Without it, Hollow still works, but those folders show as \"Can't read\" and their space counts as Other.")
                .fixedSize(horizontal: false, vertical: true)
            Text("Open System Settings, turn on Hollow under Full Disk Access, then reopen the app.")
                .foregroundStyle(.secondary)
                .fixedSize(horizontal: false, vertical: true)
            HStack {
                Spacer()
                Button("Not Now", action: dismiss).keyboardShortcut(.cancelAction)
                Button("Open System Settings", action: openSettings).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 4)
        }
        .font(.system(size: 13))
        .padding(20)
        .frame(width: 420)
    }
}
