import FirebaseAuth
import FirebaseCore
import SwiftUI

@Observable @MainActor
final class PendingDeviceApprovalModel {
    private let gateway: MacDeviceTrustGateway
    private(set) var pendingDevices: [MacTrustedDevice] = []
    private(set) var thisDeviceIsTrusted: Bool = false
    private(set) var approvingDeviceId: String?
    private(set) var lastErrorMessage: String?
    var isDismissed: Bool = false

    init(gateway: MacDeviceTrustGateway = MacLiveDeviceTrustGateway()) {
        self.gateway = gateway
    }

    var hasPending: Bool {
        !pendingDevices.isEmpty
    }

    var canApproveFromThisDevice: Bool {
        thisDeviceIsTrusted
    }

    func refresh() async {
        do {
            if FirebaseApp.app() != nil, let user = Auth.auth().currentUser {
                _ = try? await user.getIDTokenResult(forcingRefresh: true)
            }
            let devices = DeviceTrustViewModel.deduplicatedDevices(
                try await gateway.trustedDevices()
            )
            let current = devices.first(where: \.isCurrentDevice)
            thisDeviceIsTrusted = current?.trustState == .trusted
            pendingDevices = devices.filter { $0.trustState == .pending }
            if pendingDevices.isEmpty {
                isDismissed = false
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func approve(device: MacTrustedDevice) async {
        guard canApproveFromThisDevice, !device.isCurrentDevice else {
            lastErrorMessage = MacCopy.pendingApprovalNeedsTrustedApprover
            return
        }
        approvingDeviceId = device.id
        defer { approvingDeviceId = nil }
        do {
            try await gateway.approve(deviceID: device.id)
            lastErrorMessage = nil
            await refresh()
        } catch {
            lastErrorMessage = Self.userFacingApprovalError(error)
        }
    }

    static func userFacingApprovalError(_ error: Error) -> String {
        let raw = error.localizedDescription
        let lowered = raw.lowercased()
        if lowered.contains("distinct trusted native") ||
            lowered.contains("must be a trusted native device") {
            return MacCopy.pendingApprovalNeedsTrustedApprover
        }
        return raw
    }
}

struct PendingDeviceApprovalBanner: View {
    var model: PendingDeviceApprovalModel
    var compact: Bool = true
    var horizontalInset: CGFloat = DesignSystem.Spacing.sm
    var topInset: CGFloat = DesignSystem.Spacing.xs
    var onOpenSettings: (() -> Void)?

    var body: some View {
        Group {
            if model.hasPending {
                if model.isDismissed {
                    collapsedChip
                } else {
                    expandedCard
                }
            }
        }
        .task {
            await model.refresh()
        }
        .onAppear {
            Task { await model.refresh() }
        }
    }

    private var collapsedChip: some View {
        Button {
            withAnimation(DesignSystem.Animation.standard) {
                model.isDismissed = false
            }
        } label: {
            HStack(spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                Text(pendingCountLabel)
                    .font(DesignSystem.Typography.tiny)
                    .fontWeight(.medium)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Spacer()
                Image(systemName: "chevron.down")
                    .font(.system(size: 9, weight: .bold))
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            .padding(.horizontal, DesignSystem.Spacing.sm)
            .padding(.vertical, 4)
            .background(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .fill(DesignSystem.Colors.amber.opacity(0.12))
            )
            .overlay(
                RoundedRectangle(cornerRadius: 6, style: .continuous)
                    .stroke(DesignSystem.Colors.amber.opacity(0.35), lineWidth: 1)
            )
        }
        .buttonStyle(.plain)
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .transition(.move(edge: .top).combined(with: .opacity))
        .accessibilityLabel(pendingCountLabel)
    }

    private var expandedCard: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
            HStack(alignment: .firstTextBaseline, spacing: DesignSystem.Spacing.xs) {
                Image(systemName: "lock.shield.fill")
                    .font(.system(size: 11, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.amber)
                Text(pendingCountLabel)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .fixedSize(horizontal: false, vertical: true)
                Spacer(minLength: 4)
                Button {
                    withAnimation(DesignSystem.Animation.standard) {
                        model.isDismissed = true
                    }
                } label: {
                    Image(systemName: "xmark")
                        .font(.system(size: 10, weight: .bold))
                        .foregroundStyle(DesignSystem.Colors.textSecondary)
                        .padding(4)
                }
                .buttonStyle(.plain)
                .accessibilityLabel("Dismiss banner")
            }

            if !model.canApproveFromThisDevice {
                Text(MacCopy.pendingApprovalNeedsTrustedApprover)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .fixedSize(horizontal: false, vertical: true)
            }

            ScrollView {
                VStack(spacing: DesignSystem.Spacing.xs) {
                    ForEach(model.pendingDevices) { device in
                        pendingDeviceRow(device)
                    }
                }
            }
            .frame(maxHeight: compact ? 168 : 280)

            if let error = model.lastErrorMessage,
               !error.isEmpty,
               model.canApproveFromThisDevice || error != MacCopy.pendingApprovalNeedsTrustedApprover {
                Text(error)
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.error)
                    .fixedSize(horizontal: false, vertical: true)
                    .accessibilityIdentifier("pending-device-approval.error")
            }

            Button(MacCopy.reviewPendingDevices) {
                onOpenSettings?()
            }
            .buttonStyle(.plain)
            .font(DesignSystem.Typography.tiny)
            .fontWeight(.semibold)
            .foregroundStyle(DesignSystem.Colors.teal)
            .accessibilityIdentifier("pending-device-approval.open-settings")
        }
        .padding(.horizontal, DesignSystem.Spacing.sm)
        .padding(.vertical, DesignSystem.Spacing.xs)
        .background(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .fill(DesignSystem.Colors.surface)
        )
        .overlay(
            RoundedRectangle(cornerRadius: 8, style: .continuous)
                .stroke(DesignSystem.Colors.amber.opacity(0.4), lineWidth: 1)
        )
        .padding(.horizontal, horizontalInset)
        .padding(.top, topInset)
        .transition(.move(edge: .top).combined(with: .opacity))
    }

    private var pendingCountLabel: String {
        let count = model.pendingDevices.count
        return count == 1 ? "1 device waiting for approval" : "\(count) devices waiting for approval"
    }

    private func pendingDeviceRow(_ device: MacTrustedDevice) -> some View {
        HStack(spacing: DesignSystem.Spacing.sm) {
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.amber.opacity(0.2))
                    .frame(width: 28, height: 28)
                Image(systemName: platformIcon(for: device.platform))
                    .font(.system(size: 13, weight: .medium))
                    .foregroundStyle(DesignSystem.Colors.amber)
            }

            VStack(alignment: .leading, spacing: 1) {
                Text(device.isCurrentDevice ? "\(device.displayName) (this Mac)" : device.displayName)
                    .font(DesignSystem.Typography.caption)
                    .fontWeight(.semibold)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
                Text(deviceSummary(for: device))
                    .font(DesignSystem.Typography.tiny)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .lineLimit(2)
                    .fixedSize(horizontal: false, vertical: true)
            }
            .frame(maxWidth: .infinity, alignment: .leading)

            if model.canApproveFromThisDevice, !device.isCurrentDevice {
                Button {
                    Task { await model.approve(device: device) }
                } label: {
                    if model.approvingDeviceId == device.id {
                        ProgressView()
                            .scaleEffect(0.65)
                            .frame(width: 54, height: 22)
                    } else {
                        Text("Approve")
                            .font(DesignSystem.Typography.tiny)
                            .fontWeight(.semibold)
                            .foregroundStyle(DesignSystem.Colors.textPrimary)
                            .padding(.horizontal, 8)
                            .padding(.vertical, 3)
                    }
                }
                .buttonStyle(.borderedProminent)
                .tint(DesignSystem.Colors.teal)
                .controlSize(.mini)
                .disabled(model.approvingDeviceId != nil)
                .accessibilityIdentifier("pending-device-approval.approve.\(device.id)")
            }
        }
        .accessibilityIdentifier("pending-device-approval.row.\(device.id)")
    }

    private func platformIcon(for platform: String) -> String {
        switch platform.lowercased() {
        case "web":
            return "globe"
        case "ios", "ipados", "iphone", "ipad":
            return "iphone"
        case "android":
            return "phone.fill"
        default:
            return "macbook"
        }
    }

    private func deviceSummary(for device: MacTrustedDevice) -> String {
        if let safety = device.safetyCode, !safety.isEmpty {
            return "\(device.platform) · Safety: \(safety.prefix(9))…"
        }
        if device.isCurrentDevice {
            return "\(device.platform) · Waiting for a trusted phone or Mac"
        }
        return "\(device.platform) · Requesting vault access"
    }
}
