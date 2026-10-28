import AppKit
import DiskApp
import MetalKit

/// The treemap's surface: a paused MTKView that redraws on change. Reports the pointer in
/// top-left-origin points and re-shows the snapshot when dark or light mode changes.
final class TreemapMTKView: MTKView {
    var onHover: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    /// A second click on the same spot, after `onClick`; never fires for a drag.
    var onDoubleClick: ((CGPoint) -> Void)?
    /// The right-click menu for the block under the point, or nil for none.
    var onContextMenu: ((CGPoint) -> NSMenu?)?
    /// A trackpad swipe back (two fingers, to the right).
    var onBack: (() -> Void)?
    var onResize: ((CGSize) -> Void)?
    /// A press that moved `BasketDrag.threshold` points or more; locations are in the window's content, top-left origin.
    var onDrag: ((BasketDrag) -> Void)?
    var onDrop: ((BasketDrag) -> Void)?

    private(set) var renderer: TreemapRenderer?
    private var snapshot: MapSnapshot?
    private var tracking: NSTrackingArea?
    /// The press in progress, on a block's top-level rect.
    private var drag: BasketDrag?

    init?(device: MTLDevice? = MTLCreateSystemDefaultDevice()) {
        guard let device, let renderer = TreemapRenderer(device: device) else { return nil }
        super.init(frame: .zero, device: device)
        self.renderer = renderer
        delegate = renderer
        colorPixelFormat = .bgra8Unorm
        layer?.isOpaque = false
        (layer as? CAMetalLayer)?.colorspace = CGColorSpace(name: CGColorSpace.sRGB)
        isPaused = true
        enableSetNeedsDisplay = true
        autoResizeDrawable = true
        updateClearColor()
    }

    @available(*, unavailable)
    required init(coder: NSCoder) { fatalError("init(coder:) is not supported") }

    override var isFlipped: Bool { true }

    /// Takes key focus (from the search field too) so the window's keys reach the map.
    override var acceptsFirstResponder: Bool { true }

    /// The first click on a background window lands instead of only activating it.
    override func acceptsFirstMouse(for event: NSEvent?) -> Bool { true }

    override func menu(for event: NSEvent) -> NSMenu? { onContextMenu?(point(event)) }

    override func swipe(with event: NSEvent) {
        if event.deltaX > 0 { onBack?() }
    }

    override func mouseDown(with event: NSEvent) {
        window?.makeFirstResponder(self)
        drag = nil
        guard let snapshot, let hit = snapshot.layout.hitTest(point(event)), let content = contentPoint(event) else { return }
        let top = snapshot.layout.topLevel(of: hit)
        drag = BasketDrag(at: content, item: top, key: snapshot.nodes.indices.contains(top) ? snapshot.nodes[top].key : nil)
    }

    override func mouseDragged(with event: NSEvent) {
        guard var drag, let content = contentPoint(event) else { return }
        drag.move(to: content)
        self.drag = drag
        onDrag?(drag)
    }

    var isDark: Bool { effectiveAppearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua }

    /// Shows `snapshot`, zooming into it when `animation` is given.
    func show(_ snapshot: MapSnapshot, animation: ZoomAnimation?) {
        self.snapshot = snapshot
        renderer?.show(snapshot, dark: isDark, animation: animation, in: self)
    }

    func setHighlight(hoveredTop: Int?, outlinedTop: Int?) {
        renderer?.setHighlight(hoveredTop: hoveredTop, outlinedTop: outlinedTop, in: self)
    }

    private func updateClearColor() {
        // A fixed sRGB fallback: component accessors raise on a catalog color.
        var color = isDark ? NSColor(srgbRed: 0.196, green: 0.196, blue: 0.196, alpha: 1)
                           : NSColor(srgbRed: 0.925, green: 0.925, blue: 0.925, alpha: 1)
        effectiveAppearance.performAsCurrentDrawingAppearance {
            if let resolved = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) { color = resolved }
        }
        clearColor = MTLClearColor(red: Double(color.redComponent), green: Double(color.greenComponent),
                                   blue: Double(color.blueComponent), alpha: Double(color.alphaComponent))
    }

    override func viewDidChangeEffectiveAppearance() {
        super.viewDidChangeEffectiveAppearance()
        updateClearColor()
        if let snapshot { renderer?.show(snapshot, dark: isDark, animation: nil, in: self) }
        needsDisplay = true
    }

    /// Labels are rasterized at the backing scale; re-show after moving between Retina and non-Retina screens.
    override func viewDidChangeBackingProperties() {
        super.viewDidChangeBackingProperties()
        if let snapshot { renderer?.show(snapshot, dark: isDark, animation: nil, in: self) }
    }

    override func setFrameSize(_ newSize: NSSize) {
        let changed = newSize != frame.size
        super.setFrameSize(newSize)
        if changed { onResize?(newSize) }
    }

    override func updateTrackingAreas() {
        super.updateTrackingAreas()
        if let tracking { removeTrackingArea(tracking) }
        let area = NSTrackingArea(rect: bounds, options: [.mouseMoved, .mouseEnteredAndExited, .activeInKeyWindow, .inVisibleRect],
                                  owner: self, userInfo: nil)
        addTrackingArea(area)
        tracking = area
    }

    /// Top-left origin, in points.
    private func point(_ event: NSEvent) -> CGPoint {
        let p = convert(event.locationInWindow, from: nil)
        return isFlipped ? p : CGPoint(x: p.x, y: bounds.height - p.y)
    }

    override func mouseMoved(with event: NSEvent) { onHover?(point(event)) }
    override func mouseExited(with event: NSEvent) { onHover?(nil) }
    override func mouseUp(with event: NSEvent) {
        let press = drag
        drag = nil
        if let press, press.isActive {
            onDrop?(press)
            return
        }
        let p = point(event)
        guard bounds.contains(p) else { return }
        onClick?(p)
        if event.clickCount >= 2 { onDoubleClick?(p) }
    }

    /// The event in the window's content view, top-left origin: the SwiftUI window's "mapWindow" coordinate space.
    private func contentPoint(_ event: NSEvent) -> CGPoint? {
        guard let content = window?.contentView else { return nil }
        let p = content.convert(event.locationInWindow, from: nil)
        return content.isFlipped ? p : CGPoint(x: p.x, y: content.bounds.height - p.y)
    }
}
