import DiskApp
import DiskEngine
import SwiftUI

/// The drag in progress and where the bar is, kept apart from `MapWindowState` so a drag redraws only the bar.
@MainActor
final class BasketDragState: ObservableObject {
    /// An active drag only.
    @Published var drag: BasketDrag?
    /// The bar's frame in the "mapWindow" coordinate space, from its last layout.
    var barFrame: CGRect = .zero
}

/// Floats over the bottom of the map: what is in the drive's basket, and the way to review it.
/// It shows while the basket holds something, or while a block is being dragged.
struct BasketBar: View {
    @ObservedObject var basket: Basket
    @ObservedObject var dragState: BasketDragState
    let clear: () -> Void
    let review: () -> Void

    static let height: CGFloat = 44
    static let maxWidth: CGFloat = 560

    var body: some View {
        let drag = dragState.drag
        if !basket.items.isEmpty || drag != nil {
            let over = drag?.dropsOnBasket(dragState.barFrame) ?? false
            content
                .padding(.leading, 14).padding(.trailing, 9)
                .frame(maxWidth: Self.maxWidth)
                .frame(height: Self.height)
                .background(Color(white: 0.11), in: RoundedRectangle(cornerRadius: 6))
                .overlay(RoundedRectangle(cornerRadius: 6).strokeBorder(Color.white.opacity(over ? 0.6 : 0.08), lineWidth: 1))
                .onGeometryChange(for: CGRect.self, of: { $0.frame(in: .named(MapWindowView.space)) }) { frame in
                    dragState.barFrame = frame
                }
                .environment(\.colorScheme, .dark)
        }
    }

    @ViewBuilder private var content: some View {
        if basket.items.isEmpty {
            Text("Drop here to add to the basket")
                .foregroundStyle(.white.opacity(0.6))
                .frame(maxWidth: .infinity)
        } else {
            HStack(spacing: 10) {
                HStack(spacing: 4) {
                    ForEach(Array(basket.chips.enumerated()), id: \.offset) { _, kind in
                        RoundedRectangle(cornerRadius: 2).fill(kind.map(Palette.color) ?? Palette.other)
                            .frame(width: 12, height: 12)
                    }
                    if basket.moreCount > 0 {
                        Text("+\(basket.moreCount)").foregroundStyle(.white.opacity(0.6)).monospacedDigit()
                    }
                }
                let n = basket.items.count
                Text(n == 1 ? "1 item" : "\(n) items").fontWeight(.medium).foregroundStyle(.white).lineLimit(1)
                Text(Format.gb(basket.total)).foregroundStyle(.white.opacity(0.6)).monospacedDigit().lineLimit(1)
                Spacer(minLength: 8)
                Button("Clear", action: clear)
                    .buttonStyle(.plain)
                    .foregroundStyle(.white.opacity(0.6))
                    .padding(.horizontal, 6)
                Button(action: review) {
                    Text("Review")
                        .fontWeight(.semibold)
                        .foregroundStyle(.black)
                        .padding(.horizontal, 12)
                        .frame(height: 26)
                        .background(Color.white, in: RoundedRectangle(cornerRadius: 5))
                        .contentShape(RoundedRectangle(cornerRadius: 5))
                }
                .buttonStyle(.plain)
            }
        }
    }
}
