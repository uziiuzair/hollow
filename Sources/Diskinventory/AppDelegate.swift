import AppKit
import DiskApp
import DiskEngine

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
    private var statusItem: NSStatusItem!
    private var timer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private let menu = NSMenu()

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quit = NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseUp, .rightMouseUp])
        }
        refresh()

        timer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
    }

    private func refresh() {
        guard let space = try? VolumeSpace.read(dataVolume), let button = statusItem.button else { return }
        let label = MenuBarLabel.make(space: space, showNumber: true)
        button.image = StatusIcon.image(fill: label.fillFraction, level: label.level)
        button.title = label.text.isEmpty ? "" : " " + label.text
    }

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        guard NSApp.currentEvent?.type == .rightMouseUp else { return }  // left click: dropdown comes later
        statusItem.menu = menu
        sender.performClick(nil)
        statusItem.menu = nil
    }
}
