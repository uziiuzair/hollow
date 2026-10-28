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
    private var subscriptions: Set<AnyCancellable> = []
    private var keyMonitor: Any?
    private var displayObserver: NSObjectProtocol?

    init(controller: DriveController, drive: KnownDrive, path: String, select: String?) {
        uuid = drive.uuid
        driveController = controller
        let model = MapModel(source: controller, driveName: drive.name,
                             reduceMotion: NSWorkspace.shared.accessibilityDisplayShouldReduceMotion)
        let ui = MapWindowState(driveName: drive.name,
                                tint: Palette.tints[drive.tintIndex % Palette.tints.count],
                                isInternal: controller.volume.isInternalData)
        self.model = model
        self.ui = ui

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
            openCommands: { [weak self] in self?.ui?.focusRequest += 1 })
        let hosting = NSHostingView(rootView: MapWindowView(model: model, ui: ui, pointer: MapPointer(),
                                                            mapView: mapView, actions: actions))
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
        guard let window, window.isKeyWindow, event.window === window, let model, let ui else { return false }
        let modifiers = KeyModifiers(eventFlags: event.modifierFlags)
        guard let command = MapKey.command(keyCode: event.keyCode, modifiers: modifiers, searchFocused: ui.searchFocused)
        else { return false }
        switch command {
        case .zoomIn: zoomIntoSelection()
        case .zoomOut: model.zoomOut()
        case .quickLook: toggleQuickLook()
        case .openCommands: ui.focusRequest += 1
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
        return true
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
        NSGraphicsContext.restoreGraphicsState()
        try? out.representation(using: .png, properties: [:])?.write(to: url)
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
