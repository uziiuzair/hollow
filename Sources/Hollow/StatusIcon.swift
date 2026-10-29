// SPDX-License-Identifier: GPL-3.0-or-later

import AppKit
import DiskApp

enum StatusIcon {
    static let amber = NSColor(srgbRed: 0xE8/255, green: 0xA3/255, blue: 0x3D/255, alpha: 1)
    static let red = NSColor(srgbRed: 0xE5/255, green: 0x48/255, blue: 0x4D/255, alpha: 1)

    /// 13 pt ring, 2.5 pt stroke, filled clockwise from 12 o'clock.
    static func image(fill: Double, level: LabelLevel) -> NSImage {
        let size = NSSize(width: 13, height: 13)
        let lineWidth: CGFloat = 2.5
        let ring = RingFill.forFraction(fill)
        let image = NSImage(size: size, flipped: false) { rect in
            let color: NSColor = switch level {
            case .normal: .black
            case .low: amber
            case .critical: red
            }
            let center = NSPoint(x: rect.midX, y: rect.midY)
            let radius = (rect.width - lineWidth) / 2

            let track = NSBezierPath()
            track.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            track.lineWidth = lineWidth
            color.withAlphaComponent(0.3).setStroke()
            track.stroke()

            let arc = NSBezierPath()
            switch ring {
            case .none: break
            case .full:
                arc.appendArc(withCenter: center, radius: radius, startAngle: 0, endAngle: 360)
            case .arc(let end):
                // Non-flipped coordinates: 90 degrees is 12 o'clock; clockwise means decreasing angle.
                arc.appendArc(withCenter: center, radius: radius, startAngle: 90, endAngle: end, clockwise: true)
            }
            if !arc.isEmpty {
                arc.lineWidth = lineWidth
                arc.lineCapStyle = .butt
                color.setStroke()
                arc.stroke()
            }
            return true
        }
        image.isTemplate = (level == .normal)
        return image
    }
}
