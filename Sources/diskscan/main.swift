import Darwin
import DiskEngine
import Foundation

// diskscan <path> [--top N]
var arguments = Array(CommandLine.arguments.dropFirst())
var top = 10
if let flag = arguments.firstIndex(of: "--top"), flag + 1 < arguments.count, let n = Int(arguments[flag + 1]) {
    top = n
    arguments.removeSubrange(flag...(flag + 1))
}
guard let target = arguments.first else {
    FileHandle.standardError.write(Data("usage: diskscan <path> [--top N]\n".utf8))
    exit(2)
}

func gb(_ bytes: UInt64) -> String { String(format: "%.1f GB", Double(bytes) / 1_000_000_000) }
func mb(_ bytes: UInt64) -> String { String(format: "%.1f MB", Double(bytes) / 1_000_000) }

let root = URL(filePath: (target as NSString).expandingTildeInPath)
let storage = FileManager.default.temporaryDirectory.appending(path: "diskscan-\(UUID().uuidString)")
try FileManager.default.createDirectory(at: storage, withIntermediateDirectories: true)
defer { try? FileManager.default.removeItem(at: storage) }

let result = try await DiskScanner(root: root, storage: storage).run()
let index = result.index
let rootRecord = index.folders[0]
let smallFiles = index.folders.reduce(0) { $0 + Int($1.smallFileCount) }

var usage = rusage()
getrusage(RUSAGE_SELF, &usage)
let peak = UInt64(usage.ru_maxrss) // bytes on macOS

let seconds = Double(result.elapsed.components.seconds) + Double(result.elapsed.components.attoseconds) / 1e18
print("path:               \(root.path)")
print("elapsed:            \(String(format: "%.1f s", seconds))")
print("folders:            \(index.folders.count)")
print("stored files:       \(index.files.count)")
print("small files:        \(smallFiles)")
print("total allocated:    \(gb(rootRecord.totalAllocated))")
print("unreadable folders: \(result.unreadableFolders)")
print("peak memory:        \(mb(peak))")
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
