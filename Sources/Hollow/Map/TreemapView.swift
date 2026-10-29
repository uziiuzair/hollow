import AppKit
import Combine
import DiskApp
import SwiftUI

/// Where the pointer is over the map, in map points; nil outside. Kept apart from
/// `MapWindowState` so a mouse move redraws only the hover card.
@MainActor
final class MapPointer: ObservableObject {
    @Published var location: CGPoint?
}

/// Hosts the window's `TreemapMTKView` and wires it to the model: hover, click, resize,
/// new snapshots and the highlight.
struct TreemapView: NSViewRepresentable {
    let view: TreemapMTKView
    let model: MapModel
    let pointer: MapPointer
    let onDrag: (BasketDrag) -> Void
    let onDrop: (BasketDrag) -> Void

    func makeCoordinator() -> Coordinator { Coordinator() }

    func makeNSView(context: Context) -> TreemapMTKView {
        context.coordinator.attach(view: view, model: model, pointer: pointer)
        view.onDrag = onDrag
        view.onDrop = onDrop
        return view
    }

    func updateNSView(_ nsView: TreemapMTKView, context: Context) {}

    static func dismantleNSView(_ nsView: TreemapMTKView, coordinator: Coordinator) {
        coordinator.detach(nsView)
    }

    @MainActor
    final class Coordinator {
        private var subscriptions: Set<AnyCancellable> = []

        func attach(view: TreemapMTKView, model: MapModel, pointer: MapPointer) {
            view.onHover = { [weak model, weak pointer] p in
                pointer?.location = p
                guard let model else { return }
                let hit = p.flatMap { model.snapshot?.layout.hitTest($0) }
                if model.hovered != hit { model.hovered = hit }
            }
            view.onClick = { [weak model] p in
                guard let model, let snapshot = model.snapshot, let hit = snapshot.layout.hitTest(p) else { return }
                let top = snapshot.layout.topLevel(of: hit)
                model.select(top)
            }
            view.onDoubleClick = { [weak model] p in
                guard let model, let snapshot = model.snapshot, let hit = snapshot.layout.hitTest(p) else { return }
                let top = snapshot.layout.topLevel(of: hit)
                // The view sends a double-click only for the second click, and never for a drag.
                if MapClick.opensFolder(clickCount: 2, isFolder: snapshot.nodes[top].isFolder) {
                    model.zoomIn(top)
                }
            }
            view.onResize = { [weak model] size in model?.setSize(size) }

            // C5: read the model after the change has landed, not on willSet.
            model.$snapshot
                .receive(on: DispatchQueue.main)
                .sink { [weak view, weak model] snapshot in
                    guard let view, let model, let snapshot else { return }
                    view.show(snapshot, animation: model.animation)
                    Self.highlight(view, model)
                }
                .store(in: &subscriptions)
            Publishers.Merge(model.$hovered.map { _ in () }, model.$selected.map { _ in () })
                .receive(on: DispatchQueue.main)
                .sink { [weak view, weak model] in
                    guard let view, let model else { return }
                    Self.highlight(view, model)
                }
                .store(in: &subscriptions)
        }

        func detach(_ view: TreemapMTKView) {
            subscriptions.removeAll()
            view.onHover = nil
            view.onClick = nil
            view.onDoubleClick = nil
            view.onContextMenu = nil
            view.onBack = nil
            view.onResize = nil
            view.onDrag = nil
            view.onDrop = nil
        }

        private static func highlight(_ view: TreemapMTKView, _ model: MapModel) {
            var hoveredTop: Int?
            if let hovered = model.hovered, let layout = model.snapshot?.layout, layout.rects.indices.contains(hovered) {
                hoveredTop = layout.topLevel(of: hovered)
            }
            view.setHighlight(hoveredTop: hoveredTop, outlinedTop: model.outlinedTop)
        }
    }
}
