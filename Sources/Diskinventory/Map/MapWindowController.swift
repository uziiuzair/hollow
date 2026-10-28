import AppKit
import Combine
import DiskApp
import DiskEngine
import Quartz
import os
import SwiftUI

/// The full map window for one drive. It holds the drive warm while open (through the
/// model) and drops the model, renderer and hosting view when it closes.
@MainActor
final class MapWindowController: NSWindowController, NSWindowDelegate {
    let uuid: String
    /// The controller this window holds; a remount brings a new one, which this window can't use.
    private(set) weak var driveController: DriveController?
    var onClose: (() -> Void)?
    var onFirstFrame: (() -> Void)?

    private var model: MapModel?
    private var ui: MapWindowState?
    private var mapView: TreemapMTKView?
    private var dragState: BasketDragState?
    /// This drive's basket; it outlives the window (the store keeps it until the drive is gone).
    let basket: Basket
    private var subscriptions: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var displayObserver: NSObjectProtocol?

    init(controller: DriveController, drive: KnownDrive, path: String, select: String?, basket: Basket) {
        uuid = drive.uuid
        driveController = controller
        self.basket = basket
        let model = MapModel(source: controller, driveName: drive.name,
                             reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let ui = MapWindowState(driveName: drive.name,
                                tint: Palette.tints[drive.tintIndex % Palette.tints.count],
                                isInternal: controller.volume.isInternalData, basket: basket)
        let dragState = BasketDragState()
        self.model = model
        self.ui = ui
        self.dragState = dragState

        let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 1100, height: 700),
                              styleMask: [.titled, .closable, .miniaturizable, .resizable, .fullSizeContentView],
                              backing: .buffered, defer: false)
        window.titlebarAppearsTransparent = true
        window.titleVisibility = .hidden
        window.toolbar = NSToolbar(identifier: "MapWindow")
        window.toolbarStyle = .unified
        // Shown in the Window menu and Mission Control; the title bar itself hides it.
        window.title = "\(AppIdentity.name) — \(drive.name)"
        window.minSize = NSSize(width: 760, height: 480)
        window.isReleasedWhenClosed = false
        super.init(window: window)
        window.delegate = self

        let mapView = TreemapMTKView()
        self.mapView = mapView
        mapView?.renderer?.onFirstFrame = { [weak self] in self?.onFirstFrame?() }

        let actions = MapWindowActions(
            run: { [weak self] in self?.run($0) },
            zoomIn: { [weak self] in self?.zoomIntoSelection() },
            quickLook: { [weak self] in self?.toggleQuickLook() },
            openCommands: { [weak self] in self?.ui?.focusRequest += 1 },
            addToBasket: { [weak self] in self?.addSelectionToBasket() },
            drag: { [weak self] in self?.dragChanged($0) },
            drop: { [weak self] in self?.dropped($0) },
            review: { [weak self] in self?.presentReview() },
            trash: { [weak self] items in await self?.moveToTrash(items) ?? .driveGone(items, protected: []) },
            protected: { [weak self] in self?.driveController?.protectedHits ?? [] })
        let hosting = NSHostingView(rootView: MapWindowView(model: model, ui: ui, basket: basket, pointer: MapPointer(),
                                                            dragState: dragState, mapView: mapView, actions: actions))
        // The window, not the SwiftUI content, decides the window's size.
        hosting.sizingOptions = []
        window.contentView = hosting
        window.setContentSize(NSSize(width: 1100, height: 700))
        window.center()
        window.setFrameAutosaveName("MapWindow")
        // The map, not the search field, has focus at open.
        window.initialFirstResponder = mapView

        observe(controller, model: model, ui: ui)
        installKeyMonitor()
        Task { await controller.refreshSpace() }
        show(path: path, select: select)
    }

    @available(*, unavailable)
    required init?(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    /// Shows `path` with the depth-1 item `select` selected.
    func show(path: String, select: String?) {
        guard let model else { return }
        Task { await model.open(path: path, select: select) }
    }

    /// The drive is being unmounted. The window stays and says the drive was disconnected;
    /// the model lets go of the drive and drops the map. A remount opens a new window.
    func driveDisconnected() {
        model?.driveDisconnected()
    }

    // MARK: Glue

    private func observe(_ controller: DriveController, model: MapModel, ui: MapWindowState) {
        // C5: @Published fires on willSet; hop a turn so the model reads the new values.
        Publishers.Merge3(controller.$generation.dropFirst().map { _ in () },
                          controller.$activity.dropFirst().map { _ in () },
                          controller.$period.dropFirst().map { _ in () })
            .receive(on: DispatchQueue.main)
            .sink { [weak model] in model?.sourceChanged() }
            .store(in: &subscriptions)
        controller.$space
            .receive(on: DispatchQueue.main)
            .sink { [weak ui] space in ui?.free = space.map { Format.gb($0.availableForImportantUsage) + " free" } }
            .store(in: &subscriptions)
        model.$selected
            .receive(on: DispatchQueue.main)
            .sink { _ in
                guard QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible else { return }
                panel.reloadData()
            }
            .store(in: &subscriptions)
        displayObserver = NSWorkspace.shared.notificationCenter.addObserver(
            forName: NSWorkspace.accessibilityDisplayOptionsDidChangeNotification, object: nil, queue: .main
        ) { [weak model] _ in
            MainActor.assumeIsolated {
                model?.reduceMotion = NSWorkspace.shared.accessibilityDisplayShouldReduceMotion
            }
        }
    }

    // MARK: Keys

    private func installKeyMonitor() {
        keyMonitor = NSEvent.addLocalMonitorForEvents(matching: .keyDown) { [weak self] event in
            let handled = MainActor.assumeIsolated {
                self?.handleKey(event) ?? false
            }
            return handled ? nil : event
        }
    }

    /// True when the event was handled and should be swallowed.
    private func handleKey(_ event: NSEvent) -> Bool {
        guard let window, window.isKeyWindow, event.window === window, model != nil, let ui else { return false }
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags)
        guard let command = MapKey.command(keyCode: event.keyCode, characters: event.charactersIgnoringModifiers,
                                           modifiers: modifiers, searchFocused: ui.searchFocused)
        else { return false }
        perform(command)
        return true
    }

    private func perform(_ command: MapKeyCommand) {
        guard let model, let ui else { return }
        switch command {
        case .zoomIn: zoomIntoSelection()
        case .zoomOut: model.zoomOut()
        case .quickLook: toggleQuickLook()
        case .openCommands: ui.focusRequest += 1
        case .addToBasket: addSelectionToBasket()
        case .selectPrevious: model.moveSelection(by: -1)
        case .selectNext: model.moveSelection(by: 1)
        case .closeSearch: closeSearch()
        case .runCommand:
            let items = ui.commands(model)
            if items.indices.contains(ui.commandIndex) { run(items[ui.commandIndex].action) }
        case .commandUp:
            ui.commandIndex = max(ui.commandIndex - 1, 0)
        case .commandDown:
            ui.commandIndex = min(ui.commandIndex + 1, max(ui.commands(model).count - 1, 0))
        }
    }

    // MARK: Basket

    /// True while the review sheet is moving items to the Trash; the window must not be replaced or closed then.
    var isMovingToTrash: Bool { ui?.reviewPhase == .moving }

    /// Opens the review sheet over the map, back at its list when it was showing a finished move.
    /// Does nothing to a sheet that is moving.
    func presentReview() {
        guard let ui, ui.reviewPhase != .moving else { return }
        ui.reviewPhase = .review
        ui.reviewShown = true
    }

    /// Takes the review sheet down at once (before the window closes). Not while it is moving.
    func endReview() {
        guard let ui, ui.reviewPhase != .moving else { return }
        ui.reviewShown = false
        ui.reviewPhase = .review
        if let window, let sheet = window.attachedSheet { window.endSheet(sheet) }
    }

    /// ⌫ and "Add to Basket": the selected block, unless it is a bucket, the root or already in the basket.
    private func addSelectionToBasket() {
        guard let model, let selected = model.selected else { return }
        addToBasket(rect: selected)
    }

    private func addToBasket(rect: Int) {
        guard let model, let item = ui?.basketItem(model, rect: rect) else { return }
        basket.add(item)
    }

    private func dragChanged(_ drag: BasketDrag) {
        guard let dragState else { return }
        let next = drag.isActive ? drag : nil
        if dragState.drag != next { dragState.drag = next }
    }

    private func dropped(_ drag: BasketDrag) {
        guard let dragState else { return }
        // By the pressed node's key in the map shown now: a rebuild during the drag adds the pressed item or nothing.
        if drag.dropsOnBasket(dragState.barFrame), let key = drag.key,
           let item = model?.snapshot?.basketItem(droppedKey: key) {
            basket.add(item)
        }
        dragState.drag = nil
    }

    /// The review sheet's "Move N items to Trash". The window's own controller only: after a disconnect it moves nothing.
    private func moveToTrash(_ items: [BasketItem]) async -> TrashOutcome {
        guard let controller = driveController, model?.status != .offline else {
            return .driveGone(items, protected: driveController?.protectedHits ?? [])
        }
        return await controller.trash(items, backend: SystemTrash())
    }

    private func zoomIntoSelection() {
        guard let model, let selected = model.selected else { return }
        model.zoomIn(selected)
    }

    private func closeSearch() {
        guard let ui else { return }
        ui.query = ""
        ui.blurRequest += 1
        window?.makeFirstResponder(mapView)
    }

    override func showWindow(_ sender: Any?) {
        super.showWindow(sender)
        // SwiftUI would otherwise put the first key view, the search field, in focus.
        if let mapView, ui?.searchFocused != true { window?.makeFirstResponder(mapView) }
    }

    // MARK: Actions

    private func run(_ action: MapAction) {
        guard let model else { return }
        let url = model.selected.flatMap { model.snapshot?.url(of: $0) }
        switch action {
        case .addToBasket:
            addSelectionToBasket()
        case .revealInFinder:
            if let url { NSWorkspace.shared.activateFileViewerSelecting([url]) }
        case .copyPath:
            if let url {
                NSPasteboard.general.clearContents()
                NSPasteboard.general.setString(url.path, forType: .string)
            }
        case .zoomToParent:
            model.zoomOut()
        case .goTo(let key):
            if let snapshot = model.snapshot,
               let i = (0..<snapshot.layout.topLevelCount).first(where: { snapshot.nodes[$0].key == key }) {
                model.select(i)
            }
        }
        closeSearch()
    }

    // MARK: Quick Look

    private func toggleQuickLook() {
        guard let panel = QLPreviewPanel.shared() else { return }
        if QLPreviewPanel.sharedPreviewPanelExists(), panel.isVisible {
            panel.orderOut(nil)
        } else {
            panel.makeKeyAndOrderFront(nil)
        }
    }

    // QLPreviewPanelController is an informal NSObject protocol, so these come in nonisolated;
    // the panel always calls them on main.
    override func acceptsPreviewPanelControl(_ panel: QLPreviewPanel!) -> Bool { true }

    override func beginPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated {
            panel.dataSource = self
            panel.reloadData()
        }
    }

    override func endPreviewPanelControl(_ panel: QLPreviewPanel!) {
        MainActor.assumeIsolated { panel.dataSource = nil }
    }

    private var previewURL: URL? {
        guard let model, let selected = model.selected else { return nil }
        return model.snapshot?.url(of: selected)
    }

    #if DEBUG
    // MARK: Debug snapshots

    private let debugLog = Logger(subsystem: AppIdentity.bundleID, category: "map")

    /// Writes PNGs of the window to `dir` in dark and light, plain, hovered and zoomed in,
    /// then closes the window.
    /// It draws the window itself (SwiftUI via cacheDisplay, the map from the renderer), so it
    /// works while the screen is locked; the hover card and materials are not in it.
    func debugCapture(to dir: URL) async {
        guard let window, self.model != nil else { return }
        weak let model = self.model
        func shot(_ name: String) async {
            try? await Task.sleep(for: .milliseconds(1500))
            debugSnapshot(to: dir.appending(path: name + ".png"))
        }
        for (name, appearance) in [("dark", NSAppearance.Name.darkAqua), ("light", .aqua)] {
            window.appearance = NSAppearance(named: appearance)
            model?.select(nil)
            model?.hovered = nil
            await shot(name)
            model?.select(1)
            model?.hovered = 0
            await shot(name + "-hover")
            model?.hovered = nil
        }
        window.appearance = nil
        if let first = model?.snapshot.flatMap({ s in (0..<s.layout.topLevelCount).first { s.nodes[$0].isFolder } }) {
            model?.zoomIn(first)
            await shot("zoomed")
            model?.zoomOut()
            await shot("zoomed-out")
        }
        debugLog.info("map snapshots written to \(dir.path, privacy: .public)")
        close()
        try? await Task.sleep(for: .milliseconds(500))
        debugLog.info("map closed: model released \(model == nil), policy \(NSApp.activationPolicy().rawValue)")
    }

    private func debugSnapshot(to url: URL) {
        guard let content = window?.contentView, let rep = content.bitmapImageRepForCachingDisplay(in: content.bounds) else { return }
        content.cacheDisplay(in: content.bounds, to: rep)
        let size = content.bounds.size
        guard let out = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: rep.pixelsWide, pixelsHigh: rep.pixelsHigh,
                                         bitsPerSample: 8, samplesPerPixel: 4, hasAlpha: true, isPlanar: false,
                                         colorSpaceName: .deviceRGB, bytesPerRow: 0, bitsPerPixel: 0) else { return }
        out.size = size
        NSGraphicsContext.saveGraphicsState()
        NSGraphicsContext.current = NSGraphicsContext(bitmapImageRep: out)
        rep.draw(in: NSRect(origin: .zero, size: size))
        if let mapView, mapView.alphaValue > 0, let image = mapView.renderer?.debugImage(in: mapView) {
            let frame = mapView.convert(mapView.bounds, to: nil)
            NSGraphicsContext.current?.cgContext.draw(image, in: frame)
        }
        // The basket bar floats over the map: draw its part of the SwiftUI layer again, on top.
        if let bar = dragState?.barFrame, !bar.isEmpty, basket.items.count > 0 || dragState?.drag != nil {
            let rect = NSRect(x: bar.minX, y: size.height - bar.maxY, width: bar.width, height: bar.height)
            NSGraphicsContext.current?.cgContext.clip(to: rect)
            rep.draw(in: NSRect(origin: .zero, size: size))
        }
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
    }

    // MARK: Debug basket driver

    /// Logs the presented sheet, then writes the same sheet view, hosted off screen, to `url` (a sheet on a locked
    /// screen is never drawn).
    func debugSheetSnapshot(to url: URL) {
        debugLog.info("debug-basket: sheet presented \(self.window?.attachedSheet != nil), frame \(String(describing: self.window?.attachedSheet?.frame), privacy: .public)")
        guard let ui else { return }
        let view = ReviewSheetView(basket: basket, phase: .constant(.review), protected: { [weak self] in self?.driveController?.protectedHits ?? [] },
                                   driveName: ui.driveName, driveConnected: model?.status != .offline,
                                   move: { .driveGone($0, protected: []) }, close: {})
        let host = NSHostingView(rootView: view.background(Color(nsColor: .windowBackgroundColor)))
        host.appearance = window?.effectiveAppearance
        host.frame = NSRect(origin: .zero, size: host.fittingSize)
        host.layoutSubtreeIfNeeded()
        host.frame.size = host.fittingSize
        host.layoutSubtreeIfNeeded()
        guard let rep = host.bitmapImageRepForCachingDisplay(in: host.bounds) else { return }
        host.cacheDisplay(in: host.bounds, to: rep)
        try? rep.representation(using: .png, properties: [:])?.write(to: url)
    }

    /// The review sheet's move, as its button runs it: the checked trashable items, then the cleared ones leave the basket.
    func debugMoveReviewed() async -> TrashOutcome {
        let protected = driveController?.protectedHits ?? []
        let items = ReviewSheet.trashable(basket.items, unchecked: [], protected: protected)
        debugLog.info("debug-basket: moving \(items.map(\.path), privacy: .public)")
        ui?.reviewPhase = .moving
        let outcome = await moveToTrash(items)
        basket.remove(paths: outcome.cleared)
        ui?.reviewPhase = .done(outcome)
        return outcome
    }

    func debugCloseReview() { ui?.reviewShown = false }

    var debugReview: (shown: Bool, phase: ReviewPhase)? { ui.map { ($0.reviewShown, $0.reviewPhase) } }

    func debugSetPhase(_ phase: ReviewPhase) { ui?.reviewPhase = phase }

    private func debugBasketLine(_ step: String) {
        let items = basket.items.map(\.path)
        debugLog.info("debug-basket: \(step, privacy: .public): \(items.count) items \(Format.gb(self.basket.total), privacy: .public) \(items, privacy: .public)")
    }

    /// A mouse event at `p` in the map view (top-left origin), handed straight to the map view (a locked screen
    /// delivers no events to an inactive window).
    private func postMouse(_ type: NSEvent.EventType, _ p: CGPoint) {
        guard let window, let mapView,
              let e = NSEvent.mouseEvent(with: type, location: mapView.convert(p, to: nil), modifierFlags: [],
                                         timestamp: ProcessInfo.processInfo.systemUptime, windowNumber: window.windowNumber,
                                         context: nil, eventNumber: 0, clickCount: 1, pressure: type == .leftMouseUp ? 0 : 1)
        else { return }
        switch type {
        case .leftMouseDown: mapView.mouseDown(with: e)
        case .leftMouseDragged: mapView.mouseDragged(with: e)
        default: mapView.mouseUp(with: e)
        }
    }

    /// A point in the window content (top-left origin) in the map view's coordinates.
    private func mapPoint(fromContent p: CGPoint) -> CGPoint? {
        guard let content = window?.contentView, let mapView else { return nil }
        let inContent = content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
        return mapView.convert(content.convert(inContent, to: nil), from: nil)
    }

    /// Drives the basket the way a user would, with synthetic keys and presses, writing PNGs to `dir`.
    /// Paths are the DITrash fixture's.
    func debugBasketDrive(to dir: URL) async {
        guard let model, let window else { return }
        func settle(_ ms: Int = 1500) async { try? await Task.sleep(for: .milliseconds(ms)) }
        window.makeKeyAndOrderFront(nil)
        window.makeFirstResponder(mapView)
        basket.clear()

        await model.open(path: "Users/u", select: "Users/u/movie.mov")
        await settle()
        debugLog.info("debug-basket: key window \(window.isKeyWindow), selected \(model.selected.map { model.snapshot?.nodes[$0].key ?? "?" } ?? "nil", privacy: .public), can add \(self.ui?.canAddSelection(model) ?? false)")
        // A locked screen makes no window key, so keys go straight to the window's own key handling.
        MapKey.command(keyCode: 51, modifiers: [], searchFocused: false).map(perform)
        await settle(500)
        debugBasketLine("after delete key")
        debugSnapshot(to: dir.appending(path: "bar-1.png"))

        let docker = "Users/u/Library/Containers/com.docker.docker/Data/Docker.raw"
        await model.open(path: "Users/u/Library/Containers/com.docker.docker/Data", select: docker)
        await settle()
        MapKey.command(keyCode: 40, characters: "k", modifiers: .command, searchFocused: false).map(perform)
        await settle(500)
        debugLog.info("debug-basket: commands \(self.ui.map { $0.commands(model).map(\.title) } ?? [], privacy: .public)")
        MapKey.command(keyCode: 36, modifiers: [], searchFocused: true).map(perform)
        await settle(500)
        debugBasketLine("after command bar")
        debugSnapshot(to: dir.appending(path: "bar-2.png"))

        model.zoom(to: nil)
        await settle()
        guard let snapshot = model.snapshot,
              let users = (0..<snapshot.layout.topLevelCount).first(where: { snapshot.nodes[$0].key == "Users" }) else {
            debugLog.info("debug-basket: no Users block")
            return
        }
        let f = snapshot.layout.rects[users].frame
        let c = CGPoint(x: f.midX, y: f.midY)
        postMouse(.leftMouseDown, c)
        postMouse(.leftMouseDragged, CGPoint(x: c.x + 1, y: c.y + 1))
        postMouse(.leftMouseUp, CGPoint(x: c.x + 2, y: c.y))
        await settle()
        debugLog.info("debug-basket: after 2 pt press, zoom \(model.zoomPath, privacy: .public)")
        debugBasketLine("after 2 pt press")
        model.zoom(to: nil)
        await settle()

        let bar = dragState?.barFrame ?? .zero
        guard let target = mapPoint(fromContent: CGPoint(x: bar.midX, y: bar.midY)) else { return }
        debugLog.info("debug-basket: bar frame \(String(describing: bar), privacy: .public), target in map \(String(describing: target), privacy: .public)")
        // Press and drag onto the bar, then hold so the PNG shows the bar as a target.
        postMouse(.leftMouseDown, c)
        for i in 1...8 {
            postMouse(.leftMouseDragged, CGPoint(x: c.x + (target.x - c.x) * CGFloat(i) / 8, y: c.y + (target.y - c.y) * CGFloat(i) / 8))
        }
        await settle(800)
        debugLog.info("debug-basket: dragging \(self.dragState?.drag.map { "active \($0.isActive) over \($0.dropsOnBasket(bar))" } ?? "none", privacy: .public)")
        debugSnapshot(to: dir.appending(path: "dragging.png"))
        postMouse(.leftMouseUp, target)
        await settle(800)
        debugBasketLine("after drop on bar")
        debugSnapshot(to: dir.appending(path: "bar-3.png"))
        presentReview()
        await settle()
        debugSheetSnapshot(to: dir.appending(path: "review-users.png"))
        let sheet = ReviewSheet.make(items: basket.items, unchecked: [], protected: driveController?.protectedHits ?? [],
                                     driveName: ui?.driveName ?? "", driveConnected: true)
        for row in sheet.rows {
            debugLog.info("debug-basket: row \(row.path, privacy: .public) checkable \(row.isCheckable) \(row.instruction ?? row.explanation, privacy: .public)")
        }
        debugCloseReview()
    }
    #endif

    // MARK: Close

    func windowWillClose(_ notification: Notification) {
        if QLPreviewPanel.sharedPreviewPanelExists(), let panel = QLPreviewPanel.shared(), panel.isVisible,
           panel.dataSource === self {
            panel.orderOut(nil)
        }
        if let keyMonitor { NSEvent.removeMonitor(keyMonitor) }
        keyMonitor = nil
        if let displayObserver { NSWorkspace.shared.notificationCenter.removeObserver(displayObserver) }
        displayObserver = nil
        subscriptions.removeAll()
        model?.close()
        window?.contentView = nil
        model = nil
        ui = nil
        mapView = nil
        dragState = nil
        onClose?()
    }
}

extension MapWindowController: @preconcurrency QLPreviewPanelDataSource {
    func numberOfPreviewItems(in panel: QLPreviewPanel!) -> Int {
        previewURL == nil ? 0 : 1
    }

    func previewPanel(_ panel: QLPreviewPanel!, previewItemAt index: Int) -> (any QLPreviewItem)! {
        previewURL as NSURL?
    }
}
