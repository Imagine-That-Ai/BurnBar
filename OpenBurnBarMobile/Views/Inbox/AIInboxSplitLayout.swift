import SwiftUI
import OpenBurnBarCore

// MARK: - AI Inbox split layout (iPad)
//
// Two columns at width ≥ 720pt — the same threshold and the same draggable,
// `@AppStorage`-persisted divider as `HermesSquareSplitLayout`, so the two
// list+detail surfaces in the app resize identically. Below the threshold the
// list renders alone and rows push onto the host's stack.
//
// This is the ONLY place that chooses between one column and two: iPhone, a
// half-width iPad split, and a full-width iPad all mount this same view and it
// resolves the arrangement from the width it is actually given — so a Slide Over
// resize is a layout change, not a different code path.

struct AIInboxSplitLayout: View {
    @Bindable var store: AIInboxStore

    @AppStorage("ai_inbox_ipad_left_column_width") private var storedLeftColumnWidth: Double = 0
    @State private var resizeStartWidth: CGFloat?

    var body: some View {
        GeometryReader { geometry in
            if geometry.size.width >= 720 {
                twoColumnLayout(width: geometry.size.width)
            } else {
                AIInboxView(store: store, selectionMode: .push)
            }
        }
    }

    private func twoColumnLayout(width: CGFloat) -> some View {
        let limits = leftColumnWidthLimits(for: width)
        let defaultWidth = min(max(width * 0.38, limits.min), limits.max)
        let leftWidth = storedLeftColumnWidth > 0
            ? min(max(CGFloat(storedLeftColumnWidth), limits.min), limits.max)
            : defaultWidth

        return HStack(spacing: 0) {
            // `.inline` — selection drives the right column instead of a push,
            // so the list stays visible while the item is read.
            AIInboxView(store: store, selectionMode: .inline)
                .frame(width: leftWidth)
                .frame(maxHeight: .infinity)
                .clipped()

            AIInboxResizeHandle()
                .gesture(
                    DragGesture(minimumDistance: 0)
                        .onChanged { value in
                            let startWidth = resizeStartWidth ?? leftWidth
                            resizeStartWidth = startWidth
                            let resized = startWidth + value.translation.width
                            storedLeftColumnWidth = Double(min(max(resized, limits.min), limits.max))
                        }
                        .onEnded { _ in
                            resizeStartWidth = nil
                        }
                )
                .accessibilityLabel("Resize inbox list")
                .accessibilityHint("Drag left or right to resize the inbox list.")

            detailColumn
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .clipped()
        }
        .frame(maxWidth: .infinity, maxHeight: .infinity)
    }

    @ViewBuilder
    private var detailColumn: some View {
        if let item = store.selectedItem {
            AIInboxDetailView(
                item: item,
                onArchive: { Task { await store.archive(item.id) } },
                onSnooze: { interval in Task { await store.snooze(item.id, for: interval) } },
                onFeedback: { useful in Task { await store.setFeedback(item.id, useful: useful) } }
            )
            .id(item.id)
        } else {
            AuroraStatePane(
                kind: .empty,
                icon: "sparkles",
                title: "Select an item",
                message: "Each item explains what happened, shows the evidence behind it, and offers the next step."
            )
            .padding(.horizontal, AuroraDesign.Layout.cardInset)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
    }

    /// Keeps the list wide enough to stay readable and the detail wide enough
    /// for the evidence rows. Same shape as the Agents split so a user who has
    /// dragged one recognizes the other's limits.
    private func leftColumnWidthLimits(for width: CGFloat) -> (min: CGFloat, max: CGFloat) {
        let minWidth = min(max(width * 0.30, 340), 420)
        let maxWidth = min(max(width * 0.52, 520), width - 460)
        return (minWidth, max(minWidth, maxWidth))
    }
}

// MARK: - Resize handle

/// Visual twin of `HermesSquareResizeHandle`; kept local rather than shared so
/// the Agents surface's handle can evolve with its own chrome.
struct AIInboxResizeHandle: View {
    var body: some View {
        Rectangle()
            .fill(MobileTheme.Colors.borderSubtle.opacity(0.7))
            .frame(width: 10)
            .overlay {
                Capsule()
                    .fill(MobileTheme.Colors.textMuted.opacity(0.28))
                    .frame(width: 3, height: 44)
            }
            .contentShape(Rectangle())
    }
}
