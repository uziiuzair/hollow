import Foundation
import Testing
@testable import DiskApp

@Test func formatting() {
    #expect(Format.gb(82_400_000_000) == "82 GB")
    #expect(Format.gb(9_240_000_000) == "9.2 GB")
    #expect(Format.gb(600_000_000) == "0.6 GB")
    #expect(Format.signedGB(8_100_000_000) == "+8.1 GB")
    #expect(Format.signedGB(-600_000_000) == "\u{2212}0.6 GB")
    let now = Date(timeIntervalSince1970: 1_800_000_000)
    #expect(Format.ago(now.addingTimeInterval(-30), now: now) == "just now")
    #expect(Format.ago(now.addingTimeInterval(-120), now: now) == "2 min ago")
    #expect(Format.ago(now.addingTimeInterval(-3 * 3600), now: now) == "3 h ago")
}

@Test func agoYesterdayAndOlder() {
    var cal = Calendar.current
    cal.timeZone = .current
    let now = cal.date(from: DateComponents(year: 2026, month: 10, day: 28, hour: 12))!
    let yesterday = cal.date(from: DateComponents(year: 2026, month: 10, day: 27, hour: 8))!
    let older = cal.date(from: DateComponents(year: 2026, month: 10, day: 20, hour: 8))!
    #expect(Format.ago(yesterday, now: now) == "yesterday")
    #expect(Format.ago(older, now: now) == "Oct 20")
    #expect(Format.shortDate(older) == "Oct 20")
}
