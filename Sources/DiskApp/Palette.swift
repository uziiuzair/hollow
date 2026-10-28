import SwiftUI
import DiskEngine

extension Color {
    public init(hex: UInt32) {
        self.init(
            .sRGB,
            red: Double((hex >> 16) & 0xFF) / 255,
            green: Double((hex >> 8) & 0xFF) / 255,
            blue: Double(hex & 0xFF) / 255,
            opacity: 1)
    }
}

public enum Palette {
    public static func color(_ kind: ContentKind) -> Color {
        switch kind {
        case .apps: Color(hex: 0x4C7CE0)
        case .virtualMachines: Color(hex: 0x2E9FC4)
        case .developer: Color(hex: 0x7A5FD6)
        case .media: Color(hex: 0xD45C7E)
        case .documents: Color(hex: 0xD9893A)
        case .appData: Color(hex: 0x3E9E7A)
        case .caches: Color(hex: 0x6B7183)
        case .other: other
        }
    }

    public static let growth = Color(hex: 0xE8805F)
    public static let freed = Color(hex: 0x3FA67F)
    /// Drive tints: internal first, then externals in order.
    public static let tints: [Color] = [
        0x8B7BFF, 0x0FA39B, 0xE0884F, 0x4C9BE0, 0xD2589A, 0x6BA34A, 0xB08A3E, 0x7E8796,
    ].map { Color(hex: $0) }
    public static let other = Color(hex: 0x8E8E93)
}
