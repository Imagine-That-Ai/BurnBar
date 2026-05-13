import SwiftUI

// MARK: - SmartHub Setup Wizard (iPhone)
//
// Mirrors the macOS wizard but runs entirely off Firestore. The user's
// Mac is the actual Cast actor — this view publishes `cast_actions`
// documents and renders whatever the Mac writes back.
//
// Flow:
//   welcome → discovering (Mac scans) → pick → testing (Mac casts)
//          → confirm → done

struct SmartHubSetupWizardView: View {

    @Environment(\.dismiss) private var dismiss
    @Bindable var store: SmartHubStore

    @State private var step: Step = .welcome
    @State private var devices: [WizardCastDevice] = []
    @State private var pickedDevice: WizardCastDevice?
    @State private var failureMessage: String?

    enum Step: Equatable {
        case welcome
        case discovering
        case pick
        case testing
        case confirm
        case failed
        case done
    }

    var body: some View {
        NavigationStack {
            ZStack {
                Color(.systemGroupedBackground).ignoresSafeArea()
                content
                    .padding()
            }
            .navigationTitle("Set up Smart Display")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Close") { dismiss() }
                }
            }
        }
    }

    @ViewBuilder
    private var content: some View {
        switch step {
        case .welcome: welcomeStep
        case .discovering: discoveringStep
        case .pick: pickStep
        case .testing: testingStep
        case .confirm: confirmStep
        case .failed: failedStep
        case .done: doneStep
        }
    }

    private var welcomeStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "tv.and.hifispeaker.fill")
                .font(.system(size: 70, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Mirror OpenBurnBar to a Smart Display")
                    .font(.title2.bold())
                    .multilineTextAlignment(.center)
                Text("Your Mac will scan the network for Nest Hubs and Chromecasts. Make sure your Mac is awake.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Spacer()
            Button {
                Task { await runDiscovery() }
            } label: {
                Label("Find devices", systemImage: "magnifyingglass")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
                    .font(.headline)
            }
            .buttonStyle(.plain)
        }
    }

    private var discoveringStep: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().scaleEffect(1.4)
            Text("Asking your Mac to scan…")
                .font(.title3)
            Text("Takes about 6 seconds.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var pickStep: some View {
        VStack(alignment: .leading, spacing: 16) {
            Text("Found \(devices.count) device\(devices.count == 1 ? "" : "s")")
                .font(.title2.bold())
            Text("Pick which display to mirror to.")
                .foregroundStyle(.secondary)
            ScrollView {
                VStack(spacing: 8) {
                    ForEach(devices) { device in
                        Button {
                            pickedDevice = device
                            Task { await runTest(device: device) }
                        } label: {
                            HStack {
                                Image(systemName: iconName(for: device.iconKind))
                                    .frame(width: 32)
                                    .foregroundStyle(device.supportsDisplay
                                                     ? AnyShapeStyle(.tint)
                                                     : AnyShapeStyle(.secondary))
                                VStack(alignment: .leading, spacing: 2) {
                                    HStack(spacing: 6) {
                                        Text(device.friendlyName).font(.headline)
                                        if !device.supportsDisplay {
                                            Text("speaker")
                                                .font(.caption2.bold())
                                                .padding(.horizontal, 6).padding(.vertical, 2)
                                                .background(Color.orange.opacity(0.2), in: Capsule())
                                                .foregroundStyle(.orange)
                                        }
                                    }
                                    Text(device.supportsDisplay ? device.model : "Audio-only — won't show webpages")
                                        .font(.caption).foregroundStyle(.secondary)
                                }
                                Spacer()
                                Image(systemName: "chevron.right").foregroundStyle(.secondary)
                            }
                            .padding()
                            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
                            .opacity(device.supportsDisplay ? 1 : 0.55)
                        }
                        .buttonStyle(.plain)
                    }

                    missingDeviceHelper
                }
            }
        }
    }

    /// Shown beneath the device list when the scan returned no
    /// display-capable devices (only speakers / nothing). Mac-side
    /// mDNS can miss a Nest Hub if the Hub is asleep, on a different
    /// SSID/VLAN, or if macOS's Local Network permission has been
    /// denied — none of those are visible to the user, so spell out
    /// the most common causes and offer a one-tap rescan.
    @ViewBuilder
    private var missingDeviceHelper: some View {
        let displayCapable = devices.filter(\.supportsDisplay)
        if displayCapable.count < max(1, devices.count) || devices.isEmpty {
            VStack(alignment: .leading, spacing: 8) {
                Label(
                    displayCapable.isEmpty
                        ? "Don't see your Nest Hub?"
                        : "Missing a Nest Hub?",
                    systemImage: "questionmark.circle"
                )
                .font(.subheadline.bold())
                .foregroundStyle(.primary)

                Text(
                    """
                    Check these on the Mac running BurnBar:
                    • The Hub is awake and on the same Wi‑Fi as your Mac (not a guest network).
                    • System Settings → Privacy & Security → Local Network → BurnBar is **on**.
                    • Wi‑Fi router doesn't isolate client devices ("AP Isolation" / "Client Isolation" off).
                    """
                )
                .font(.caption)
                .foregroundStyle(.secondary)

                Button {
                    Task { await runDiscovery() }
                } label: {
                    Label("Scan again", systemImage: "arrow.clockwise")
                        .font(.subheadline.weight(.semibold))
                        .padding(.horizontal, 12)
                        .padding(.vertical, 8)
                }
                .buttonStyle(.bordered)
                .padding(.top, 2)
            }
            .padding()
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(Color(.secondarySystemGroupedBackground), in: RoundedRectangle(cornerRadius: 12))
            .padding(.top, 4)
        }
    }

    private var testingStep: some View {
        VStack(spacing: 24) {
            Spacer()
            ProgressView().scaleEffect(1.4)
            Text("Casting to \(pickedDevice?.friendlyName ?? "your display")…")
                .font(.title3)
            Text("Watch your screen for the dashboard.")
                .foregroundStyle(.secondary)
            Spacer()
        }
    }

    private var confirmStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "questionmark.circle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.tint)
            VStack(spacing: 8) {
                Text("Did the dashboard appear?")
                    .font(.title2.bold())
                Text("Look at \(pickedDevice?.friendlyName ?? "your display").")
                    .foregroundStyle(.secondary)
                    .multilineTextAlignment(.center)
            }
            HStack(spacing: 12) {
                Button {
                    step = .pick
                } label: {
                    Text("No, try another")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color(.secondarySystemGroupedBackground), in: Capsule())
                }
                Button {
                    Task { await saveSelection() }
                } label: {
                    Label("Yes, I see it", systemImage: "checkmark")
                        .frame(maxWidth: .infinity)
                        .padding()
                        .background(Color.accentColor, in: Capsule())
                        .foregroundStyle(.white)
                }
                .buttonStyle(.plain)
            }
            Spacer()
        }
    }

    private var failedStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "exclamationmark.triangle.fill")
                .font(.system(size: 56, weight: .light))
                .foregroundStyle(.orange)
            VStack(spacing: 8) {
                Text("Couldn't cast")
                    .font(.title2.bold())
                Text(failureMessage ?? "Tap your display to wake it, then try again.")
                    .multilineTextAlignment(.center)
                    .foregroundStyle(.secondary)
            }
            Button {
                step = .pick
            } label: {
                Text("Pick another device")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    private var doneStep: some View {
        VStack(spacing: 24) {
            Spacer()
            Image(systemName: "checkmark.circle.fill")
                .font(.system(size: 64, weight: .light))
                .foregroundStyle(.green)
            Text("All set")
                .font(.title.bold())
            Text("\(pickedDevice?.friendlyName ?? "Your display") will keep showing your live token usage.")
                .multilineTextAlignment(.center)
                .foregroundStyle(.secondary)
            Button { dismiss() } label: {
                Text("Done")
                    .frame(maxWidth: .infinity)
                    .padding()
                    .background(Color.accentColor, in: Capsule())
                    .foregroundStyle(.white)
            }
            .buttonStyle(.plain)
            Spacer()
        }
    }

    // MARK: - Actions

    private func runDiscovery() async {
        step = .discovering
        do {
            let found = try await store.runDiscovery()
            await MainActor.run {
                self.devices = found
                if found.isEmpty {
                    self.failureMessage = "No devices found. Make sure your Mac is awake and on the same Wi-Fi as your display."
                    self.step = .failed
                } else {
                    self.step = .pick
                }
            }
        } catch {
            await MainActor.run {
                self.failureMessage = error.localizedDescription
                self.step = .failed
            }
        }
    }

    private func runTest(device: WizardCastDevice) async {
        step = .testing
        do {
            let result = try await store.runTestCast(deviceId: device.serviceName)
            await MainActor.run {
                switch result {
                case .completed:
                    self.step = .confirm
                case .failed(let reason):
                    self.failureMessage = reason
                    self.step = .failed
                case .pending:
                    self.failureMessage = "Mac didn't respond."
                    self.step = .failed
                }
            }
        } catch {
            await MainActor.run {
                self.failureMessage = error.localizedDescription
                self.step = .failed
            }
        }
    }

    private func saveSelection() async {
        guard let pickedDevice else { return }
        do {
            _ = try await store.saveSelection(device: pickedDevice)
            await MainActor.run { self.step = .done }
        } catch {
            await MainActor.run {
                self.failureMessage = error.localizedDescription
                self.step = .failed
            }
        }
    }

    private func iconName(for iconKind: String) -> String {
        switch iconKind {
        case "nestHub", "nestHubMax": return "display"
        case "chromecast": return "tv"
        case "nestSpeaker": return "homepod"
        default: return "tv.and.hifispeaker.fill"
        }
    }
}
