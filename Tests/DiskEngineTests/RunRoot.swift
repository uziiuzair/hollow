import Foundation

/// One folder per test process, `<tmp>/DiskinventoryTests/DiskEngineTests-<pid>-<UUID>/`, holding
/// every fixture. It is removed when the process exits; roots left by crashed runs
/// (pid no longer alive) are removed on first use. Nothing outside
/// `<tmp>/DiskinventoryTests/` is ever deleted.
enum RunRoot {
    static let target = "DiskEngineTests"

    static var base: URL {
        FileManager.default.temporaryDirectory.appending(path: "DiskinventoryTests", directoryHint: .isDirectory)
    }

    /// Created, stale-swept and exit-hooked on first access only.
    static let url: URL = {
        let base = RunRoot.base
        try? FileManager.default.createDirectory(at: base, withIntermediateDirectories: true)
        removeStaleRoots(in: base)
        let root = base.appending(path: "\(target)-\(getpid())-\(UUID().uuidString)", directoryHint: .isDirectory)
        try? FileManager.default.createDirectory(at: root, withIntermediateDirectories: true)
        runRootPath = root.path(percentEncoded: false)
        atexit { if let p = runRootPath { RunRoot.removeTree(atPath: p) } }
        return root
    }()

    /// Deletes `<target>-<pid>-<UUID>` folders whose pid is gone.
    private static func removeStaleRoots(in base: URL) {
        let basePath = base.path(percentEncoded: false)
        guard let names = try? FileManager.default.contentsOfDirectory(atPath: basePath) else { return }
        for name in names {
            let parts = name.split(separator: "-", maxSplits: 2, omittingEmptySubsequences: false)
            guard parts.count == 3, let pid = pid_t(parts[1]), pid > 0, pid != getpid() else { continue }
            if kill(pid, 0) == -1 && errno == ESRCH {
                removeTree(atPath: basePath + "/" + name)
            }
        }
    }

    /// Removes a tree without following symlinks, making folders accessible first.
    /// Errors are ignored.
    static func removeTree(atPath path: String) {
        var st = stat()
        guard lstat(path, &st) == 0 else { return }
        guard (st.st_mode & S_IFMT) == S_IFDIR else { unlink(path); return }
        chmod(path, 0o700)
        if let dir = opendir(path) {
            var children: [String] = []
            while let e = readdir(dir) {
                let name = withUnsafePointer(to: &e.pointee.d_name) {
                    $0.withMemoryRebound(to: CChar.self, capacity: Int(MAXNAMLEN) + 1) { String(cString: $0) }
                }
                if name != "." && name != ".." { children.append(name) }
            }
            closedir(dir)
            for c in children { removeTree(atPath: path + "/" + c) }
        }
        rmdir(path)
    }
}

private nonisolated(unsafe) var runRootPath: String?
