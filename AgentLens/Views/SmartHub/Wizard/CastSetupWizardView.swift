import SwiftUI

// MARK: - Cast Setup Wizard View
//
// 5-step hand-holding wizard. The model owns all the logic; views just
// render `model.step` and call back into the model on user intent.
//
// All copy is intentionally short and conversational — this is the
// surface where the user has to understand what's happening, not where
// we should be teaching them about Cast V2 internals.

struct CastSetupWizardView: View {

    @Bindable var model: CastWizardModel
    let onClose: () -> Void

    var body: some View {
        VStack(spacing: 0) {
            ZStack {
                stepView
                    .padding(DesignSystem.Spacing.xl)
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
            }
            .background(DesignSystem.Colors.background)

            HStack(spacing: DesignSystem.Spacing.md) {
                Button("Cancel") { onClose() }
                    .buttonStyle(.plain)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .keyboardShortcut(.cancelAction)
                Spacer()
                stepProgressIndicator
            }
            .padding(.horizontal, DesignSystem.Spacing.xl)
            .padding(.vertical, DesignSystem.Spacing.lg)
            .background(DesignSystem.Colors.surface)
        }
        .frame(width: 480, height: 640)
        .animation(DesignSystem.Animation.standard, value: stepKey(model.step))
    }

    // MARK: - Step routing

    @ViewBuilder
    private var stepView: some View {
        switch model.step {
        case .welcome:
            CastWelcomeStep(onContinue: { model.start() })
        case .discover:
            CastDiscoverStep()
        case .noDevices:
            CastNoDevicesStep(onRetry: { model.retryDiscovery() })
        case .pick:
            CastPickStep(devices: model.devices, onPick: { model.pickDevice($0) })
        case .testing(let device):
            CastTestingStep(device: device)
        case .recover(let device, let attempt, let lastError):
            CastRecoverStep(
                device: device,
                attempt: attempt,
                lastError: lastError,
                onRetry: { model.retryDevice() },
                onPickAnother: { model.tryAnother() }
            )
        case .confirm(let device):
            CastConfirmStep(
                device: device,
                onYes: { model.confirmTestPattern() },
                onNo: { model.tryAnother() }
            )
        case .failed(let reason):
            CastFailedStep(reason: reason, onRetry: { model.start() })
        case .done(let device):
            CastDoneStep(device: device, onClose: onClose)
        }
    }

    private var stepProgressIndicator: some View {
        let total = 5
        let current = stepIndex(model.step)
        return HStack(spacing: 4) {
            ForEach(0..<total, id: \.self) { idx in
                Capsule()
                    .fill(idx <= current ? DesignSystem.Colors.ember : DesignSystem.Colors.border)
                    .frame(width: idx == current ? 18 : 8, height: 4)
                    .animation(DesignSystem.Animation.standard, value: current)
            }
        }
    }
}

// MARK: - Step views

private struct CastWelcomeStep: View {
    let onContinue: () -> Void
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            Image(systemName: "tv.and.hifispeaker.fill")
                .font(.system(size: 72, weight: .light))
                .foregroundStyle(DesignSystem.Colors.primaryGradient)

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Mirror OpenBurnBar to your Smart Display")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                    .multilineTextAlignment(.center)
                Text("We'll find your Nest Hub or Chromecast on the network and start showing your live token usage. Takes about 30 seconds.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }

            Spacer()
            Button(action: onContinue) {
                Text("Find devices on my network")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.xl)
                    .padding(.vertical, DesignSystem.Spacing.md)
                    .background(
                        Capsule().fill(DesignSystem.Colors.primaryGradient)
                    )
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
        }
    }
}

private struct CastDiscoverStep: View {
    @State private var pulse = false
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .stroke(DesignSystem.Colors.ember.opacity(0.3), lineWidth: 3)
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.4 : 0.85)
                    .opacity(pulse ? 0 : 0.7)
                    .animation(.easeOut(duration: 1.6).repeatForever(autoreverses: false), value: pulse)
                Image(systemName: "wifi")
                    .font(.system(size: 40, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.ember)
            }
            .onAppear { pulse = true }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Scanning your network…")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Looking for Nest Hubs, Chromecasts, and TVs.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
        }
    }
}

private struct CastNoDevicesStep: View {
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            Image(systemName: "wifi.exclamationmark")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(DesignSystem.Colors.warning)
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("No devices found")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Make sure your Smart Display is on and connected to the same Wi-Fi network as this Mac.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 360)
            }
            Button(action: onRetry) {
                Label("Scan again", systemImage: "arrow.clockwise")
                    .font(DesignSystem.Typography.headline)
                    .padding(.horizontal, DesignSystem.Spacing.xl)
                    .padding(.vertical, DesignSystem.Spacing.md)
                    .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                    .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 1))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

private struct CastPickStep: View {
    let devices: [CastDevice]
    let onPick: (CastDevice) -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: DesignSystem.Spacing.lg) {
            VStack(alignment: .leading, spacing: DesignSystem.Spacing.xs) {
                Text("Found \(devices.count) device\(devices.count == 1 ? "" : "s")")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Pick which one to mirror to.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }

            ScrollView {
                VStack(spacing: DesignSystem.Spacing.sm) {
                    ForEach(devices, id: \.serviceName) { device in
                        Button(action: { onPick(device) }) {
                            HStack(spacing: DesignSystem.Spacing.md) {
                                Image(systemName: iconName(for: device))
                                    .font(.system(size: 24, weight: .light))
                                    .foregroundStyle(device.supportsDisplay
                                                     ? DesignSystem.Colors.ember
                                                     : DesignSystem.Colors.textMuted)
                                    .frame(width: 36)
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(device.friendlyName)
                                            .font(DesignSystem.Typography.headline)
                                            .foregroundStyle(device.supportsDisplay
                                                             ? DesignSystem.Colors.textPrimary
                                                             : DesignSystem.Colors.textSecondary)
                                        if !device.supportsDisplay {
                                            Text("speaker")
                                                .font(DesignSystem.Typography.tiny)
                                                .foregroundStyle(DesignSystem.Colors.warning)
                                                .padding(.horizontal, 6)
                                                .padding(.vertical, 2)
                                                .background(
                                                    Capsule().fill(DesignSystem.Colors.warning.opacity(0.15))
                                                )
                                        }
                                    }
                                    Text(device.supportsDisplay
                                         ? "\(device.model) • \(device.host)"
                                         : "Audio-only — won't show webpages")
                                        .font(DesignSystem.Typography.monoSmall)
                                        .foregroundStyle(DesignSystem.Colors.textMuted)
                                }
                                Spacer()
                                Image(systemName: "chevron.right")
                                    .font(.system(size: 12, weight: .semibold))
                                    .foregroundStyle(DesignSystem.Colors.textMuted)
                            }
                            .padding(DesignSystem.Spacing.md)
                            .background(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                                    .fill(DesignSystem.Colors.surfaceElevated)
                            )
                            .overlay(
                                RoundedRectangle(cornerRadius: DesignSystem.Radius.md)
                                    .strokeBorder(DesignSystem.Colors.border, lineWidth: 1)
                            )
                            .opacity(device.supportsDisplay ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                    }
                }
            }
        }
        .frame(maxWidth: .infinity, alignment: .topLeading)
    }

    private func iconName(for device: CastDevice) -> String {
        switch device.iconKind {
        case .nestHub, .nestHubMax: return "display"
        case .chromecast: return "tv"
        case .nestSpeaker: return "homepod"
        case .generic: return "tv.and.hifispeaker.fill"
        }
    }
}

private struct CastTestingStep: View {
    let device: CastDevice
    @State private var pulse = false

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            ZStack {
                Circle()
                    .fill(DesignSystem.Colors.ember.opacity(0.15))
                    .frame(width: 96, height: 96)
                    .scaleEffect(pulse ? 1.1 : 0.95)
                    .animation(.easeInOut(duration: 1.0).repeatForever(autoreverses: true), value: pulse)
                Image(systemName: "play.tv.fill")
                    .font(.system(size: 44, weight: .light))
                    .foregroundStyle(DesignSystem.Colors.ember)
            }
            .onAppear { pulse = true }

            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Casting to \(device.friendlyName)…")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("This usually takes 5–8 seconds. Watch your display.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
            }
            Spacer()
        }
    }
}

private struct CastRecoverStep: View {
    let device: CastDevice
    let attempt: Int
    let lastError: String
    let onRetry: () -> Void
    let onPickAnother: () -> Void

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(DesignSystem.Colors.warning)
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("\(device.friendlyName) didn't respond")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("This usually means the display is asleep. Try waking it (tap the screen, or say \"Hey Google\"), then retry.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
                Text("Last error: \(lastError)")
                    .font(DesignSystem.Typography.monoTiny)
                    .foregroundStyle(DesignSystem.Colors.textMuted)
                    .padding(.top, DesignSystem.Spacing.sm)
            }
            HStack(spacing: DesignSystem.Spacing.md) {
                Button(action: onPickAnother) {
                    Text("Pick another")
                        .font(DesignSystem.Typography.body)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: onRetry) {
                    Label("Retry", systemImage: "arrow.clockwise")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
    }
}

private struct CastConfirmStep: View {
    let device: CastDevice
    let onYes: () -> Void
    let onNo: () -> Void

    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(DesignSystem.Colors.ember)
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Did the test pattern appear?")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("Look at \(device.friendlyName). You should see the OpenBurnBar dashboard right now.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            HStack(spacing: DesignSystem.Spacing.md) {
                Button(action: onNo) {
                    Text("No, try another")
                        .font(DesignSystem.Typography.body)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.surfaceElevated))
                        .overlay(Capsule().strokeBorder(DesignSystem.Colors.border, lineWidth: 1))
                }
                .buttonStyle(.plain)
                Button(action: onYes) {
                    Label("Yes, I see it", systemImage: "checkmark")
                        .font(DesignSystem.Typography.headline)
                        .foregroundStyle(.white)
                        .padding(.horizontal, DesignSystem.Spacing.lg)
                        .padding(.vertical, DesignSystem.Spacing.sm)
                        .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
                }
                .buttonStyle(.plain)
                .keyboardShortcut(.defaultAction)
            }
            Spacer()
        }
    }
}

private struct CastFailedStep: View {
    let reason: String
    let onRetry: () -> Void
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            Image(systemName: "xmark.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(DesignSystem.Colors.error)
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("Setup didn't complete")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text(reason)
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button(action: onRetry) {
                Label("Start over", systemImage: "arrow.clockwise")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.lg)
                    .padding(.vertical, DesignSystem.Spacing.sm)
                    .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }
}

private struct CastDoneStep: View {
    let device: CastDevice
    let onClose: () -> Void
    var body: some View {
        VStack(spacing: DesignSystem.Spacing.xl) {
            Spacer()
            ZStack {
                Circle().fill(DesignSystem.Colors.success.opacity(0.15))
                    .frame(width: 96, height: 96)
                Image(systemName: "checkmark")
                    .font(.system(size: 44, weight: .semibold))
                    .foregroundStyle(DesignSystem.Colors.success)
            }
            VStack(spacing: DesignSystem.Spacing.sm) {
                Text("You're all set")
                    .font(DesignSystem.Typography.title)
                    .foregroundStyle(DesignSystem.Colors.textPrimary)
                Text("\(device.friendlyName) will keep showing your live token usage. You can change this anytime in Settings → Smart Display.")
                    .font(DesignSystem.Typography.body)
                    .foregroundStyle(DesignSystem.Colors.textSecondary)
                    .multilineTextAlignment(.center)
                    .frame(maxWidth: 380)
            }
            Button(action: onClose) {
                Text("Done")
                    .font(DesignSystem.Typography.headline)
                    .foregroundStyle(.white)
                    .padding(.horizontal, DesignSystem.Spacing.xl)
                    .padding(.vertical, DesignSystem.Spacing.md)
                    .background(Capsule().fill(DesignSystem.Colors.primaryGradient))
            }
            .buttonStyle(.plain)
            .keyboardShortcut(.defaultAction)
            Spacer()
        }
    }
}

// MARK: - Step indexing for the progress dots

private func stepIndex(_ step: CastWizardModel.Step) -> Int {
    switch step {
    case .welcome: return 0
    case .discover, .noDevices: return 1
    case .pick: return 2
    case .testing, .recover, .failed: return 3
    case .confirm: return 4
    case .done: return 4
    }
}

private func stepKey(_ step: CastWizardModel.Step) -> String {
    switch step {
    case .welcome: return "welcome"
    case .discover: return "discover"
    case .noDevices: return "noDevices"
    case .pick: return "pick"
    case .testing: return "testing"
    case .recover: return "recover"
    case .confirm: return "confirm"
    case .failed: return "failed"
    case .done: return "done"
    }
}
