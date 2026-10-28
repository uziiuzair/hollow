import DiskApp
import DiskEngine
import SwiftUI

/// The list the user checks before anything moves to the Trash. Nothing moves until "Move N items to Trash".
struct ReviewSheetView: View {
    @ObservedObject var basket: Basket
    /// Kept by the window, so it can tell a move is under way and reset a finished sheet.
    @Binding var phase: ReviewPhase
    /// The drive's app-managed hits, read each time the sheet draws.
    let protected: () -> [LensHit]
    let driveName: String
    let driveConnected: Bool
    /// Moves the items (the checked, trashable ones) and answers what happened.
    let move: ([BasketItem]) async -> TrashOutcome
    let close: () -> Void


    @State private var unchecked: Set<String> = []

    static let width: CGFloat = 560
    static let maxRowsHeight: CGFloat = 420

    var body: some View {
        Group {
            if case .done(let outcome) = phase {
                done(outcome)
            } else {
                review
            }
        }
        .frame(width: Self.width)
        .interactiveDismissDisabled(isMoving)
    }

    private var isMoving: Bool { phase == .moving }

    // MARK: Review

    private var review: some View {
        let protectedHits = protected()
        let sheet = ReviewSheet.make(items: basket.items, unchecked: unchecked, protected: protectedHits,
                                     driveName: driveName, driveConnected: driveConnected)
        return VStack(alignment: .leading, spacing: 0) {
            VStack(alignment: .leading, spacing: 4) {
                Text(ReviewSheet.title).font(.system(size: 15, weight: .semibold))
                Text(ReviewSheet.subtitle).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
            }
            .padding(.horizontal, 20).padding(.top, 18).padding(.bottom, 12)
            Divider()
            rows(sheet.rows)
            Divider()
            if let notice = sheet.notice {
                Text(notice).foregroundStyle(.secondary)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(.horizontal, 20).padding(.top, 10)
            }
            footer(sheet)
        }
        .disabled(isMoving)
    }

    /// As tall as the rows, up to `maxRowsHeight`; past that the rows scroll.
    private func rows(_ rows: [ReviewRow]) -> some View {
        let list = VStack(spacing: 0) {
            ForEach(rows, id: \.path) { row in
                rowView(row)
                if row.path != rows.last?.path { Divider().padding(.leading, 48) }
            }
        }
        // Hugs the rows (the sheet would otherwise stretch it to the cap), and scrolls past the cap.
        return ScrollView { list }
            .frame(maxHeight: Self.maxRowsHeight)
            .fixedSize(horizontal: false, vertical: true)
    }

    private func rowView(_ row: ReviewRow) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Group {
                if row.isCheckable {
                    Toggle("", isOn: Binding(
                        get: { !unchecked.contains(row.path) },
                        set: { on in if on { unchecked.remove(row.path) } else { unchecked.insert(row.path) } }))
                        .toggleStyle(.checkbox).labelsHidden()
                } else {
                    Image(systemName: "arrow.up.forward.app").foregroundStyle(.secondary)
                }
            }
            .frame(width: 18, alignment: .center)
            VStack(alignment: .leading, spacing: 2) {
                Text(row.name).fontWeight(.semibold).lineLimit(1).truncationMode(.middle)
                Text(row.location).foregroundStyle(.secondary).lineLimit(1).truncationMode(.middle)
                Text(row.explanation).foregroundStyle(.secondary).lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                if let instruction = row.instruction {
                    Text(instruction).lineLimit(2).fixedSize(horizontal: false, vertical: true)
                }
            }
            Spacer(minLength: 8)
            Text(row.size).monospacedDigit()
            Button { remove(row.path) } label: {
                Image(systemName: "xmark").font(.system(size: 10, weight: .semibold)).foregroundStyle(.secondary)
                    .frame(width: 18, height: 18).contentShape(Rectangle())
            }
            .buttonStyle(.plain)
            .help("Take it out of the basket")
        }
        .font(.system(size: 12))
        .padding(.horizontal, 20).padding(.vertical, 9)
    }

    private func footer(_ sheet: ReviewSheet) -> some View {
        HStack(spacing: 8) {
            if isMoving {
                ProgressView().controlSize(.small)
                Text("Moving to Trash\u{2026}").foregroundStyle(.secondary)
            } else {
                Text(sheet.selectedLabel).foregroundStyle(.secondary).monospacedDigit()
            }
            Spacer()
            Button("Cancel", action: close).keyboardShortcut(.cancelAction)
            // No Return shortcut: nothing moves without a click on this button.
            Button(sheet.buttonTitle) { start() }
                .buttonStyle(.borderedProminent)
                .disabled(!sheet.canTrash)
        }
        .padding(.horizontal, 20).padding(.vertical, 14)
    }

    private func remove(_ path: String) {
        basket.remove(paths: [path])
        unchecked.remove(path)
    }

    private func start() {
        let items = ReviewSheet.trashable(basket.items, unchecked: unchecked, protected: protected())
        guard !items.isEmpty, !isMoving else { return }
        phase = .moving
        Task {
            let outcome = await move(items)
            // Moved and already-gone items leave; failed ones stay in the basket.
            basket.remove(paths: outcome.cleared)
            unchecked.subtract(outcome.cleared)
            phase = .done(outcome)
        }
    }

    // MARK: Done

    private func done(_ outcome: TrashOutcome) -> some View {
        VStack(alignment: .leading, spacing: 8) {
            Text(outcome.title).font(.system(size: 24, weight: .semibold)).monospacedDigit()
            if let detail = outcome.detail { Text(detail).foregroundStyle(.secondary) }
            if let header = outcome.failureHeader {
                Text(header).fontWeight(.semibold).padding(.top, 6)
                ScrollView {
                    VStack(alignment: .leading, spacing: 4) {
                        ForEach(Array(outcome.failureLines.enumerated()), id: \.offset) { _, line in
                            Text(line).foregroundStyle(.secondary).fixedSize(horizontal: false, vertical: true)
                                .frame(maxWidth: .infinity, alignment: .leading)
                        }
                    }
                }
                .frame(maxHeight: 200)
            }
            HStack {
                Spacer()
                Button("Done", action: close).keyboardShortcut(.defaultAction)
            }
            .padding(.top, 10)
        }
        .padding(20)
    }
}
