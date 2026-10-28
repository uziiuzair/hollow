import AppKit
import DiskApp
import MetalKit

/// The treemap's surface: a paused MTKView that redraws on change. Reports the pointer in
/// top-left-origin points and re-shows the snapshot when dark or light mode changes.
final class TreemapMTKView: MTKView {
    var onHover: ((CGPoint?) -> Void)?
    var onClick: ((CGPoint) -> Void)?
    var onResize: ((CGSize) -> Void)?

    private(set) var renderer: TreemapRenderer?
    private var snapshot: MapSnapshot?
    private var tracking: NSTrackingArea?

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
        var color = NSColor.windowBackgroundColor
        effectiveAppearance.performAsCurrentDrawingAppearance {
            color = NSColor.windowBackgroundColor.usingColorSpace(.sRGB) ?? color
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
        let p = point(event)
        if bounds.contains(p) { onClick?(p) }
    }
}
