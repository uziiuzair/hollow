import AppKit
import Combine
import DiskApp
import DiskEngine
import ServiceManagement
import os
import QuartzCore

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
    private var mapWindow: MapWindowController?
    /// Last saved summaries of drives that are not connected, read once per uuid and period.
    private var cachedSummaries: [String: [Int: DriveSummary?]] = [:]
    #if DEBUG
    private var debugSnapshotDir: URL?
    #endif
    private let mapLog = Logger(subsystem: AppIdentity.bundleID, category: "map")

    func applicationDidFinishLaunching(_ notification: Notification) {
        installMainMenu()
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

        if CommandLine.arguments.contains("--watchdog") {
            MainThreadWatchdog().start()
        }

        #if DEBUG
        // --close-map-after <s> / --reopen-map-after <s>: seconds after launch, for measuring
        // release on close and a cold reopen without clicking (the screen may be locked).
        for (flag, reopen) in [("--close-map-after", false), ("--reopen-map-after", true)] {
            guard let i = CommandLine.arguments.firstIndex(of: flag), i + 1 < CommandLine.arguments.count,
                  let seconds = Double(CommandLine.arguments[i + 1]) else { continue }
            DispatchQueue.main.asyncAfter(deadline: .now() + seconds) { [weak self] in
                guard let self else { return }
                if reopen, let id = self.internalUUID { self.openMap(uuid: id, focus: nil) }
                if !reopen { self.mapWindow?.close() }
            }
        }
        if CommandLine.arguments.contains("--show-panel") {
            DispatchQueue.main.async { [weak self] in self?.showPanel(keepOpen: true) }
        }
        if CommandLine.arguments.contains("--show-map"), let id = internalUUID {
            startHeartbeat()
            DispatchQueue.main.async { [weak self] in self?.openMap(uuid: id, focus: nil) }
        }
        // --map-snapshot <dir>: with --show-map, writes the window's PNGs once the map is drawn.
        if let i = CommandLine.arguments.firstIndex(of: "--map-snapshot"), i + 1 < CommandLine.arguments.count {
            debugSnapshotDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
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
        // The map window holds this controller; it can't outlive the mount.
        if mapWindow?.uuid == uuid { mapWindow?.close() }
        let task = Task { [weak self] in
            await c.willUnmount()
            guard let self else { return }
            // willUnmount saves the index; whatever was cached before is stale.
            self.cachedSummaries[uuid] = nil
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
                // An accessory app is not active; without this the alert opens behind other apps.
                NSApp.activate()
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
        let period = c?.period ?? offlinePeriod
        let summary = c?.summary ?? (connected.contains(selected) ? nil : cachedSummary(selected, period: period))
        let model = DropdownModel.make(
            drives: registry.all(), selected: selected, connected: connected, summary: summary,
            space: c?.space, activity: c?.activity ?? .offline, period: period,
            connectedSince: connectedSince[selected], now: .now)
        if state.model != model { state.model = model }
        if state.period != period { state.period = period }
        // A new controller for the same UUID (remount, failed eject) needs a fresh subscription.
        if observedController !== c { observeSelected() }
    }

    /// Offline drives have no controller to hold the period, so the panel keeps it.
    private var offlinePeriod = 7

    private func cachedSummary(_ uuid: String, period: Int) -> DriveSummary? {
        if let hit = cachedSummaries[uuid]?[period] { return hit }
        let loaded = DriveSummary.load(from: LiveIndex.storeDirectory(base: storeBase, uuid: uuid), period: period)
        cachedSummaries[uuid, default: [:]][period] = .some(loaded)
        return loaded
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
        guard let c = liveController else { offlinePeriod = days; rebuild(); return }
        offlinePeriod = days
        c.period = days
        // Reopens the index if the panel stayed open past the cool-down, so the new
        // period is not shown from a stale cache.
        Task { await c.warm() }
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
            eject: { [weak self] in self?.ejectSelected() },
            openMap: { [weak self] focus in
                guard let self else { return }
                self.panel?.dismiss()
                self.openMap(uuid: self.selected, focus: focus)
            })
        let p = DropdownPanel(rootView: host)
        p.onDismiss = { [weak self] in self?.panelDismissed() }
        return p
    }

    private func showPanel(keepOpen: Bool) {
        // hidesOnDeactivate hides the panel without onDismiss; drop what the last showing
        // left behind so timers and monitors never stack.
        clearPanelTimers()
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
        clearPanelTimers()
    }

    private func clearPanelTimers() {
        clockTimer?.invalidate(); clockTimer = nil
        if let m = clickMonitor { NSEvent.removeMonitor(m); clickMonitor = nil }
    }

    #if DEBUG
    private var heartbeat: Timer?
    private var heartbeatActivity: NSObjectProtocol?

    /// A 100 ms main-thread timer that logs every gap over 50 ms past its due time, with the
    /// longest so far. App Nap is held off so a hidden or locked screen doesn't stretch it.
    private func startHeartbeat() {
        heartbeatActivity = ProcessInfo.processInfo.beginActivity(
            options: [.userInitiated, .latencyCritical], reason: "main-thread heartbeat")
        heartbeatLast = CACurrentMediaTime()
        let timer = Timer(timeInterval: 0.1, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.beat() }
        }
        timer.tolerance = 0
        RunLoop.main.add(timer, forMode: .common)
        heartbeat = timer
        DispatchQueue.main.asyncAfter(deadline: .now() + 40) { [weak self] in
            guard let self else { return }
            self.mapLog.info("heartbeat done: longest main-thread gap \(Int(self.heartbeatLongest)) ms")
        }
    }

    private var heartbeatLast = 0.0
    private var heartbeatLongest = 0.0

    private func beat() {
        let now = CACurrentMediaTime()
        let late = (now - heartbeatLast - 0.1) * 1000
        heartbeatLast = now
        heartbeatLongest = max(heartbeatLongest, late)
        if late > 16 { mapLog.info("main thread late \(Int(late)) ms (longest \(Int(self.heartbeatLongest)) ms)") }
    }
    #endif

    // MARK: Main menu

    /// Shown only while the map window makes the app regular; gives the window ⌘W, ⌘M, ⌘Q,
    /// the search field's Edit shortcuts and a Window menu.
    private func installMainMenu() {
        let bar = NSMenu()
        for spec in MainMenuSpec.menus(appName: AppIdentity.name) {
            let menu = NSMenu(title: spec.title)
            for entry in spec.items {
                switch entry {
                case .separator:
                    menu.addItem(.separator())
                case .item(let i):
                    let item = NSMenuItem(title: i.title, action: NSSelectorFromString(i.selector), keyEquivalent: i.key)
                    var mask: NSEvent.ModifierFlags = []
                    if i.modifiers.contains(.command) { mask.insert(.command) }
                    if i.modifiers.contains(.shift) { mask.insert(.shift) }
                    if i.modifiers.contains(.option) { mask.insert(.option) }
                    if i.modifiers.contains(.control) { mask.insert(.control) }
                    item.keyEquivalentModifierMask = mask
                    menu.addItem(item)
                }
            }
            let top = NSMenuItem(title: spec.title, action: nil, keyEquivalent: "")
            top.submenu = menu
            bar.addItem(top)
            if spec.isWindowsMenu { NSApp.windowsMenu = menu }
        }
        NSApp.mainMenu = bar
    }

    // MARK: Map window

    /// Opens the map for drive `uuid`: at the root when `focus` is nil or empty, else at
    /// `focus`'s parent with `focus` selected. One map window at a time.
    func openMap(uuid: String, focus: String?) {
        let clock = ContinuousClock()
        let started = clock.now
        guard let controller = controllers[uuid], unmounts[uuid] == nil,
              let drive = registry?.all().first(where: { $0.uuid == uuid }) else { return }
        var path = "", select: String?
        if let focus, !focus.isEmpty {
            path = focus.lastIndex(of: "/").map { String(focus[..<$0]) } ?? ""
            select = focus
        }
        if let window = mapWindow, window.uuid == uuid, window.driveController === controller {
            window.show(path: path, select: select)
        } else {
            if let old = mapWindow {
                mapWindow = nil
                old.close()
            }
            let window = MapWindowController(controller: controller, drive: drive, path: path, select: select)
            window.onClose = { [weak self, weak window] in
                guard let self, self.mapWindow === window else { return }
                self.mapWindow = nil
                // The Dock icon shows only while the window is open (spec 5).
                NSApp.setActivationPolicy(.accessory)
            }
            window.onFirstFrame = { [weak self] in
                let ms = (clock.now - started) / .milliseconds(1)
                self?.mapLog.info("first map frame in \(Int(ms)) ms")
                #if DEBUG
                if let dir = self?.debugSnapshotDir, let window = self?.mapWindow {
                    Task { await window.debugCapture(to: dir) }
                }
                #endif
            }
            mapWindow = window
        }
        NSApp.setActivationPolicy(.regular)
        NSApp.activate()
        mapWindow?.showWindow(nil)
        mapWindow?.window?.makeKeyAndOrderFront(nil)
        let ms = (clock.now - started) / .milliseconds(1)
        mapLog.info("map window shown in \(Int(ms)) ms")
        #if DEBUG
        if let w = mapWindow?.window { NSLog("Diskinventory map window \(w.windowNumber) frame \(w.frame)") }
        #endif
    }

    // MARK: Quit

    private var terminating = false
    private var terminationReplied = false

    /// Spec 6.4 records history at app quit: cool every controller so each open index
    /// records today's snapshot and saves, waiting at most 3 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        let all = Array(controllers.values)
        Task { [weak self] in
            await withTaskGroup(of: Void.self) { group in
                for c in all { group.addTask { await c.cool() } }
            }
            self?.finishTermination()
        }
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(3))
            self?.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
