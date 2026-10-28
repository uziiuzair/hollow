import AppKit
import DiskApp
import DiskEngine
import SwiftUI

/// Where the review sheet is: checking the list, moving, or showing what happened.
enum ReviewPhase: Equatable {
    case review, moving, done(TrashOutcome)
}

/// The window's own UI state: the search field and command list, and the drive chip.
@MainActor
final class MapWindowState: ObservableObject {
    @Published var query = "" { didSet { if query != oldValue { commandIndex = 0 } } }
    @Published var searchFocused = false
    /// Bumped to move focus into or out of the search field.
    @Published var focusRequest = 0
    @Published var blurRequest = 0
    @Published var commandIndex = 0
    @Published var free: String?
    @Published var reviewShown = false
    @Published var reviewPhase = ReviewPhase.review

    let driveName: String
    @Published var tint: Color
    let isInternal: Bool
    /// This drive's basket, shared with the dropdown's "Review N GB to clear".
    let basket: Basket

    init(driveName: String, tint: Color, isInternal: Bool, basket: Basket) {
        self.driveName = driveName
        self.tint = tint
        self.isInternal = isInternal
        self.basket = basket
    }

    /// The command list for the current query and selection.
    func commands(_ model: MapModel) -> [CommandItem] {
        guard let snapshot = model.snapshot else {
            return MapCommands.items(query: query, hasSelection: false, canZoomOut: !model.zoomPath.isEmpty, children: [])
        }
        let top = 0..<snapshot.layout.topLevelCount
        let realSelection = model.selected.map { snapshot.nodes[$0].kind != nil } ?? false
        let children = top.filter { snapshot.nodes[$0].kind != nil }.map { (name: snapshot.nodes[$0].name, key: snapshot.nodes[$0].key) }
        return MapCommands.items(query: query, hasSelection: realSelection, canZoomOut: !model.zoomPath.isEmpty, children: children,
                                 canAddToBasket: canAddSelection(model))
    }

    /// What map rect `rect` would put in the basket, or nil for a bucket or the root.
    func basketItem(_ model: MapModel, rect: Int) -> BasketItem? {
        model.snapshot?.basketItem(at: rect)
    }

    /// The selection is a real item that is not already in the basket (itself or inside a folder there).
    func canAddSelection(_ model: MapModel) -> Bool {
        guard let selected = model.selected, let item = basketItem(model, rect: selected) else { return false }
        return basket.accepts(item)
    }
}

/// What the window's buttons do; the controller supplies them.
struct MapWindowActions {
    var run: (MapAction) -> Void
    var zoomIn: () -> Void
    var quickLook: () -> Void
    var openCommands: () -> Void
    var addToBasket: () -> Void
    /// A press moving a block or list row; `drop` ends it.
    var drag: (BasketDrag) -> Void
    var drop: (BasketDrag) -> Void
    var review: () -> Void
    /// The review sheet's move, and the drive's app-managed hits it may never move.
    var trash: ([BasketItem]) async -> TrashOutcome
    var protected: () -> [LensHit]
}

/// Colors from the approved flat mockup, on the native window background.
private enum Tokens {
    static let bg = Color(nsColor: .windowBackgroundColor)
    static let line = Color(nsColor: .separatorColor)
    static let chip = Color.primary.opacity(0.06)
    static let small = Color(nsColor: .labelColor).opacity(0.22)

    static func kind(_ kind: ContentKind?) -> Color { kind.map(Palette.color) ?? small }

    static func symbol(_ kind: ContentKind?) -> String {
        switch kind {
        case .apps: "square.grid.2x2.fill"
        case .virtualMachines: "shippingbox.fill"
        case .developer: "hammer.fill"
        case .media: "photo.fill"
        case .documents: "doc.text.fill"
        case .appData: "archivebox.fill"
        case .caches: "arrow.clockwise"
        case .other: "doc.fill"
        case nil: "square.grid.3x3.fill"
        }
    }
}

private struct KeyBadge: View {
    let text: String
    var body: some View {
        Text(text)
            .font(.system(size: 11, weight: .medium))
            .padding(.horizontal, 6).padding(.vertical, 1)
            .background(Tokens.chip, in: RoundedRectangle(cornerRadius: 5))
            .overlay(RoundedRectangle(cornerRadius: 5).strokeBorder(Tokens.line, lineWidth: 0.5))
    }
}

struct MapWindowView: View {
    @ObservedObject var model: MapModel
    @ObservedObject var ui: MapWindowState
    @ObservedObject var basket: Basket
    let pointer: MapPointer
    let dragState: BasketDragState
    let mapView: TreemapMTKView?
    let actions: MapWindowActions

    @FocusState private var searchFocus: Bool

    /// The window content's coordinate space, top-left origin: drags and the basket bar's frame are measured in it.
    nonisolated static let space = "mapWindow"

    var body: some View {
        VStack(spacing: 0) {
            toolbar
            Rectangle().fill(Tokens.line).frame(height: 0.5)
            GeometryReader { geo in
                HStack(spacing: 0) {
                    mapArea
                    Rectangle().fill(Tokens.line).frame(width: 0.5)
                    SideList(model: model, tint: ui.tint, drag: actions.drag, drop: actions.drop)
                        .frame(width: MapWindowLayout.listWidth(windowWidth: geo.size.width))
                }
            }
            Rectangle().fill(Tokens.line).frame(height: 0.5)
            keyBar
        }
        .overlay(alignment: .topTrailing) {
            let items = ui.searchFocused ? ui.commands(model) : []
            if ui.searchFocused, !items.isEmpty || !ui.query.isEmpty {
                CommandList(items: items, highlighted: ui.commandIndex, tint: ui.tint, run: actions.run)
                    .padding(.top, 46).padding(.trailing, 14)
            }
        }
        .font(.system(size: 13))
        .background(Tokens.bg)
        .coordinateSpace(name: Self.space)
        .ignoresSafeArea()
        .sheet(isPresented: $ui.reviewShown) {
            ReviewSheetView(basket: basket, phase: $ui.reviewPhase, protected: actions.protected, driveName: ui.driveName,
                            driveConnected: model.status != .offline, move: actions.trash,
                            close: { ui.reviewShown = false })
        }
        .onChange(of: searchFocus) { _, focused in ui.searchFocused = focused }
        .onChange(of: ui.focusRequest) { _, _ in searchFocus = true }
        .onChange(of: ui.blurRequest) { _, _ in searchFocus = false }
    }

    // MARK: Toolbar

    private var toolbar: some View {
        HStack(spacing: 10) {
            driveChip
            breadcrumb
            Spacer(minLength: 10)
            searchField
        }
        .padding(.leading, 78).padding(.trailing, 14)
        .frame(height: 52)
    }

    private var driveChip: some View {
        Button { model.zoom(to: nil) } label: {
            HStack(spacing: 7) {
                RoundedRectangle(cornerRadius: 5).fill(ui.tint)
                    .frame(width: 20, height: 20)
                    .overlay(Image(systemName: ui.isInternal ? "internaldrive" : "externaldrive")
                        .font(.system(size: 11, weight: .semibold)).foregroundStyle(.white))
                Text(ui.driveName).fontWeight(.semibold).lineLimit(1)
                if let free = ui.free {
                    Text(free).fontWeight(.medium).foregroundStyle(.secondary).monospacedDigit().lineLimit(1)
                }
            }
            .padding(.leading, 6).padding(.trailing, 10).padding(.vertical, 5)
            .background(ui.tint.opacity(0.22), in: RoundedRectangle(cornerRadius: 6))
            .contentShape(RoundedRectangle(cornerRadius: 6))
        }
        .buttonStyle(.plain)
        .fixedSize()
        .help("Zoom to the top of \(ui.driveName)")
    }

    private var breadcrumb: some View {
        let crumbs = model.snapshot?.crumbs ?? []
        let current = crumbs.last?.path
        let items = MapWindowLayout.crumbItems(crumbs)
        return HStack(spacing: 2) {
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                if i > 0 { Text("›").foregroundStyle(.secondary) }
                switch item {
                case .collapsed(let early):
                    Menu {
                        ForEach(early, id: \.path) { crumb in
                            Button(crumb.name) { model.zoom(to: crumb) }
                        }
                    } label: { Text("…") }
                    .menuStyle(.borderlessButton).menuIndicator(.hidden).fixedSize()
                    .padding(.horizontal, 7).padding(.vertical, 4)
                case .crumb(let crumb):
                    let isCurrent = crumb.path == current
                    Button { model.zoom(to: crumb) } label: {
                        Text(crumb.name)
                            .fontWeight(isCurrent ? .semibold : .regular)
                            .foregroundStyle(isCurrent ? .primary : .secondary)
                            .lineLimit(1).truncationMode(.middle)
                            .padding(.horizontal, 7).padding(.vertical, 4)
                            .background(isCurrent ? Tokens.chip : .clear, in: RoundedRectangle(cornerRadius: 5))
                            .contentShape(RoundedRectangle(cornerRadius: 5))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
        .lineLimit(1)
    }

    private var searchField: some View {
        HStack(spacing: 6) {
            Image(systemName: "magnifyingglass").foregroundStyle(.secondary)
            TextField("Search files or type a command", text: $ui.query)
                .textFieldStyle(.plain)
                .focused($searchFocus)
            KeyBadge(text: "⌘K").foregroundStyle(.secondary)
        }
        .padding(.leading, 9).padding(.trailing, 6).padding(.vertical, 6)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: 6))
        .frame(width: 260)
    }

    // MARK: Map

    private var mapArea: some View {
        ZStack {
            if let mapView {
                TreemapView(view: mapView, model: model, pointer: pointer, onDrag: actions.drag, onDrop: actions.drop)
                    .opacity(model.snapshot == nil ? 0 : 1)
                    .overlay { HoverCardOverlay(model: model, pointer: pointer) }
            } else {
                Text("This Mac can’t draw the map: no Metal device.").foregroundStyle(.secondary)
            }
            if let message = model.statusMessage {
                Text(message)
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
        }
        .padding(10)
        .overlay(alignment: .bottom) {
            BasketBar(basket: basket, dragState: dragState, clear: { basket.clear() }, review: actions.review)
                .padding(.horizontal, 16).padding(.bottom, 12)
        }
    }

    // MARK: Key bar

    private var keyBar: some View {
        let snapshot = model.snapshot
        let node = model.selected.flatMap { i in snapshot?.nodes.indices.contains(i) == true ? snapshot?.nodes[i] : nil }
        let canZoom = node?.isFolder ?? false
        return HStack(spacing: 16) {
            if let node {
                HStack(spacing: 8) {
                    RoundedRectangle(cornerRadius: 2).fill(Tokens.kind(node.kind)).frame(width: 10, height: 10)
                    Text(node.name).fontWeight(.semibold).foregroundStyle(.primary).lineLimit(1).truncationMode(.middle)
                }
            }
            Spacer(minLength: 16)
            keyButton("Zoom in", "↵", primary: canZoom, action: actions.zoomIn)
                .opacity(canZoom ? 1 : 0.5).disabled(!canZoom)
            keyButton("Quick Look", "Space", primary: false, action: actions.quickLook)
            let canAdd = ui.canAddSelection(model)
            keyButton("Add to basket", "⌫", primary: false, action: actions.addToBasket)
                .opacity(canAdd ? 1 : 0.5).disabled(!canAdd)
            keyButton("Actions", "⌘K", primary: false, action: actions.openCommands)
        }
        .font(.system(size: 12))
        .foregroundStyle(.secondary)
        .padding(.horizontal, 14)
        .frame(height: 40)
    }

    private func keyButton(_ title: String, _ key: String, primary: Bool, action: @escaping () -> Void) -> some View {
        Button(action: action) {
            HStack(spacing: 6) {
                Text(title).foregroundStyle(primary ? .primary : .secondary)
                KeyBadge(text: key).foregroundStyle(.secondary)
            }
            .contentShape(Rectangle())
        }
        .buttonStyle(.plain)
    }
}

// MARK: - Side list

private struct SideList: View {
    @ObservedObject var model: MapModel
    let tint: Color
    let drag: (BasketDrag) -> Void
    let drop: (BasketDrag) -> Void
    @State private var rowDrag: BasketDrag?

    var body: some View {
        let snapshot = model.snapshot
        let hoveredTop = model.hovered.flatMap { h in
            snapshot.flatMap { $0.layout.rects.indices.contains(h) ? $0.layout.topLevel(of: h) : nil }
        }
        VStack(alignment: .leading, spacing: 0) {
            if let snapshot {
                HStack {
                    Text(snapshot.crumbs.last?.name ?? model.driveName).lineLimit(1)
                    Spacer(minLength: 8)
                    Text(Format.gb(snapshot.total)).monospacedDigit()
                }
                .font(.system(size: 12))
                .foregroundStyle(.secondary)
                .padding(.horizontal, 8).padding(.top, 4).padding(.bottom, 8)
                ScrollView {
                    LazyVStack(spacing: 0) {
                        ForEach(Array(snapshot.list.enumerated()), id: \.offset) { _, row in
                            ListRowView(row: row, selected: row.node != nil && row.node == model.selected,
                                        hovered: row.node != nil && row.node == hoveredTop, tint: tint)
                                .onHover { inside in
                                    if inside { model.hovered = row.node }
                                    else if model.hovered == row.node { model.hovered = nil }
                                }
                                .onTapGesture { if let node = row.node { model.select(node) } }
                                // Rows without a node (the remainder, unreadable folders) can't be dragged (C21).
                                .gesture(rowDragGesture(row.node ?? -1), including: row.node == nil ? .none : .all)
                        }
                    }
                }
                .scrollIndicators(.never)
            }
            Spacer(minLength: 0)
        }
        .padding(.vertical, 10).padding(.horizontal, 8)
    }

    /// A press on row `node`, keyed by the node it shows now.
    private func press(at point: CGPoint, node: Int) -> BasketDrag {
        let key = model.snapshot.flatMap { $0.nodes.indices.contains(node) ? $0.nodes[node].key : nil }
        return BasketDrag(at: point, item: node, key: key)
    }

    /// Feeds the same drag the map's blocks do, in the window's coordinate space.
    private func rowDragGesture(_ node: Int) -> some Gesture {
        DragGesture(minimumDistance: BasketDrag.threshold, coordinateSpace: .named(MapWindowView.space))
            .onChanged { value in
                var d = rowDrag.flatMap { $0.item == node ? $0 : nil } ?? press(at: value.startLocation, node: node)
                d.move(to: value.location)
                rowDrag = d
                drag(d)
            }
            .onEnded { value in
                var d = rowDrag.flatMap { $0.item == node ? $0 : nil } ?? press(at: value.startLocation, node: node)
                d.move(to: value.location)
                rowDrag = nil
                drop(d)
            }
    }
}

private struct ListRowView: View {
    let row: ListRow
    let selected: Bool
    let hovered: Bool
    let tint: Color

    var body: some View {
        let color = Tokens.kind(row.kind)
        VStack(spacing: 5) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 10, height: 10)
                    .frame(width: 18, alignment: .leading)
                Text(row.name).lineLimit(1).truncationMode(.middle)
                Spacer(minLength: 8)
                Text(Format.gb(row.size)).monospacedDigit()
                    .foregroundStyle(selected ? .primary : .secondary)
            }
            GeometryReader { geo in
                ZStack(alignment: .leading) {
                    RoundedRectangle(cornerRadius: 2).fill(Tokens.chip)
                    RoundedRectangle(cornerRadius: 2).fill(color)
                        .frame(width: geo.size.width * min(max(row.fraction, 0), 1))
                }
            }
            .frame(height: 3)
            .padding(.leading, 27)
        }
        .padding(.horizontal, 8).padding(.vertical, 7)
        .background(selected ? tint.opacity(0.26) : hovered ? Tokens.chip : .clear,
                    in: RoundedRectangle(cornerRadius: 5))
        .contentShape(Rectangle())
    }
}

// MARK: - Hover card

private struct CardSizeKey: PreferenceKey {
    static let defaultValue: CGSize = .zero
    static func reduce(value: inout CGSize, nextValue: () -> CGSize) { value = nextValue() }
}

private struct HoverCardOverlay: View {
    @ObservedObject var model: MapModel
    @ObservedObject var pointer: MapPointer
    @State private var cardSize = CGSize(width: 236, height: 80)

    var body: some View {
        GeometryReader { geo in
            if let p = pointer.location, let hovered = model.hovered, let snapshot = model.snapshot,
               snapshot.nodes.indices.contains(hovered) {
                let node = snapshot.nodes[hovered]
                let card = HoverCard.make(node: node, size: snapshot.layout.rects[hovered].size, period: snapshot.period)
                let origin = MapWindowLayout.cardOrigin(pointer: p, card: cardSize, in: geo.size)
                HoverCardView(card: card, kind: node.kind)
                    .background(GeometryReader { Color.clear.preference(key: CardSizeKey.self, value: $0.size) })
                    .offset(x: origin.x, y: origin.y)
            }
        }
        .onPreferenceChange(CardSizeKey.self) { cardSize = $0 }
        .allowsHitTesting(false)
    }
}

private struct HoverCardView: View {
    let card: HoverCard
    let kind: ContentKind?

    var body: some View {
        VStack(alignment: .leading, spacing: 6) {
            HStack(spacing: 9) {
                RoundedRectangle(cornerRadius: 6).fill(Tokens.kind(kind))
                    .frame(width: 28, height: 28)
                    .overlay(Image(systemName: Tokens.symbol(kind))
                        .font(.system(size: 13, weight: .semibold)).foregroundStyle(.white))
                VStack(alignment: .leading, spacing: 1) {
                    Text(card.title).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                    detailLine.font(.system(size: 12)).lineLimit(1)
                }
            }
            if let explanation = card.explanation {
                Text(explanation)
                    .font(.system(size: 12)).foregroundStyle(.secondary)
                    .lineSpacing(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
        }
        .padding(12)
        .frame(width: 236, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }

    private var detailLine: Text {
        let detail = Text(card.detail).foregroundStyle(.secondary)
        guard let change = card.change else { return detail }
        return detail + Text(", ").foregroundStyle(.secondary)
            + Text(change).fontWeight(.semibold).foregroundStyle(card.changeIsGrowth ? Palette.growth : Palette.freed)
    }
}

// MARK: - Command list

private struct CommandList: View {
    let items: [CommandItem]
    let highlighted: Int
    let tint: Color
    let run: (MapAction) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 0) {
            if items.isEmpty {
                Text("No matching commands").foregroundStyle(.secondary)
                    .padding(.horizontal, 10).padding(.vertical, 6)
            }
            ForEach(Array(items.enumerated()), id: \.offset) { i, item in
                Button { run(item.action) } label: {
                    HStack {
                        Text(item.title).lineLimit(1).truncationMode(.middle)
                        Spacer(minLength: 8)
                        if let shortcut = item.shortcut { KeyBadge(text: shortcut).foregroundStyle(.secondary) }
                    }
                    .padding(.horizontal, 10).padding(.vertical, 6)
                    .background(i == highlighted ? tint.opacity(0.26) : .clear, in: RoundedRectangle(cornerRadius: 5))
                    .contentShape(Rectangle())
                }
                .buttonStyle(.plain)
            }
        }
        .padding(6)
        .frame(width: 320, alignment: .leading)
        .background(.regularMaterial, in: RoundedRectangle(cornerRadius: 8))
        .overlay(RoundedRectangle(cornerRadius: 8).strokeBorder(Tokens.line, lineWidth: 0.5))
        .shadow(color: .black.opacity(0.25), radius: 16, y: 8)
    }
}
