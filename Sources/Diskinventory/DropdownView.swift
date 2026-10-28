import AppKit
import DiskApp
import DiskEngine
import SwiftUI

/// What the hosted view observes; the AppDelegate rewrites it as controllers publish.
@MainActor
final class DropdownState: ObservableObject {
    @Published var model: DropdownModel
    @Published var period: Int

    init(model: DropdownModel, period: Int = 7) {
        self.model = model
        self.period = period
    }
}

struct DropdownHost: View {
    @ObservedObject var state: DropdownState
    let select: (String) -> Void
    let setPeriod: (Int) -> Void
    let eject: () -> Void

    var body: some View {
        DropdownView(model: state.model, period: state.period, select: select, setPeriod: setPeriod, eject: eject)
    }
}

/// Colors from the approved flat mockup, light and dark.
private enum Tokens {
    private static func dynamic(dark: NSColor, light: NSColor) -> Color {
        Color(nsColor: NSColor(name: nil) { appearance in
            appearance.bestMatch(from: [.darkAqua, .aqua]) == .darkAqua ? dark : light
        })
    }
    private static func rgb(_ hex: UInt32, _ alpha: CGFloat = 1) -> NSColor {
        NSColor(srgbRed: CGFloat((hex >> 16) & 0xFF) / 255, green: CGFloat((hex >> 8) & 0xFF) / 255,
                blue: CGFloat(hex & 0xFF) / 255, alpha: alpha)
    }
    static let bg = dynamic(dark: rgb(0x2B2936), light: rgb(0xFAFAFC))
    static let fg = dynamic(dark: rgb(0xF2F1F7), light: rgb(0x16161D))
    static let fg2 = dynamic(dark: rgb(0xF2F1F7, 0.56), light: rgb(0x16161D, 0.55))
    static let line = dynamic(dark: NSColor(white: 1, alpha: 0.08), light: NSColor(srgbRed: 20/255, green: 20/255, blue: 40/255, alpha: 0.08))
    static let chip = dynamic(dark: NSColor(white: 1, alpha: 0.07), light: NSColor(srgbRed: 20/255, green: 20/255, blue: 40/255, alpha: 0.05))
}

struct DropdownView: View {
    let model: DropdownModel
    let period: Int
    let select: (String) -> Void
    let setPeriod: (Int) -> Void
    let eject: () -> Void

    private var isOffline: Bool { model.tabs.first(where: \.isSelected)?.isOffline ?? false }

    var body: some View {
        VStack(spacing: 0) {
            tabs
            freeSection
            if !isOffline { changedSection }
            footer
        }
        .font(.system(size: 13))
        .foregroundStyle(Tokens.fg)
        .frame(width: 340)
        .background(Tokens.bg)
        .clipShape(RoundedRectangle(cornerRadius: 10))
        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(Tokens.line, lineWidth: 0.5))
    }

    private func divider() -> some View {
        Rectangle().fill(Tokens.line).frame(height: 0.5)
    }

    // MARK: Tabs

    private var tabs: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: 4) {
                ForEach(model.tabs, id: \.uuid) { tab in
                    Button { select(tab.uuid) } label: {
                        HStack(spacing: 6) {
                            RoundedRectangle(cornerRadius: 2)
                                .fill(Palette.tints[tab.tintIndex % Palette.tints.count])
                                .frame(width: 8, height: 8)
                            Text(tab.name).lineLimit(1)
                        }
                        .padding(.horizontal, 9).padding(.vertical, 5)
                        .foregroundStyle(tab.isSelected ? Tokens.fg : Tokens.fg2)
                        .fontWeight(tab.isSelected ? .semibold : .regular)
                        .opacity(tab.isOffline ? 0.55 : 1)
                        .background(tab.isSelected ? Tokens.chip : .clear, in: RoundedRectangle(cornerRadius: 6))
                        .contentShape(RoundedRectangle(cornerRadius: 6))
                    }
                    .buttonStyle(.plain)
                }
            }
            .padding(.horizontal, 8)
        }
        .padding(.top, 8)
    }

    // MARK: Free space, bar, key

    private var freeSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack(alignment: .firstTextBaseline) {
                Text(model.freeTitle)
                    .font(.system(size: 22, weight: .semibold))
                    .tracking(-0.44).monospacedDigit()
                    .lineLimit(1).fixedSize()
                Spacer(minLength: 8)
                detail.lineLimit(1).minimumScaleFactor(0.8)
            }
            if !model.bar.isEmpty {
                diskBar.padding(.top, 9)
                key.padding(.top, 9)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
    }

    private var detail: some View {
        Text(model.freeDetail)
            .font(.system(size: 12)).foregroundStyle(Tokens.fg2)
            .multilineTextAlignment(.trailing)
    }

    private var diskBar: some View {
        GeometryReader { geo in
            let gaps = 1.5 * CGFloat(max(model.bar.count - 1, 0))
            let usable = max(geo.size.width - gaps, 0)
            HStack(spacing: 1.5) {
                ForEach(Array(model.bar.enumerated()), id: \.offset) { _, seg in
                    segment(seg.kind).frame(width: usable * seg.fraction)
                }
            }
        }
        .frame(height: 12)
        .clipShape(RoundedRectangle(cornerRadius: 3))
    }

    @ViewBuilder private func segment(_ kind: SegmentKind) -> some View {
        switch kind {
        case .content(let k): Palette.color(k)
        case .reclaimable: RuledPattern(opacity: 0.55)
        case .free: Tokens.chip
        }
    }

    private var key: some View {
        FlowLayout(hSpacing: 12, vSpacing: 4) {
            ForEach(model.legend, id: \.self) { kind in
                keyItem(Palette.color(kind), Self.legendName(kind))
            }
            if model.showsReclaimable {
                HStack(spacing: 5) {
                    RuledPattern(opacity: 1).frame(width: 8, height: 8).clipShape(RoundedRectangle(cornerRadius: 2))
                    Text("Reclaimable")
                }
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Tokens.fg2)
    }

    private func keyItem(_ color: Color, _ name: String) -> some View {
        HStack(spacing: 5) {
            RoundedRectangle(cornerRadius: 2).fill(color).frame(width: 8, height: 8)
            Text(name)
        }
    }

    static func legendName(_ kind: ContentKind) -> String {
        switch kind {
        case .appData: "App data"
        case .virtualMachines: "VMs"
        case .developer: "Developer"
        case .media: "Media"
        case .apps: "Apps"
        case .documents: "Documents"
        case .caches: "Caches"
        case .other: "Other"
        }
    }

    // MARK: What changed

    private var changedSection: some View {
        VStack(alignment: .leading, spacing: 0) {
            HStack {
                Text("What changed").fontWeight(.semibold)
                Spacer()
                periodControl
            }
            .padding(.bottom, 6)
            if let message = model.emptyMessage {
                secondaryLine(message)
            } else if model.rows.isEmpty {
                secondaryLine("Loading\u{2026}")
            } else {
                ForEach(Array(model.rows.enumerated()), id: \.offset) { _, row in rowView(row) }
            }
            if !model.netValue.isEmpty {
                HStack {
                    Text(model.netLabel).foregroundStyle(Tokens.fg2)
                    Spacer()
                    Text(model.netValue).foregroundStyle(model.netIsGrowth ? Palette.growth : Palette.freed)
                }
                .font(.system(size: 12))
                .padding(.top, 6)
                .overlay(alignment: .top) { divider() }
                .padding(.top, 4)
            }
        }
        .padding(.horizontal, 14).padding(.vertical, 12)
        .overlay(alignment: .top) { divider() }
    }

    private func secondaryLine(_ text: String) -> some View {
        Text(text).font(.system(size: 12)).foregroundStyle(Tokens.fg2)
            .fixedSize(horizontal: false, vertical: true)
            .padding(.vertical, 6)
    }

    private var periodControl: some View {
        HStack(spacing: 0) {
            ForEach([(1, "Today"), (7, "7 days"), (30, "30 days")], id: \.0) { value, title in
                let on = period == value
                Button { setPeriod(value) } label: {
                    Text(title)
                        .font(.system(size: 11.5, weight: on ? .semibold : .regular))
                        .padding(.horizontal, 8).padding(.vertical, 2)
                        .foregroundStyle(on ? Tokens.bg : Tokens.fg2)
                        .background(on ? Tokens.fg : .clear, in: RoundedRectangle(cornerRadius: 4))
                        .contentShape(RoundedRectangle(cornerRadius: 4))
                }
                .buttonStyle(.plain)
            }
        }
        .padding(2)
        .background(Tokens.chip, in: RoundedRectangle(cornerRadius: 6))
    }

    private func rowView(_ row: DropdownModel.Row) -> some View {
        HStack(spacing: 10) {
            RoundedRectangle(cornerRadius: 2).fill(Palette.color(row.kind)).frame(width: 8, height: 8)
            (Text(row.name)
                + (row.location.isEmpty ? Text("") : Text("  " + row.location).font(.system(size: 11)).foregroundColor(Tokens.fg2)))
                .lineLimit(1).truncationMode(.tail)
                .frame(maxWidth: .infinity, alignment: .leading)
            Text(row.delta).fontWeight(.semibold).monospacedDigit()
                .foregroundStyle(row.isGrowth ? Palette.growth : Palette.freed)
        }
        .padding(.vertical, 6)
    }

    // MARK: Footer

    private var footer: some View {
        HStack {
            Text(model.footerLeft)
            Spacer()
            switch model.footerRight {
            case .settings: Text("Settings \u{2318},")
            case .eject: Button("Eject", action: eject).buttonStyle(.plain)
            case .none: EmptyView()
            }
        }
        .font(.system(size: 11.5)).foregroundStyle(Tokens.fg2)
        .padding(.horizontal, 14).padding(.vertical, 8)
        .overlay(alignment: .top) { divider() }
    }
}

/// 1 pt lines every 3 pt in the secondary label color (the reclaimable segment).
struct RuledPattern: View {
    let opacity: Double

    var body: some View {
        Canvas { context, size in
            var x: CGFloat = 0
            while x < size.width {
                context.fill(Path(CGRect(x: x, y: 0, width: 1, height: size.height)),
                             with: .color(Color(nsColor: .secondaryLabelColor).opacity(opacity)))
                x += 3
            }
        }
    }
}

/// Wraps children onto new lines like the mockup's flex-wrap key.
struct FlowLayout: Layout {
    var hSpacing: CGFloat
    var vSpacing: CGFloat

    func sizeThatFits(proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) -> CGSize {
        arrange(proposal.width ?? .infinity, subviews).size
    }

    func placeSubviews(in bounds: CGRect, proposal: ProposedViewSize, subviews: Subviews, cache: inout ()) {
        let result = arrange(bounds.width, subviews)
        for (i, origin) in result.origins.enumerated() {
            subviews[i].place(at: CGPoint(x: bounds.minX + origin.x, y: bounds.minY + origin.y), proposal: .unspecified)
        }
    }

    private func arrange(_ width: CGFloat, _ subviews: Subviews) -> (size: CGSize, origins: [CGPoint]) {
        var origins: [CGPoint] = []
        var x: CGFloat = 0, y: CGFloat = 0, rowHeight: CGFloat = 0, maxX: CGFloat = 0
        for sub in subviews {
            let s = sub.sizeThatFits(.unspecified)
            if x > 0, x + s.width > width { x = 0; y += rowHeight + vSpacing; rowHeight = 0 }
            origins.append(CGPoint(x: x, y: y))
            x += s.width + hSpacing
            maxX = max(maxX, x - hSpacing)
            rowHeight = max(rowHeight, s.height)
        }
        return (CGSize(width: maxX, height: y + rowHeight), origins)
    }
}
