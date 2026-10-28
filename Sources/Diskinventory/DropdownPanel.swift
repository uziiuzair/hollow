import AppKit
import SwiftUI

/// Hosting view that reports content size changes so the panel can follow.
final class FittingHostingView<Content: View>: NSHostingView<Content> {
    var onSizeChange: (() -> Void)?

    override func invalidateIntrinsicContentSize() {
        super.invalidateIntrinsicContentSize()
        onSizeChange?()
    }
}

/// Borderless popover-like panel that hangs under the status item.
@MainActor
final class DropdownPanel: NSPanel {
    static let width: CGFloat = 340
    private static let cornerRadius: CGFloat = 10

    /// Called after the panel hides itself (Esc, resigning key).
    var onDismiss: (() -> Void)?
    var closesOnResign = true
    private let hosting: FittingHostingView<AnyView>

    init(rootView: some View) {
        hosting = FittingHostingView(rootView: AnyView(rootView))
        let container = NSView()
        container.wantsLayer = true
        container.layer?.cornerRadius = Self.cornerRadius
        container.layer?.cornerCurve = .continuous
        container.layer?.masksToBounds = true
        hosting.translatesAutoresizingMaskIntoConstraints = false
        container.addSubview(hosting)
        NSLayoutConstraint.activate([
            hosting.leadingAnchor.constraint(equalTo: container.leadingAnchor),
            hosting.trailingAnchor.constraint(equalTo: container.trailingAnchor),
            hosting.topAnchor.constraint(equalTo: container.topAnchor),
            hosting.bottomAnchor.constraint(equalTo: container.bottomAnchor),
        ])
        super.init(contentRect: NSRect(x: 0, y: 0, width: Self.width, height: 300),
                   styleMask: [.borderless, .nonactivatingPanel], backing: .buffered, defer: true)
        contentView = container
        isOpaque = false
        backgroundColor = .clear
        hasShadow = true
        level = .popUpMenu
        hidesOnDeactivate = true
        isReleasedWhenClosed = false
        collectionBehavior = [.canJoinAllSpaces, .fullScreenAuxiliary]
        hosting.onSizeChange = { [weak self] in
            DispatchQueue.main.async { self?.fitHeight() }
        }
    }

    override var canBecomeKey: Bool { true }

    override func resignKey() {
        super.resignKey()
        if closesOnResign { dismiss() }
    }

    override func cancelOperation(_ sender: Any?) { dismiss() }

    func dismiss() {
        guard isVisible else { return }
        orderOut(nil)
        onDismiss?()
    }

    /// Resizes to the content, keeping the top edge where it is.
    func fitHeight() {
        let height = hosting.fittingSize.height
        guard height > 0, abs(height - frame.height) > 0.5 else { return }
        var f = frame
        f.origin.y = f.maxY - height
        f.size = NSSize(width: Self.width, height: height)
        setFrame(f, display: true)
        invalidateShadow()
    }

    /// Right edge on `anchor`'s right edge (screen coordinates), just below its bottom; clamped to the screen.
    func show(below anchor: NSRect?) {
        fitHeight()
        let screen = NSScreen.screens.first { anchor.map($0.frame.intersects) ?? false } ?? NSScreen.screens.first
        let visible = screen?.visibleFrame ?? NSRect(x: 0, y: 0, width: 1440, height: 900)
        let height = max(frame.height, hosting.fittingSize.height)
        var x = (anchor?.maxX ?? visible.maxX - 8) - Self.width
        let top = (anchor?.minY ?? visible.maxY) - 4
        x = min(max(x, visible.minX + 4), visible.maxX - Self.width - 4)
        setFrame(NSRect(x: x, y: top - height, width: Self.width, height: height), display: true)
        makeKeyAndOrderFront(nil)
        invalidateShadow()
    }
}
