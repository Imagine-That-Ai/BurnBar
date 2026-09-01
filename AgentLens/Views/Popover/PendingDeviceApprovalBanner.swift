import SwiftUI

@Observable @MainActor
final class PendingDeviceApprovalModel {
    private let gateway: MacDeviceTrustGateway
    private(set) var pendingDevices: [MacTrustedDevice] = []
    private(set) var approvingDeviceId: String?
    private(set) var lastErrorMessage: String?
    var isDismissed: Bool = false

    init(gateway: MacDeviceTrustGateway = MacLiveDeviceTrustGateway()) {
        self.gateway = gateway
    }

    var hasPending: Bool {
        !pendingDevices.isEmpty
    }

    var activeDevice: MacTrustedDevice? {
        pendingDevices.first
    }

    func refresh() async {
        do {
            let devices = try await gateway.trustedDevices()
            pendingDevices = devices.filter { $0.trustState == .pending && !$0.isCurrentDevice }
            if pendingDevices.isEmpty {
                isDismissed = false
            }
            lastErrorMessage = nil
        } catch {
            lastErrorMessage = error.localizedDescription
        }
    }

    func approve(device: MacTrustedDevice) async {
        approvingDeviceId = device.id
        defer { approvingDeviceId = nil }
        do {
            try await gateway.approve(deviceID: device.id)
            lastErrorMessage = nil
            await refresh()
        } catch {
            lastErrorMessage = error.localizedDescription
        }
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
            if model.hasPending, let device = model.activeDevice {
                if model.isDismissed {
                    Button {
                        withAnimation(DesignSystem.Animation.standard) {
                            model.isDismissed = false
                        }
                    } label: {
                        HStack(spacing: DesignSystem.Spacing.xs) {
                            Image(systemName: "lock.shield.fill")
                                .font(.system(size: 11, weight: .semibold))
                                .foregroundStyle(DesignSystem.Colors.amber)
                            Text("\(model.pendingDevices.count) Pending Device Approval")
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
                } else {
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
                            HStack(spacing: 4) {
                                Text("Approve \(device.displayName)")
                                    .font(DesignSystem.Typography.caption)
                                    .fontWeight(.semibold)
                                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                                    .lineLimit(1)
                            }

                            Text(deviceSummary(for: device))
                                .font(DesignSystem.Typography.tiny)
                                .foregroundStyle(DesignSystem.Colors.textSecondary)
                                .lineLimit(1)
                        }

                        Spacer(minLength: 4)

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
            }
        }
        .task {
            await model.refresh()
        }
        .onAppear {
            Task { await model.refresh() }
        }
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
        return "\(device.platform) · Requesting vault access"
    }
}
