// SPDX-License-Identifier: GPL-3.0-or-later

import Foundation

public enum Format {
    private static let minus = "\u{2212}"

    /// Decimal GB; no decimal place from 10 GB up, one below.
    public static func gb(_ bytes: UInt64) -> String {
        let value = Double(bytes) / 1_000_000_000
        return value >= 10 ? String(format: "%.0f GB", value) : String(format: "%.1f GB", value)
    }

    public static func signedGB(_ delta: Int64) -> String {
        (delta < 0 ? minus : "+") + gb(delta.magnitude)
    }

    public static func periodWords(_ days: Int) -> String {
        switch days {
        case 1: return "today"
        case 7: return "this week"
        default: return "this month"
        }
    }

    public static func ago(_ date: Date, now: Date) -> String {
        let seconds = now.timeIntervalSince(date)
        if seconds < 60 { return "just now" }
        if seconds < 3600 { return "\(Int(seconds / 60)) min ago" }
        if seconds < 86_400 { return "\(Int(seconds / 3600)) h ago" }
        if Calendar.current.isDate(date, inSameDayAs: now.addingTimeInterval(-86_400)) { return "yesterday" }
        return shortDate(date)
    }

    public static func shortDate(_ date: Date) -> String {
        let f = DateFormatter()
        f.locale = Locale(identifier: "en_US_POSIX")
        f.dateFormat = "MMM d"
        return f.string(from: date)
    }
}
