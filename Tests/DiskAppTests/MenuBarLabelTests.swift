import Testing
import DiskEngine
@testable import DiskApp

@Test func labelLevels() {
    let gb: UInt64 = 1_000_000_000
    // 82 GB of 1000 GB free is 8.2%: below 15% (amber), not below 5% (red).
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 50*gb, availableForImportantUsage: 82*gb), showNumber: true)
        == MenuBarLabel(text: "82 GB", level: .low, fillFraction: 0.918))
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 30*gb, availableForImportantUsage: 40*gb), showNumber: true).level == .critical)
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 300*gb, availableForImportantUsage: 300*gb), showNumber: true).level == .normal)
    #expect(MenuBarLabel.make(space: .init(total: 1000*gb, available: 300*gb, availableForImportantUsage: 300*gb), showNumber: false).text == "")
}
