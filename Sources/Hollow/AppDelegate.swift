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
    /// What the last probe said; re-probed off main whenever the panel opens.
    private var fdaStatus: FDAStatus = .unknown
    private var accessExplainer: AccessExplainer?
    private var observing: AnyCancellable?
    private weak var observedController: DriveController?

    private var state = DropdownState(model: DropdownModel.make(
        drives: [], selected: "", connected: [], summary: nil, space: nil, activity: .idle,
        period: 7, connectedSince: nil, now: .now))
    private var panel: DropdownPanel?
    private var lastDismiss = Date.distantPast
    private var clickMonitor: Any?
    private var mapWindow: MapWindowController?
    private let settingsStore = SettingsStore()
    private let settingsDrives = SettingsDrives()
    private var settingsWindow: SettingsWindowController?
    private var settingsSubscription: AnyCancellable?
    private var appliedSettings: AppSettings?
    /// One basket per mounted drive, by volume UUID; dropped when the drive is really gone (C20).
    private let baskets = BasketStore()
    /// Last saved summaries of drives that are not connected, read once per uuid and period.
    private var cachedSummaries: [String: [Int: DriveSummary?]] = [:]
    #if DEBUG
    private var debugSnapshotDir: URL?
    #endif
    private let mapLog = Logger(subsystem: AppIdentity.bundleID, category: "map")
    /// Holds a Finder eject (at most 2 s) while the drive's index closes; fed by every external controller's activity.
    private var unmountGate: UnmountGate?
    private var unmountApprover: UnmountApprover?
    /// By uuid, each with the controller it watches (held, so a replacement at a reused address still gets its own sink).
    private var activitySinks: [String: (controller: DriveController, sink: AnyCancellable)] = [:]
    /// Drives whose eject was refused and whose spent controller was replaced: the map window may reattach to them.
    private var refusedEjects: Set<String> = []
    /// Whether each external volume is a disk image, by uuid, as `DiskImageProbe` answered off main. A volume is shown
    /// once it has an answer.
    private var diskImages: [String: Bool] = [:]
    private var probingDiskImages: Set<String> = []
    /// Disk images get their index here, in the temporary folder, deleted when they unmount (never Application Support).
    private let imageStoreBase = FileManager.default.temporaryDirectory.appending(path: AppIdentity.bundleID + ".images")

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
            // Disk-image indexes left by a crash: the images are probed and scanned afresh when they mount.
            try? FileManager.default.removeItem(at: imageStoreBase)
            syncVolumes()
        } catch {
            NSLog("Hollow: cannot open store: \(error)")
        }
        // Emits the current value first (a no-op after the controllers were created with it), then every change.
        settingsSubscription = settingsStore.$settings.map { $0.normalized() }.removeDuplicates()
            .sink { [weak self] new in
                Task { @MainActor in self?.settingsChanged(new) }
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
        startUnmountApproval()

        probeFullDiskAccess(explainIfDue: true)

        if LoginItem.shouldRegister(bundlePath: Bundle.main.bundlePath, home: NSHomeDirectory()) {
            do {
                try LoginItem.registerOnFirstRun(defaults: UserDefaults.standard) { try SMAppService.mainApp.register() }
            } catch {
                // Ad-hoc signed builds may be refused; launch at login is optional.
                NSLog("Hollow: could not register login item: \(error)")
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
        // --show-settings [--settings-snapshot <png>]: opens Settings, and renders it to a PNG for a locked screen.
        if CommandLine.arguments.contains("--show-settings") {
            DispatchQueue.main.async { [weak self] in
                guard let self else { return }
                self.openSettings(nil)
                if let i = CommandLine.arguments.firstIndex(of: "--settings-snapshot"), i + 1 < CommandLine.arguments.count {
                    let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
                    DispatchQueue.main.asyncAfter(deadline: .now() + 1.5) { [weak self] in
                        self?.debugCapture(self?.settingsWindow?.window, to: out)
                    }
                }
            }
        }
        // --show-access-explainer <png>: shows the explainer (without recording that it was shown) and renders it.
        if let i = CommandLine.arguments.firstIndex(of: "--show-access-explainer"), i + 1 < CommandLine.arguments.count {
            let out = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            DispatchQueue.main.async { [weak self] in
                self?.presentAccessExplainer()
                DispatchQueue.main.asyncAfter(deadline: .now() + 1) { [weak self] in
                    self?.debugCapture(self?.accessExplainer?.window, to: out)
                }
            }
        }
        if CommandLine.arguments.contains("--show-map"), let id = internalUUID {
            startHeartbeat()
            // --map-focus <relative path>: opens the map at that item's folder with it selected.
            let focus = CommandLine.arguments.firstIndex(of: "--map-focus")
                .flatMap { $0 + 1 < CommandLine.arguments.count ? CommandLine.arguments[$0 + 1] : nil }
            DispatchQueue.main.async { [weak self] in self?.openMap(uuid: id, focus: focus) }
        }
        // --apply-stats: every 60 s, what each warm drive's index applied since the last line.
        if CommandLine.arguments.contains("--apply-stats") {
            startApplyStats()
        }
        // --map-snapshot <dir>: with --show-map, writes the window's PNGs once the map is drawn.
        if let i = CommandLine.arguments.firstIndex(of: "--map-snapshot"), i + 1 < CommandLine.arguments.count {
            debugSnapshotDir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
        }
        // --debug-basket <dir> [--debug-basket-move]: drives the basket and review sheet on the throwaway DITrash image only.
        if let i = CommandLine.arguments.firstIndex(of: "--debug-basket"), i + 1 < CommandLine.arguments.count {
            let dir = URL(fileURLWithPath: CommandLine.arguments[i + 1])
            let move = CommandLine.arguments.contains("--debug-basket-move")
            Task { [weak self] in await self?.debugBasket(to: dir, move: move) }
        }
        // --debug-open-map <mount point>: opens the map of a marked, mounted disk image, for the eject-hold check.
        if let i = CommandLine.arguments.firstIndex(of: "--debug-open-map"), i + 1 < CommandLine.arguments.count {
            let volume = CommandLine.arguments[i + 1]
            Task { [weak self] in await self?.debugOpenMap(volume) }
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
            let settings = self.settingsStore.settings
            let label = MenuBarLabel.make(space: space, showNumber: settings.menuBarStyle == .ringAndNumber,
                                          lowFraction: Double(settings.lowPercent) / 100,
                                          criticalFraction: Double(settings.criticalPercent) / 100)
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
        let volumes = VolumeCatalog.current().compactMap { v -> VolumeInfo? in
            guard v.isInternalData else {
                guard let image = diskImages[v.uuid] else {
                    probeDiskImage(v)
                    return nil
                }
                return v.markingDiskImage(image)
            }
            guard v.name.hasSuffix(" - Data") else { return v }
            return VolumeInfo(url: v.url, uuid: v.uuid, name: String(v.name.dropLast(7)),
                              isInternalData: true, device: v.device)
        }
        // A refused unmount (Finder: "disk in use") sends no didUnmount; the spent
        // controller would show the mounted drive as "Not connected" for good.
        for uuid in VolumeSync.spentControllersToReplace(
            mounted: Set(volumes.map(\.uuid)), unmountFinished: unmountFinished, ejecting: ejecting, now: now) {
            refusedEjects.insert(uuid)
            controllers[uuid] = nil
            unmounts[uuid] = nil
            unmountFinished[uuid] = nil
        }
        for v in volumes {
            var connected = false
            if controllers[v.uuid] == nil,
               let store = try? LiveIndex.storeDirectory(base: v.isDiskImage ? imageStoreBase : storeBase, volume: v.url) {
                controllers[v.uuid] = DriveController(volume: v, store: store, exclusions: exclusions(for: v),
                                                fullDiskAccess: { FullDiskAccess.status() != .denied })
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
        watchActivity()
        rebuild()
        // A refused eject left the drive mounted with a new controller: the map window shows it again (Decision 24).
        if let window = mapWindow, let c = controllers[window.uuid],
           VolumeSync.shouldReattach(windowDrive: window.uuid, holdsCurrentController: window.driveController === c,
                                     unmounting: unmounts[window.uuid] != nil, refused: refusedEjects) {
            refusedEjects.remove(window.uuid)
            Task { await window.reattach(controller: c) }
        }
    }

    /// Asks DiskArbitration, off main, whether a new volume is a disk image, then syncs again to show it.
    private func probeDiskImage(_ v: VolumeInfo) {
        guard probingDiskImages.insert(v.uuid).inserted else { return }
        let url = v.url
        Task { [weak self] in
            let image = await Task.detached(priority: .utility) { DiskImageProbe.isDiskImage(volume: url) }.value
            guard let self else { return }
            self.probingDiskImages.remove(v.uuid)
            self.diskImages[v.uuid] = image
            self.syncVolumes()
        }
    }

    // MARK: Unmount hold

    private func startUnmountApproval() {
        let gate = UnmountGate { [weak self] path in
            await MainActor.run { self?.uuid(forVolumePath: path).flatMap { self?.beginUnmount($0) } }?.value
        }
        let approver = UnmountApprover(gate: gate, log: Logger(subsystem: AppIdentity.bundleID, category: "drives"))
        unmountGate = gate
        unmountApprover = approver
        watchActivity()
        approver.start()
    }

    /// One sink per external controller; the gate always knows which drives have an open index.
    private func watchActivity() {
        guard unmountGate != nil else { return }
        activitySinks = activitySinks.filter { uuid, entry in controllers[uuid] === entry.controller }
        for (uuid, c) in controllers where !c.volume.isInternalData && activitySinks[uuid] == nil {
            // @Published fires on willSet; hop a turn so the read sees the new value.
            let sink = c.$activity.receive(on: DispatchQueue.main)
                .sink { [weak self] _ in self?.updateOpenDrives() }
            activitySinks[uuid] = (c, sink)
        }
        updateOpenDrives()
    }

    /// Drives with an open index, and drives whose close is still running: the system's willUnmount notification comes
    /// before the approval callback and turns the drive offline at once, but its index may not have closed yet.
    private func updateOpenDrives() {
        let open = controllers.filter { uuid, c in
            !c.volume.isInternalData
                && ([.opening, .scanning, .ready].contains(c.activity) || (unmounts[uuid] != nil && unmountFinished[uuid] == nil))
        }.values
        unmountGate?.setOpen(Set(open.map { $0.volume.url.resolvingSymlinksInPath().path }))
    }

    /// The external drive mounted at `path` (C14).
    private func uuid(forVolumePath path: String) -> String? {
        var path = path
        while path.count > 1, path.hasSuffix("/") { path.removeLast() }
        let real = URL(fileURLWithPath: path).resolvingSymlinksInPath().path
        return controllers.first { _, c in
            !c.volume.isInternalData && c.volume.url.resolvingSymlinksInPath().path == real
        }?.key
    }

    /// The skipped folders as paths relative to this volume's root.
    private func exclusions(for volume: VolumeInfo) -> Set<String> {
        settingsStore.settings.exclusions(under: volume.url.resolvingSymlinksInPath().path)
    }

    private func settingsChanged(_ new: AppSettings) {
        let old = appliedSettings
        appliedSettings = new
        if old?.menuBarStyle != new.menuBarStyle || old?.lowPercent != new.lowPercent || old?.criticalPercent != new.criticalPercent {
            refresh()
        }
        if old?.excludedFolders != new.excludedFolders {
            for c in controllers.values {
                let paths = new.exclusions(under: c.volume.url.resolvingSymlinksInPath().path)
                Task { await c.setExclusions(paths) }
            }
        }
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
        // The map window lets go of this controller and says the drive was disconnected.
        if let window = mapWindow, window.uuid == uuid, window.driveController === c { window.driveDisconnected() }
        let task = Task { [weak self] in
            await c.willUnmount()
            guard let self else { return }
            // willUnmount saves the index; whatever was cached before is stale.
            self.cachedSummaries[uuid] = nil
            if self.unmounts[uuid] != nil { self.unmountFinished[uuid] = Date() }
            self.updateOpenDrives()
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
                if self.controllers[uuid]?.volume.isDiskImage == true {
                    // Shown only while mounted: no "Not connected" tab and no index left behind.
                    self.registry.dropUnmountedImage(uuid: uuid)
                    try? FileManager.default.removeItem(at: LiveIndex.storeDirectory(base: self.imageStoreBase, uuid: uuid))
                }
                self.diskImages[uuid] = nil
                self.controllers[uuid] = nil
                self.unmounts[uuid] = nil
                self.unmountFinished[uuid] = nil
                self.connectedSince[uuid] = nil
                self.baskets.drop(uuid)
                self.refusedEjects.remove(uuid)
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
                self.refusedEjects.insert(uuid)
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
        settingsDrives.drives = registry.all()
        let model = DropdownModel.make(
            drives: registry.all(), selected: selected, connected: connected, summary: summary,
            space: c?.space, activity: c?.activity ?? .offline, period: period,
            connectedSince: connectedSince[selected], now: .now, clearable: c?.clearable,
            fullDiskAccess: fdaStatus)
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
            },
            reviewClearable: { [weak self] in
                guard let self else { return }
                self.reviewClearable(uuid: self.selected)
            },
            openSettings: { [weak self] in self?.openSettings(nil) })
        let p = DropdownPanel(rootView: host)
        p.onOpenSettings = { [weak self] in self?.openSettings(nil) }
        p.onDismiss = { [weak self] in self?.panelDismissed() }
        return p
    }

    private func showPanel(keepOpen: Bool) {
        // Drop what the last showing left behind so timers and monitors never stack.
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
        probeFullDiskAccess(explainIfDue: false)
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
        NSLog("Hollow panel window \(p.windowNumber) frame \(p.frame)")
        NSLog("Hollow showPanel main thread: sync+model \(dataReady), total \(clock.now - started)")
        #endif
    }

    /// Probes off main. A change redraws the panel; at launch a denial shows the explainer once.
    private func probeFullDiskAccess(explainIfDue: Bool) {
        Task { @MainActor in
            let status = await FullDiskAccess.currentStatus()
            if status != fdaStatus {
                fdaStatus = status
                rebuild()
            }
            #if DEBUG
            // Debug runs with flags must not use up the one-time explainer.
            if CommandLine.arguments.dropFirst().contains(where: { $0.hasPrefix("--") }) { return }
            #endif
            if explainIfDue, AccessExplainer.isDue(status: status) {
                UserDefaults.standard.set(true, forKey: AccessExplainer.defaultsKey)
                presentAccessExplainer()
            }
        }
    }

    private func presentAccessExplainer() {
        let explainer = AccessExplainer()
        explainer.onClose = { [weak self] in self?.accessExplainer = nil }
        accessExplainer = explainer
        NSApp.activate(ignoringOtherApps: true)
        explainer.showWindow(nil)
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
    private var applyStatsTimer: Timer?
    /// The stats each drive's line was last measured from, by uuid.
    private var lastApplyStats: [String: ApplyStats] = [:]
    private let indexLog = Logger(subsystem: AppIdentity.bundleID, category: "index")

    private func startApplyStats() {
        applyStatsTimer = Timer.scheduledTimer(withTimeInterval: 60, repeats: true) { [weak self] _ in
            MainActor.assumeIsolated { self?.logApplyStats() }
        }
    }

    private func logApplyStats() {
        let all = controllers
        Task { @MainActor in
            for (uuid, c) in all.sorted(by: { $0.key < $1.key }) {
                guard let now = await c.applyStats() else { lastApplyStats[uuid] = nil; continue }
                // A re-opened index counts from zero again.
                var last = lastApplyStats[uuid] ?? ApplyStats(applies: 0, foldersRelisted: 0, subtreesRescanned: 0,
                                                              fullRescans: 0, busy: .zero)
                if now.applies < last.applies {
                    last = ApplyStats(applies: 0, foldersRelisted: 0, subtreesRescanned: 0, fullRescans: 0, busy: .zero)
                }
                lastApplyStats[uuid] = now
                let ms = Int((now.busy - last.busy) / .milliseconds(1))
                indexLog.info("""
                    apply stats \(c.volume.name, privacy: .public): \(now.applies - last.applies) applies, \
                    \(now.foldersRelisted - last.foldersRelisted) relists, \(now.subtreesRescanned - last.subtreesRescanned) subtrees, \
                    \(now.fullRescans - last.fullRescans) full, \(ms) ms busy
                    """)
            }
        }
    }

    private func beat() {
        let now = CACurrentMediaTime()
        let late = (now - heartbeatLast - 0.1) * 1000
        heartbeatLast = now
        heartbeatLongest = max(heartbeatLongest, late)
        if late > 16 { mapLog.info("main thread late \(Int(late)) ms (longest \(Int(self.heartbeatLongest)) ms)") }
    }
    #endif

    #if DEBUG
    /// The only volume the basket driver will touch: a disk image mounted at exactly this path, never the internal disk (C9).
    private static let debugBasketVolume = "/Volumes/DITrash"

    /// A plain file only the check script creates at the image's root.
    private static let debugBasketMarker = ".hollow-test-volume"

    /// True when `hdiutil info` lists a disk image mounted at exactly `mountPoint`.
    nonisolated private static func isMountedDiskImage(at mountPoint: String) -> Bool {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/hdiutil")
        process.arguments = ["info", "-plist"]
        let pipe = Pipe()
        process.standardOutput = pipe
        guard (try? process.run()) != nil else { return false }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        process.waitUntilExit()
        guard process.terminationStatus == 0,
              let info = try? PropertyListSerialization.propertyList(from: data, format: nil) as? [String: Any],
              let images = info["images"] as? [[String: Any]] else { return false }
        return images.contains { image in
            (image["system-entities"] as? [[String: Any]] ?? []).contains { ($0["mount-point"] as? String) == mountPoint }
        }
    }

    private func debugOpenMap(_ volume: String) async {
        let isImage = await Task.detached { Self.isMountedDiskImage(at: volume) }.value
        var marker = stat()
        let hasMarker = lstat(volume + "/" + Self.debugBasketMarker, &marker) == 0 && (marker.st_mode & S_IFMT) == S_IFREG
        guard isImage, hasMarker, let uuid = uuid(forVolumePath: volume) else {
            mapLog.error("debug-open-map: refused, \(volume, privacy: .public) is not a marked, mounted disk image")
            return
        }
        mapLog.info("debug-open-map: \(volume, privacy: .public) opened \(self.openMap(uuid: uuid, focus: "d1"))")
    }

    private func debugBasket(to dir: URL, move: Bool) async {
        let url = URL(fileURLWithPath: Self.debugBasketVolume)
        let values = try? url.resourceValues(forKeys: [.volumeIsInternalKey, .volumeIsEjectableKey, .volumeURLKey])
        let volume = Self.debugBasketVolume
        let isImage = await Task.detached { Self.isMountedDiskImage(at: volume) }.value
        var marker = stat()
        let hasMarker = lstat(volume + "/" + Self.debugBasketMarker, &marker) == 0 && (marker.st_mode & S_IFMT) == S_IFREG
        guard let c = controller(for: url), !c.volume.isInternalData, c.volume.url.path == Self.debugBasketVolume,
              values?.volume?.path == Self.debugBasketVolume, values?.volumeIsInternal != true, values?.volumeIsEjectable == true,
              isImage, hasMarker
        else {
            mapLog.error("debug-basket: refused, \(Self.debugBasketVolume, privacy: .public) is not a marked, mounted disk image")
            return
        }
        let uuid = c.volume.uuid
        func settle(_ ms: Int = 1500) async { try? await Task.sleep(for: .milliseconds(ms)) }
        selectDrive(uuid)
        await c.warm()
        for _ in 0..<100 where c.lens == nil { await settle(200) }
        rebuild()
        mapLog.info("debug-basket: review title \(self.state.model.reviewTitle ?? "none", privacy: .public), free \(self.state.model.freeTitle, privacy: .public)")
        showPanel(keepOpen: true)
        await settle()
        debugCapture(panel, to: dir.appending(path: "panel.png"))
        reviewClearable(uuid: uuid)
        await settle(2500)
        guard let window = mapWindow, window.uuid == uuid else { return }
        window.debugSheetSnapshot(to: dir.appending(path: "review.png"))
        mapLog.info("debug-basket: basket \(window.basket.items.map(\.path), privacy: .public)")
        if move {
            let clock = ContinuousClock()
            let started = clock.now
            let outcome = await window.debugMoveReviewed()
            let ms = (clock.now - started) / .milliseconds(1)
            mapLog.info("debug-basket: \(outcome.title, privacy: .public) / \(outcome.detail ?? "-", privacy: .public) / \(outcome.failureLines, privacy: .public) in \(Int(ms)) ms")
            rebuild()
            mapLog.info("debug-basket: after move free \(self.state.model.freeTitle, privacy: .public), review \(self.state.model.reviewTitle ?? "none", privacy: .public)")
            await settle(1000)
            debugCapture(panel, to: dir.appending(path: "panel-after.png"))
            // A symlink item goes to the Trash as the link; its target stays (fixture made by the check script).
            let link = BasketItem(path: "Users/u/linkcheck/link", name: "link", size: 0, kind: .other, isFolder: false,
                                  ruleID: nil, safety: nil)
            let linkOutcome = await c.trash([link], backend: SystemTrash())
            mapLog.info("debug-basket: symlink moved \(linkOutcome.moved, privacy: .public) failures \(linkOutcome.failureLines, privacy: .public)")

            // While a sheet is moving, its window is neither replaced nor reset.
            window.debugSetPhase(.moving)
            let opened = openMap(uuid: internalUUID ?? "", focus: nil)
            reviewClearable(uuid: uuid)
            mapLog.info("debug-basket: while moving: other drive's map opened \(opened), window kept \(self.mapWindow === window), sheet \(String(describing: window.debugReview), privacy: .public)")
            // A finished sheet goes back to its list on the next review.
            window.debugSetPhase(.done(outcome))
            reviewClearable(uuid: uuid)
            mapLog.info("debug-basket: review after done: sheet \(String(describing: window.debugReview), privacy: .public)")
        }
        window.debugCloseReview()
        await settle()
        await window.debugBasketDrive(to: dir)
        mapLog.info("debug-basket: done")
    }

    private func debugCapture(_ window: NSWindow?, to url: URL) {
        guard let content = window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
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

    // MARK: Settings window

    @objc func openSettings(_ sender: Any?) {
        panel?.dismiss()
        if settingsWindow == nil {
            let window = SettingsWindowController(store: settingsStore, drives: settingsDrives,
                                                  setTint: { [weak self] uuid, index in self?.setTint(uuid: uuid, index: index) })
            window.onClose = { [weak self] in
                // The window object stays; the Dock icon goes unless the map window is open.
                self?.settingsOpen = false
                self?.updateActivationPolicy()
            }
            settingsWindow = window
        }
        settingsOpen = true
        updateActivationPolicy()
        NSApp.activate()
        settingsWindow?.showWindow(nil)
        settingsWindow?.window?.makeKeyAndOrderFront(nil)
    }

    private var settingsOpen = false

    /// Regular (Dock icon, menu bar) while the map or Settings window is open, else accessory.
    private func updateActivationPolicy() {
        NSApp.setActivationPolicy(mapWindow != nil || settingsOpen ? .regular : .accessory)
    }

    private func setTint(uuid: String, index: Int) {
        guard registry != nil, (try? registry.setTint(uuid: uuid, index: index)) != nil else { return }
        rebuild()
        if let window = mapWindow, window.uuid == uuid { window.setTint(index: index) }
    }

    // MARK: Map window

    /// Opens the map for drive `uuid`: at the root when `focus` is nil or empty, else at
    /// `focus`'s parent with `focus` selected. One map window at a time.
    /// False when nothing opened: the drive is gone, or another drive's window is moving items to the Trash.
    @discardableResult
    func openMap(uuid: String, focus: String?) -> Bool {
        let clock = ContinuousClock()
        let started = clock.now
        guard let controller = controllers[uuid], unmounts[uuid] == nil,
              let drive = registry?.all().first(where: { $0.uuid == uuid }) else { return false }
        var path = "", select: String?
        if let focus, !focus.isEmpty {
            path = focus.lastIndex(of: "/").map { String(focus[..<$0]) } ?? ""
            select = focus
        }
        if let window = mapWindow, window.uuid == uuid, window.driveController === controller {
            window.show(path: path, select: select)
        } else {
            if let old = mapWindow {
                // A move to the Trash in progress keeps its window and sheet: refuse, and show it.
                guard !old.isMovingToTrash else {
                    NSSound.beep()
                    NSApp.activate()
                    old.window?.makeKeyAndOrderFront(nil)
                    return false
                }
                old.endReview()
                mapWindow = nil
                old.close()
            }
            let window = MapWindowController(controller: controller, drive: drive, path: path, select: select,
                                             basket: baskets.basket(for: uuid))
            window.onClose = { [weak self, weak window] in
                guard let self, self.mapWindow === window else { return }
                self.mapWindow = nil
                // The Dock icon shows only while a window is open (spec 5).
                self.updateActivationPolicy()
            }
            window.onBecameKey = { [weak self] in self?.syncVolumes() }
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
        updateActivationPolicy()
        NSApp.activate()
        mapWindow?.showWindow(nil)
        mapWindow?.window?.makeKeyAndOrderFront(nil)
        let ms = (clock.now - started) / .milliseconds(1)
        mapLog.info("map window shown in \(Int(ms)) ms")
        #if DEBUG
        if let w = mapWindow?.window { NSLog("Hollow map window \(w.windowNumber) frame \(w.frame)") }
        #endif
        return true
    }

    /// "Review N GB to clear": puts the drive's regenerating hits in its basket, opens the map at the root and shows
    /// the review sheet. Nothing moves until the user presses "Move N items to Trash" there.
    func reviewClearable(uuid: String) {
        panel?.dismiss()
        guard let c = controllers[uuid], unmounts[uuid] == nil, openMap(uuid: uuid, focus: nil),
              let window = mapWindow, window.uuid == uuid, window.driveController === c else { return }
        // A sheet that is moving keeps its list; the hits wait for the next review.
        guard !window.isMovingToTrash else { NSSound.beep(); return }
        let hits = c.lens?.hits.filter { $0.safety == .regenerates } ?? []
        baskets.basket(for: uuid).add(contentsOf: hits.map(BasketItem.from(hit:)))
        window.presentReview()
    }

    // MARK: Quit

    private var terminating = false
    private var terminationReplied = false

    /// Spec 6.4 records history at app quit: cool every controller so each open index
    /// records today's snapshot and saves, waiting at most 3 seconds.
    func applicationShouldTerminate(_ sender: NSApplication) -> NSApplication.TerminateReply {
        guard !terminating else { return .terminateLater }
        terminating = true
        unmountApprover?.stop()
        Task { [weak self] in
            // A move to the Trash in progress finishes first (at most 30 s): stopping it between items would leave some
            // moved and some not, with no outcome shown.
            _ = await QuitWait.whileBusy { self?.mapWindow?.isMovingToTrash == true }
            guard let self else { return }
            let all = Array(self.controllers.values)
            Task { [weak self] in
                try? await Task.sleep(for: .seconds(3))
                self?.finishTermination()
            }
            await withTaskGroup(of: Void.self) { group in
                for c in all { group.addTask { await c.cool() } }
            }
            self.finishTermination()
        }
        return .terminateLater
    }

    private func finishTermination() {
        guard !terminationReplied else { return }
        terminationReplied = true
        NSApp.reply(toApplicationShouldTerminate: true)
    }
}
