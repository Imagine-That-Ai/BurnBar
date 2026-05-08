import SwiftUI

// MARK: - Smart Hub Cast Button
//
// Single source-of-truth control for sending the OpenBurnBar quota
// dashboard to the user's Google Nest Hub via the local DashCast bridge.
// Reads its state from `SmartHubStore` and shows a tactile loading +
// success + failure flow.

struct SmartHubCastButton: View {
    @Bindable var store: SmartHubStore
    var compact: Bool = false

    @State private var clearTask: Task<Void, Never>?

    var body: some View {
        Button {
            Task {
                HapticBus.primaryAction()
                await store.cast()
                scheduleClear()
            }
        } label: {
            HStack(spacing: 8) {
                icon
                if !compact {
                    label
                }
            }
            .padding(.horizontal, compact ? 12 : 14)
            .padding(.vertical, compact ? 8 : 10)
            .background(
                RoundedRectangle(cornerRadius: 999, style: .continuous)
                    .fill(.ultraThinMaterial)
                    .overlay(
                        RoundedRectangle(cornerRadius: 999, style: .continuous)
                            .stroke(strokeColor, lineWidth: 1)
                    )
            )
            .foregroundStyle(strokeColor)
        }
        .buttonStyle(.plain)
        .disabled(!store.canCast || store.castState == .casting)
        .accessibilityLabel(accessibilityLabel)
    }

    @ViewBuilder
    private var icon: some View {
        switch store.castState {
        case .casting:
            ProgressView().controlSize(.small)
        case .success:
            Image(systemName: "checkmark.circle.fill")
        case .failure:
            Image(systemName: "exclamationmark.triangle.fill")
        case .idle:
            Image(systemName: "tv.badge.wifi")
        }
        // SwiftUI keeps the frame stable across state swaps even though
        // the underlying view changes — no manual frame needed.
    }

    private var label: some View {
        Text(labelText)
            .font(MobileTheme.Typography.caption)
            .fontWeight(.semibold)
    }

    private var labelText: String {
        switch store.castState {
        case .casting:                 return "Casting…"
        case .success:                 return "Cast!"
        case .failure:                 return "Try again"
        case .idle:
            if !store.canCast { return "Cast unavailable" }
            return "Cast Now"
        }
    }

    private var strokeColor: Color {
        switch store.castState {
        case .success:                 return MobileTheme.Colors.success
        case .failure:                 return MobileTheme.Colors.error
        case .casting:                 return MobileTheme.hermesAureate
        case .idle:
            return store.canCast
                ? MobileTheme.hermesAureate
                : MobileTheme.Colors.textMuted
        }
    }

    private var accessibilityLabel: String {
        switch store.castState {
        case .casting: return "Casting dashboard to Nest Hub"
        case .success: return "Dashboard cast successfully"
        case .failure(let message): return "Cast failed. \(message)"
        case .idle:    return "Cast dashboard to Nest Hub"
        }
    }

    private func scheduleClear() {
        clearTask?.cancel()
        clearTask = Task {
            try? await Task.sleep(nanoseconds: 2_500_000_000)
            if !Task.isCancelled { store.clearCastFeedback() }
        }
    }
}
