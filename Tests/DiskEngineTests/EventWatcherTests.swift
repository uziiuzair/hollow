import CoreServices
import Foundation
import Testing
@testable import DiskEngine

@Test func flagMapping() {
    let sub = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs)
    #expect(FSChange.from(path: "a", flags: sub, id: 5) == FSChange(path: "a", id: 5, rescanSubtree: true, historyLost: false))
    #expect(FSChange.from(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagHistoryDone), id: 6) == nil)
    #expect(FSChange.from(path: "", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagEventIdsWrapped), id: 7)?.historyLost == true)
    let dropped = FSEventStreamEventFlags(kFSEventStreamEventFlagMustScanSubDirs | kFSEventStreamEventFlagKernelDropped)
    #expect(FSChange.from(path: "/", flags: dropped, id: 8)?.historyLost == true)
    #expect(FSChange.from(path: "x/y", flags: FSEventStreamEventFlags(kFSEventStreamEventFlagNone), id: 9)
        == FSChange(path: "x/y", id: 9, rescanSubtree: false, historyLost: false))
}

@Test func internalVolumeHasAJournal() {
    var st = stat()
    stat(FileManager.default.temporaryDirectory.path, &st)
    #expect(EventWatcher.journalUUID(device: st.st_dev) != nil)
}

@Test(.timeLimit(.minutes(1))) func reportsAFolderThatChanged() async throws {
    let root = try Fixtures.tree(["watched/": 0])
    var st = stat()
    stat(root.path, &st)
    let w = EventWatcher(device: st.st_dev, since: 0, latency: 0.2)
    try w.start()
    defer { w.stop() }
    try await Task.sleep(for: .milliseconds(500))
    try Data([1]).write(to: root.appending(path: "watched/new"))
    let target = Fixtures.realPath(root.appending(path: "watched"))
    for await batch in w.changes {
        let trimmed = batch.map { "/" + $0.path.trimmingCharacters(in: CharacterSet(charactersIn: "/")) }
        if trimmed.contains(where: { target.hasSuffix($0) && $0.count > 1 }) { return }
    }
    Issue.record("no event for the changed folder")
}
