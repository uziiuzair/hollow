import Darwin
import DiskEngine
import Foundation

// diskscan <path> [--top N] [--memory] [--hold] [--store <dir>]
var arguments = Array(CommandLine.arguments.dropFirst())
@MainActor func option(_ name: String) -> String? {
    guard let flag = arguments.firstIndex(of: name), flag + 1 < arguments.count else { return nil }
    defer { arguments.removeSubrange(flag...(flag + 1)) }
    return arguments[flag + 1]
}
@MainActor func flag(_ name: String) -> Bool {
    guard let i = arguments.firstIndex(of: name) else { return false }
    arguments.remove(at: i)
    return true
}
let top = option("--top").flatMap(Int.init) ?? 10
let storeOption = option("--store")
let showMemory = flag("--memory")
let hold = flag("--hold")
guard let target = arguments.first else {
    FileHandle.standardError.write(Data("usage: diskscan <path> [--top N] [--memory] [--hold] [--store <dir>]\n".utf8))
    exit(2)
}

func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }
func seconds(_ d: Duration) -> String {
    String(format: "%.2f s", Double(d.components.seconds) + Double(d.components.attoseconds) / 1e18)
}

let root = URL(filePath: (target as NSString).expandingTildeInPath)

// Live mode: open (or build) a persistent index and print changes until Ctrl-C.
if let storeOption {
    let store = URL(filePath: (storeOption as NSString).expandingTildeInPath)
    try FileManager.default.createDirectory(at: store, withIntermediateDirectories: true)
    let live = LiveIndex(volumeRoot: root, store: store)
    let clock = ContinuousClock()
    let started = clock.now
    let opened = try await live.open()
    print("opened:  \(opened) in \(seconds(clock.now - started))")
    print("total:   \(gb(await live.withIndex { $0.folders[0].totalAllocated }))")
    if showMemory { print("footprint: \(mb(MemoryReport.footprint()))") }

    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        Task {
            try? await live.close()
            print("\nsaved and closed")
            exit(0)
        }
    }
    interrupt.resume()

    // Report only changes of 1 MB or more; FSEvents reports background churn constantly.
    var last = await live.withIndex { $0.folders[0].totalAllocated }
    while true {
        try await Task.sleep(for: .seconds(1))
        let now = await live.withIndex { $0.folders[0].totalAllocated }
        let delta = Int64(bitPattern: now &- last)
        if abs(delta) >= 1_000_000 {
            print(String(format: "changes applied: total %@ (%+.3f GB)", gb(now), Double(delta) / 1e9))
            last = now
        }
    }
}
let storage = FileManager.default.temporaryDirectory.appending(path: "diskscan-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: storage) }

let baseline = showMemory ? MemoryReport.footprint() : 0
let result = try await DiskScanner(root: root, storage: storage).run()
let index = result.index
let rootRecord = index.folders[0]
let smallFiles = index.folders.reduce(0) { $0 + Int($1.smallFileCount) }

var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let peak = UInt64(usage.ru_maxrss) // bytes on macOS

print("path:               \(root.path)")
print("elapsed:            \(seconds(result.elapsed))")
print("folders:            \(index.folders.count)")
print("stored files:       \(index.files.count)")
print("small files:        \(smallFiles)")
print("total allocated:    \(gb(rootRecord.totalAllocated))")
print("unreadable folders: \(result.unreadableFolders)")
print("peak memory:        \(mb(peak))")
if showMemory {
    let m = MemoryReport.measure(index)
    print("baseline:           \(mb(baseline))")
    print("footprint now:      \(mb(m.processFootprint))")
    print("  folder table:     \(mb(UInt64(m.folderTableBytes)))")
    print("  folder names:     \(mb(UInt64(m.folderNameBytes)))")
    print("  hard links:       \(mb(UInt64(m.hardLinkBytes)))")
    print("  pending queue:    \(mb(UInt64(m.pendingBytes)))")
    let unexplained = Int64(m.processFootprint) - Int64(baseline) - Int64(m.tablesBytes)
    print("unexplained:        " + String(format: "%.1f MB", Double(unexplained) / 1_000_000))
}
if let space = try? VolumeSpace.read(root) {
    print("volume:             \(gb(space.total)) total, \(gb(space.available)) free, \(gb(space.reclaimable)) reclaimable")
}

print("\nlargest folders under root:")
for child in try index.children(of: 0).filter({ if case .folder = $0.kind { true } else { false } }).prefix(top) {
    print("  \(gb(child.allocated).padding(toLength: 10, withPad: " ", startingAt: 0)) \(child.name)")
}
print("\nlargest files:")
for (file, size) in index.top.sortedDescending().prefix(top) {
    let record = try index.files.record(file)
    print("  \(gb(size).padding(toLength: 10, withPad: " ", startingAt: 0)) \(index.path(of: record.parent, rootPath: root.path))/\(try index.files.name(file))")
}

// --hold: keep the process and its index alive so heap, vmmap or footprint can attach.
if hold {
    print("holding: pid \(getpid()). Attach heap or vmmap now; Ctrl-C exits.")
    fflush(stdout)
    signal(SIGINT, SIG_IGN)
    let interrupt = DispatchSource.makeSignalSource(signal: SIGINT, queue: .main)
    interrupt.setEventHandler {
        try? FileManager.default.removeItem(at: storage) // exit skips the defer above
        exit(0)
    }
    interrupt.resume()
    // dispatchMain traps under async main; sleeping frees the main queue for the signal source.
    while true {
        try await Task.sleep(for: .seconds(3600))
        withExtendedLifetime(index) {}
    }
}
