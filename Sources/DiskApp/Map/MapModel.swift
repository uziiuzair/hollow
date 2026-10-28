import CoreGraphics
import DiskEngine
import Foundation

/// Where the map window gets its maps: a drive it can hold warm while the window is open.
@MainActor
public protocol MapSource: AnyObject {
    var activity: DriveActivity { get }
    var period: Int { get }
    func hold() async
    func release()
    /// Nil while the drive is cold, scanning or gone.
    func buildMap(_ request: MapRequest) async -> MapSnapshot?
}

public enum MapStatus: Equatable, Sendable {
    case loading, scanning, ready, empty, offline
}

/// The map window's state: which level is shown, what is selected, and the snapshot
/// that draws it. Builds run off main in the source; at most one is in flight.
@MainActor
public final class MapModel: ObservableObject {
    @Published public private(set) var snapshot: MapSnapshot?
    @Published public private(set) var status: MapStatus = .loading
    @Published public private(set) var zoomPath = ""
    /// A depth-1 rect index.
    @Published public private(set) var selected: Int?
    /// Set together with the snapshot that answers a zoom; nil otherwise and with Reduce Motion.
    @Published public private(set) var animation: ZoomAnimation?
    /// Any rect index.
    @Published public var hovered: Int?
    public var reduceMotion: Bool
    /// False while the window is occluded or minimized: source changes then only mark the map stale, and showing the
    /// window again builds once if they did.
    public var isVisible = true {
        didSet {
            guard isVisible, !oldValue, staleWhileHidden else { return }
            staleWhileHidden = false
            lastSourceBuild = clock.now
            requestBuild()
        }
    }

    public let driveName: String
    private var source: any MapSource
    private let throttle: Duration
    private let clock = ContinuousClock()

    private var size: CGSize = .zero
    private var isOpen = false
    /// Bumped by open() and close(), so an open that outlives its close stops.
    private var session = 0
    /// Kept by key so the selection survives rebuilds.
    private var selectedKey: String?
    private var pendingZoom: PendingZoom?
    /// Set by driveDisconnected(): the window still shows "<name> was disconnected" and may reattach.
    private var disconnected = false
    /// True from driveDisconnected() until a reattach or reopen.
    public var isDisconnected: Bool { disconnected }

    /// The id of the latest request; only a build answering it is applied.
    private var latest = 0
    private var inFlight: Task<Void, Never>?
    private var dirty = false

    /// Only sourceChanged() builds count toward the throttle window.
    private var lastSourceBuild: ContinuousClock.Instant?
    private var trailing: Task<Void, Never>?
    /// Bytes changed at or under the zoomed folder since the last build, too few so far to move 1 pt² of the map.
    private var pendingBytes: UInt64 = 0
    /// A source change wanted a build while the window was hidden.
    private var staleWhileHidden = false

    private enum PendingZoom {
        case into(from: CGRect, bounds: CGRect)
        /// Out of the folder with this key, found in the new level once it is built.
        case outOf(key: String)
    }

    public init(source: any MapSource, driveName: String, reduceMotion: Bool, throttle: Duration = .seconds(1)) {
        self.source = source
        self.driveName = driveName
        self.reduceMotion = reduceMotion
        self.throttle = throttle
    }

    public var statusMessage: String? {
        switch status {
        case .loading: "Loading the map…"
        case .scanning: "Scanning this drive for the first time. The map appears when the scan finishes."
        case .offline: "\(driveName) was disconnected. Its map comes back when you plug it in."
        case .empty: "Nothing here takes up space."
        case .ready: nil
        }
    }

    /// The top-level block to outline: the hovered one's, else the selected one.
    public var outlinedTop: Int? {
        if let hovered, let layout = snapshot?.layout, layout.rects.indices.contains(hovered) {
            return layout.topLevel(of: hovered)
        }
        return selected
    }

    /// Holds the source, then builds `path` with the item `key` selected (if it is a
    /// depth-1 block there).
    public func open(path: String, select key: String?) async {
        zoomPath = path
        selectedKey = key
        selected = nil
        pendingZoom = nil
        // A reopen over a visible map keeps it until the new build lands.
        if snapshot == nil { status = Self.coldStatus(source.activity) }
        if !isOpen {
            isOpen = true
            disconnected = false
            session += 1
            let mine = session
            await source.hold()
            guard isOpen, session == mine else { return }
        }
        requestBuild()
    }

    /// Before open() this only stores the size.
    public func setSize(_ newSize: CGSize) {
        guard newSize != size else { return }
        size = newSize
        requestBuild()
    }

    /// The drive changed (an update, its activity or period). Builds at once, then at most once more per throttle
    /// window. `change` (an index update) skips the build while what it changed inside the zoomed folder adds up to
    /// less than 1 pt² of the map; nil always builds.
    public func sourceChanged(_ change: IndexChange? = nil) {
        guard isOpen else { return }
        if let delta = Self.visibleDelta(change, zoomPath: zoomPath) {
            pendingBytes &+= delta
            let total = Double(max(snapshot?.total ?? 0, 1))
            guard Double(pendingBytes) * Double(size.width) * Double(size.height) / total >= 1 else { return }
        }
        guard isVisible else { staleWhileHidden = true; return }
        guard trailing == nil else { return }
        let now = clock.now
        if let last = lastSourceBuild, now - last < throttle {
            let due = last + throttle
            trailing = Task { [weak self] in
                try? await Task.sleep(until: due, clock: .continuous)
                guard let self, !Task.isCancelled else { return }
                self.trailing = nil
                self.lastSourceBuild = self.clock.now
                self.requestBuild()
            }
        } else {
            lastSourceBuild = now
            requestBuild()
        }
    }

    /// Zooms into a folder block.
    public func zoomIn(_ rect: Int) {
        guard let snapshot, snapshot.nodes.indices.contains(rect), snapshot.nodes[rect].isFolder else { return }
        pendingZoom = .into(from: snapshot.layout.rects[rect].frame, bounds: snapshot.layout.bounds)
        go(to: snapshot.nodes[rect].key, select: nil)
    }

    /// Zooms to the parent level and selects the folder you came from.
    public func zoomOut() {
        guard !zoomPath.isEmpty else { return }
        zoom(to: Self.parent(of: zoomPath))
    }

    /// Nil is the drive root.
    public func zoom(to crumb: Crumb?) {
        zoom(to: crumb?.path ?? "")
    }

    public func select(_ rect: Int?) {
        guard let rect, let layout = snapshot?.layout, layout.rects.indices.contains(rect) else {
            selected = nil; selectedKey = nil; return
        }
        let top = layout.topLevel(of: rect)
        selected = top
        selectedKey = snapshot?.nodes[top].key
    }

    /// Moves through the depth-1 blocks in layout order (largest first).
    public func moveSelection(by step: Int) {
        guard let count = snapshot?.layout.topLevelCount, count > 0, step != 0 else { return }
        let start = selected ?? (step > 0 ? -1 : count)
        select(min(max(start + step, 0), count - 1))
    }

    /// How many bytes `change` moved at or under `zoomPath` (every path is under ""), or nil when the map must build
    /// anyway: anything may have changed, or a changed folder is a strict ancestor of `zoomPath`.
    nonisolated public static func visibleDelta(_ change: IndexChange?, zoomPath: String) -> UInt64? {
        guard let folders = change?.folders else { return nil }
        var sum: UInt64 = 0
        for (path, delta) in folders {
            if path == zoomPath || zoomPath.isEmpty || path.hasPrefix(zoomPath + "/") {
                sum &+= delta.magnitude
            } else if path.isEmpty || zoomPath.hasPrefix(path + "/") {
                return nil
            }
        }
        return sum
    }

    /// Releases the source and drops the map data.
    public func close() {
        guard isOpen else { return }
        isOpen = false
        session += 1
        latest += 1
        trailing?.cancel(); trailing = nil
        lastSourceBuild = nil
        dirty = false
        pendingBytes = 0
        staleWhileHidden = false
        snapshot = nil
        selected = nil
        hovered = nil
        animation = nil
        pendingZoom = nil
        status = .loading
        source.release()
    }

    /// The drive is being unmounted: lets go of it and drops the map, but keeps saying
    /// "<name> was disconnected" until the window closes. Nothing builds after this.
    public func driveDisconnected() {
        guard isOpen else { return }
        close()
        status = .offline
        disconnected = true
    }

    /// The eject was refused and the drive is still mounted, with a new controller: holds `source` and rebuilds at the
    /// level and selection the window had. Does nothing unless the drive was disconnected (driveDisconnected()).
    public func reattach(to source: any MapSource) async {
        guard disconnected, !isOpen else { return }
        disconnected = false
        self.source = source
        // close() already dropped any trailing build, the dirty flag, the throttle window, the pending tiny changes
        // and the hidden window's stale flag (C22), so this builds at once and nothing old carries over.
        await open(path: zoomPath, select: selectedKey)
    }

    /// Waits until no build is in flight or scheduled.
    func settle() async {
        while true {
            if let trailing { await trailing.value; continue }
            if let inFlight { await inFlight.value; continue }
            return
        }
    }

    // MARK: - Builds

    private func zoom(to path: String) {
        guard path != zoomPath else { return }
        // Going up to an ancestor: select the child of it that we came from.
        var cameFrom: String?
        if path.isEmpty || zoomPath.hasPrefix(path + "/") {
            let rest = zoomPath.dropFirst(path.isEmpty ? 0 : path.count + 1)
            let first = rest.split(separator: "/").first.map(String.init) ?? ""
            cameFrom = path.isEmpty ? first : path + "/" + first
        }
        pendingZoom = cameFrom.map { .outOf(key: $0) }
        go(to: path, select: cameFrom)
    }

    private func go(to path: String, select key: String?) {
        zoomPath = path
        selectedKey = key
        selected = nil
        hovered = nil
        requestBuild()
    }

    private func requestBuild() {
        guard isOpen, size.width > 0, size.height > 0 else { return }
        latest += 1
        if inFlight == nil { startBuild() } else { dirty = true }
    }

    private func startBuild() {
        dirty = false
        pendingBytes = 0
        staleWhileHidden = false
        let id = latest
        let request = MapRequest(path: zoomPath, size: size, period: source.period)
        inFlight = Task { [weak self] in
            guard let source = self?.source else { return }
            let result = await source.buildMap(request)
            self?.finish(id: id, result: result)
        }
    }

    private func finish(id: Int, result: MapSnapshot?) {
        inFlight = nil
        if isOpen, id == latest { apply(result) }
        if isOpen, dirty { startBuild() }
    }

    /// The rect index of `key` in `snapshot`, so a hover survives a live rebuild.
    static func rehover(key: String?, in snapshot: MapSnapshot) -> Int? {
        guard let key else { return nil }
        return snapshot.nodes.firstIndex { $0.key == key }
    }

    private func apply(_ result: MapSnapshot?) {
        // A rebuild of the same level (an update, a resize) keeps the hover while its item exists;
        // a new level drops it.
        let old = snapshot
        // A rebuild that changed nothing (most live updates at idle) publishes nothing, so the
        // window does not rebuild its instances, labels and GPU buffers.
        if let result, let old, result == old, pendingZoom == nil {
            let top = 0..<old.layout.topLevelCount
            let kept = selectedKey.flatMap { key in top.first { old.nodes[$0].key == key } }
            if selected != kept { selected = kept }
            let ready: MapStatus = old.layout.rects.isEmpty ? .empty : .ready
            if status != ready { status = ready }
            return
        }
        let hoveredKey = hovered.flatMap { h in old?.nodes.indices.contains(h) == true ? old?.nodes[h].key : nil }
        hovered = nil
        guard let result else {
            snapshot = nil
            selected = nil
            animation = nil
            status = Self.coldStatus(source.activity)
            return
        }
        let layout = result.layout
        let top = 0..<layout.topLevelCount
        selected = selectedKey.flatMap { key in top.first { result.nodes[$0].key == key } }
        switch pendingZoom {
        case .into(let from, let bounds):
            animation = .zoomIn(from: from, bounds: bounds)
        case .outOf(let key):
            animation = top.first { result.nodes[$0].key == key }
                .map { ZoomAnimation.zoomOut(to: layout.rects[$0].frame, bounds: layout.bounds) }
        case nil:
            animation = nil
        }
        if reduceMotion { animation = nil }
        pendingZoom = nil
        zoomPath = result.path
        snapshot = result
        if old?.path == result.path { hovered = Self.rehover(key: hoveredKey, in: result) }
        status = layout.rects.isEmpty ? .empty : .ready
    }

    private static func coldStatus(_ activity: DriveActivity) -> MapStatus {
        switch activity {
        case .offline: .offline
        case .scanning: .scanning
        case .idle, .opening, .ready: .loading
        }
    }

    private static func parent(of path: String) -> String {
        guard let slash = path.lastIndex(of: "/") else { return "" }
        return String(path[..<slash])
    }
}
