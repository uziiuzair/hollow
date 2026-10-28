import AppKit
import Combine
import DiskApp
import DiskEngine
import ServiceManagement

@MainActor
final class AppDelegate: NSObject, NSApplicationDelegate {
    private let dataVolume = URL(fileURLWithPath: "/System/Volumes/Data")
    private var statusItem: NSStatusItem!
    private var labelTimer: Timer?
    private var historyTimer: Timer?
    private var clockTimer: Timer?
    private var wakeObserver: NSObjectProtocol?
    private var mountObservers: [NSObjectProtocol] = []
    private let menu = NSMenu()

    private var storeBase: URL!
    private var registry: DriveRegistry!
    /// One controller per mounted volume UUID; never reused after `willUnmount()`.
    private var controllers: [String: DriveController] = [:]
    private var connectedSince: [String: Date] = [:]
    private var unmounts: [String: Task<Void, Never>] = [:]
    /// When each unmount in `unmounts` finished; a drive still mounted well after that
    /// had its unmount refused.
    private var unmountFinished: [String: Date] = [:]
    /// Drives the app is ejecting right now (between close and the system's answer).
    private var ejecting: Set<String> = []
    private var internalUUID: String?
    private var selected = ""
    private var observing: AnyCancellable?
    private weak var observedController: DriveController?

    private var state = DropdownState(model: DropdownModel.make(
        drives: [], selected: "", connected: [], summary: nil, space: nil, activity: .idle,
        period: 7, connectedSince: nil, now: .now))
    private var panel: DropdownPanel?
    private var lastDismiss = Date.distantPast
    private var clickMonitor: Any?

    func applicationDidFinishLaunching(_ notification: Notification) {
        let quit = NSMenuItem(title: "Quit \(AppIdentity.name)", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        quit.target = NSApp
        menu.addItem(quit)

        statusItem = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
        if let button = statusItem.button {
            button.imagePosition = .imageLeft
            button.target = self
            button.action = #selector(statusItemClicked(_:))
            button.sendAction(on: [.leftMouseDown, .rightMouseUp])
        }
        refresh()

        do {
            storeBase = try AppIdentity.storeBase()
            registry = DriveRegistry(file: storeBase.appending(path: "drives.json"))
            syncVolumes()
        } catch {
            NSLog("Diskinventory: cannot open store: \(error)")
        }

        labelTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        // The only timer that touches a controller: it records history, it never keeps a drive warm.
        historyTimer = Timer.scheduledTimer(withTimeInterval: 3600, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.recordHistory() }
        }
        wakeObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.didWakeNotification, object: nil, queue: .main
        ) { [weak self] _ in
            MainActor.assumeIsolated { self?.refresh() }
        }
        observeMounts()

        if LoginItem.shouldRegister(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory()) {
            do {
                try LoginItem.registerOnFirstRun(defaults: .standard) { try SMAppService.mainApp.register() }
            } catch {
                // Ad-hoc signed builds may be refused; launch at login is optional.
                NSLog("Diskinventory: could not register login item: \(error)")
            }
        }

        #if DEBUG
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in self?.showPanel(keepOpen: true) }
        }
        #endif
    }

    // MARK: Menu bar label

    /// Reads free space off the main thread, then updates the status item.
    private func refresh() {
        let volume = dataVolume
        Task { [weak self] in
            let read = await Task.detached(priority: .utility) { try? VolumeSpace.read(volume) }.value
            guard let self, let space = read, let button = self.statusItem.button else { return }
            let label = MenuBarLabel.make(space: space, showNumber: true)
            button.image = StatusIcon.image(fill: label.fillFraction, level: label.level)
            button.title = label.text.isEmpty ? "" : " " + label.text
        }
    }

    private func recordHistory() {
        guard let id = internalUUID, let controller = controllers[id] else { return }
        Task { await controller.recordDailyHistoryIfNeeded() }
    }

    // MARK: Mounts

    private func observeMounts() {
        let center = NSWorkspace.shared.notificationCenter
        mountObservers.append(center.addObserver(forName: NSWorkspace.didMountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.syncVolumes() }
        })
        mountObservers.append(center.addObserver(forName: NSWorkspace.willUnmountNotification, object: nil, queue: .main) { [weak self] note in
            let url = note.userInfo?[NSWorkspace.volumeURLUserInfoKey] as? URL
            MainActor.assumeIsolated { self?.volumeWillUnmount(url) }
        })
        mountObservers.append(center.addObserver(forName: NSWorkspace.didUnmountNotification, object: nil, queue: .main) { [weak self] _ in
            MainActor.assumeIsolated { self?.volumeDidUnmount() }
        })
    }

    /// Creates a controller for every mounted drive that has none, replaces one whose
    /// unmount was refused, and records drives in the registry. Runs on every panel open,
    /// so it reads no free space here and writes drives.json only when a drive is new,
    /// renamed or newly connected.
    private func syncVolumes() {
        guard registry != nil else { return }
        let now = Date()
        let volumes = VolumeCatalog.current().map { v in
            guard v.isInternalData, v.name.hasSuffix(" - Data") else { return v }
            return VolumeInfo(url: v.url, uuid: v.uuid, name: String(v.name.dropLast(7)),
                              isInternalData: true, device: v.device)
        }
        // A refused unmount (Finder: "disk in use") sends no didUnmount; the spent
        // controller would show the mounted drive as "Not connected" for good.
        for uuid in VolumeSync.spentControllersToReplace(
            mounted: Set(volumes.map(\.uuid)), unmountFinished: unmountFinished, ejecting: ejecting, now: now) {
            controllers[uuid] = nil
            unmounts[uuid] = nil
            unmountFinished[uuid] = nil
        }
        for v in volumes {
            var connected = false
            if controllers[v.uuid] == nil, let store = try? LiveIndex.storeDirectory(base: storeBase, volume: v.url) {
                controllers[v.uuid] = DriveController(volume: v, store: store)
                connectedSince[v.uuid] = now
                connected = true
            }
            if v.isInternalData { internalUUID = v.uuid }
            guard unmounts[v.uuid] == nil else { continue }
            if connected || registry.needsWrite(for: v) {
                _ = try? registry.upsert(v, space: controllers[v.uuid]?.space, now: now)
                if connected, let c = controllers[v.uuid] {
                    // Free space at connect time, read off the main thread.
                    Task { [weak self] in
                        await c.refreshSpace()
                        guard let self, self.controllers[v.uuid] === c, self.unmounts[v.uuid] == nil else { return }
                        _ = try? self.registry.upsert(v, space: c.space, now: .now)
                    }
                }
            } else {
                registry.markSeen(v.uuid, now: now)
            }
        }
        if selected.isEmpty || !registry.all().contains(where: { $0.uuid == selected }) {
            selected = internalUUID ?? registry.all().first?.uuid ?? ""
            observeSelected()
        }
        rebuild()
    }

    private func controller(for url: URL?) -> DriveController? {
        guard let path = url?.resolvingSymlinksInPath().path else { return nil }
        return controllers.values.first { $0.volume.url.resolvingSymlinksInPath().path == path }
    }

    @discardableResult
    private func beginUnmount(_ uuid: String) -> Task<Void, Never>? {
        if let task = unmounts[uuid] { return task }
        guard let c = controllers[uuid] else { return nil }
        _ = try? registry.upsert(c.volume, space: c.space, now: .now)
        let task = Task { [weak self] in
            await c.willUnmount()
            guard let self else { return }
            if self.unmounts[uuid] != nil { self.unmountFinished[uuid] = Date() }
            self.rebuild()
        }
        unmounts[uuid] = task
        rebuild()
        return task
    }

    private func volumeWillUnmount(_ url: URL?) {
        guard let c = controller(for: url), !c.volume.isInternalData else { return }
        beginUnmount(c.volume.uuid)
    }

    private func volumeDidUnmount() {
        let present = Set(VolumeCatalog.current().map(\.uuid))
        let gone = controllers.keys.filter { !present.contains($0) && $0 != internalUUID }
        Task { [weak self] in
            guard let self else { return }
            for uuid in gone {
                await self.beginUnmount(uuid)?.value
                self.controllers[uuid] = nil
                self.unmounts[uuid] = nil
                self.unmountFinished[uuid] = nil
                self.connectedSince[uuid] = nil
            }
            self.syncVolumes()
        }
    }

    private func ejectSelected() {
        let uuid = selected
        guard let c = controllers[uuid], !c.volume.isInternalData, unmounts[uuid] == nil else { return }
        let url = c.volume.url
        let name = c.volume.name
        // Registered synchronously so a second click cannot start another eject.
        let unmount = beginUnmount(uuid)
        ejecting.insert(uuid)
        Task { [weak self] in
            await unmount?.value
            do {
                try await Task.detached { try NSWorkspace.shared.unmountAndEjectDevice(at: url) }.value
                self?.ejecting.remove(uuid)
            } catch {
                // Still mounted: this controller is spent, so start a fresh one.
                guard let self else { return }
                self.ejecting.remove(uuid)
                self.controllers[uuid] = nil
                self.unmounts[uuid] = nil
                self.unmountFinished[uuid] = nil
                self.syncVolumes()
                let alert = NSAlert()
                alert.messageText = "Could not eject \(name)"
                alert.informativeText = error.localizedDescription
                alert.runModal()
            }
        }
    }

    // MARK: Model

    private var liveController: DriveController? {
        unmounts[selected] == nil ? controllers[selected] : nil
    }

    private func observeSelected() {
        let c = liveController
        observedController = c
        observing = c?.objectWillChange.sink { [weak self] _ in
            Task { @MainActor in self?.rebuild() }
        }
    }

    private func rebuild() {
        guard registry != nil else { return }
        let connected = Set(controllers.keys.filter { unmounts[$0] == nil })
        let c = liveController
        if let c, c.space == nil { Task { await c.refreshSpace() } }
        let model = DropdownModel.make(
            drives: registry.all(), selected: selected, connected: connected, summary: c?.summary,
            space: c?.space, activity: c?.activity ?? .offline, period: c?.period ?? 7,
            connectedSince: connectedSince[selected], now: .now)
        if state.model != model { state.model = model }
        let period = c?.period ?? 7
        if state.period != period { state.period = period }
        // A new controller for the same UUID (remount, failed eject) needs a fresh subscription.
        if observedController !== c { observeSelected() }
    }

    private func selectDrive(_ uuid: String) {
        selected = uuid
        observeSelected()
        if let c = liveController {
            Task { await c.refreshSpace() }
            Task { await c.warm() }
        }
        rebuild()
    }

    private func setPeriod(_ days: Int) {
        liveController?.period = days
        rebuild()
    }

    // MARK: Panel

    @objc private func statusItemClicked(_ sender: NSStatusBarButton) {
        if NSApp.currentEvent?.type == .rightMouseUp {
            statusItem.menu = menu
            sender.performClick(nil)
            statusItem.menu = nil
            return
        }
        if panel?.isVisible == true {
            panel?.dismiss()
        } else if Date().timeIntervalSince(lastDismiss) > 0.25 {
            // Within a quarter second the same click just closed it by resigning key.
            showPanel(keepOpen: false)
        }
    }

    private func makePanel() -> DropdownPanel {
        let host = DropdownHost(
            state: state,
            select: { [weak self] in self?.selectDrive($0) },
            setPeriod: { [weak self] in self?.setPeriod($0) },
            eject: { [weak self] in self?.ejectSelected() })
        let p = DropdownPanel(rootView: host)
        p.onDismiss = { [weak self] in self?.panelDismissed() }
        return p
    }

    private func showPanel(keepOpen: Bool) {
        #if DEBUG
        let clock = ContinuousClock()
        let started = clock.now
        #endif
        syncVolumes()
        let p = panel ?? makePanel()
        panel = p
        p.closesOnResign = !keepOpen
        if let c = liveController {
            Task { await c.refreshSpace() }
            Task { await c.warm() }
        }
        rebuild()
        #if DEBUG
        let dataReady = clock.now - started
        #endif
        var anchor = statusItem.button?.window.flatMap { w in
            statusItem.button.map { w.convertToScreen($0.convert($0.bounds, to: nil)) }
        }
        // A status item that is not placed in the menu bar (crowded bar, Control Center owns it) reports a bogus frame.
        if let a = anchor, !NSScreen.screens.contains(where: { a.midY > $0.frame.maxY - 60 && a.midY <= $0.frame.maxY && a.midX > $0.frame.minX && a.midX < $0.frame.maxX }) {
            anchor = nil
        }
        p.show(below: anchor)
        if !keepOpen {
            clickMonitor = NSEvent.addGlobalMonitorForEvents(matching: [.leftMouseDown, .rightMouseDown]) { [weak self] _ in
                MainActor.assumeIsolated { self?.panel?.dismiss() }
            }
        }
        // Keeps "Updated 2 min ago" honest while open; never warms anything.
        clockTimer = Timer.scheduledTimer(withTimeInterval: 30, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.rebuild() }
        }
        #if DEBUG
        NSLog("Diskinventory panel window \(p.windowNumber) frame \(p.frame)")
        NSLog("Diskinventory showPanel main thread: sync+model \(dataReady), total \(clock.now - started)")
        #endif
    }

    private func panelDismissed() {
        lastDismiss = Date()
        clockTimer?.invalidate(); clockTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }
}
