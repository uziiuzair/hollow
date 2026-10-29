// SPDX-License-Identifier: GPL-3.0-or-later

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
    public static func color(_ kind: ContentKind) -> Color { Color(hex: hex(kind)) }

    /// The kind's sRGB color as 0xRRGGBB.
    public static func hex(_ kind: ContentKind) -> UInt32 {
        switch kind {
        case .apps: 0x4C7CE0
        case .virtualMachines: 0x2E9FC4
        case .developer: 0x7A5FD6
        case .media: 0xD45C7E
        case .documents: 0xD9893A
        case .appData: 0x3E9E7A
        case .caches: 0x6B7183
        case .other: 0x8E8E93
        }
    }

    public static let growth = Color(hex: 0xE8805F)
    public static let freed = Color(hex: 0x3FA67F)
    /// Drive tints: internal first, then externals in order.
    public static let tints: [Color] = [
        0x8B7BFF, 0x0FA39B, 0xE0884F, 0x4C9BE0, 0xD2589A, 0x6BA34A, 0xB08A3E, 0x7E8796,
    ].map { Color(hex: $0) }
    public static let other = Color(hex: hex(.other))
}
