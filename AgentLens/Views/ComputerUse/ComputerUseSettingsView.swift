#if canImport(SwiftUI) && canImport(AppKit) && !DISTRIBUTION_MAS
import AppKit
import ApplicationServices
import OpenBurnBarCore
import OpenBurnBarComputerUseCore
import SwiftUI

/// Settings surface for direct-download Computer Use.
///
/// The Mac App Store build compiles this out with the rest of Path C.
/// This view intentionally reads live local state instead of inferring
/// readiness from docs or rollout flags.
struct ComputerUseSettingsView: View {
    private struct AuditOperationStatus: Equatable {
        var kind: Kind
        var message: String

        enum Kind: Equatable {
            case idle
            case running
            case succeeded
            case failed
        }
    }

    @StateObject private var panelModel = ComputerUseSessionPanelModel()
    @StateObject private var wizardModel = ComputerUseSetupWizardModel()
    @State private var accessibilityTrusted = AXIsProcessTrusted()
    @State private var showingSetupWizard = false
    @State private var auditSessionId = ""
    @State private var auditIncludeScreenshots = true
    @State private var auditAdvancedExpanded = false
    @State private var auditNotarizationOptIn = false
    @State private var auditStatus = AuditOperationStatus(
        kind: .idle,
        message: "Enter a session id to validate, export, or notarize its local audit chain."
    )
    private let runtimeController: ComputerUseRuntimeController?

    init(runtimeController: ComputerUseRuntimeController? = nil) {
        self.runtimeController = runtimeController
    }

    var body: some View {
        ScrollView {
            VStack(alignment: .leading, spacing: 18) {
                header
                readiness
                    .settingsAnchor(SettingsAnchor.computerUseReadiness)
                actions
                ComputerUseSessionPanel(model: activePanelModel)
                    .frame(maxWidth: .infinity, alignment: .leading)
                auditOperations
            }
            .padding(24)
            .frame(maxWidth: 900, alignment: .leading)
        }
        .onAppear(perform: configureModels)
        .sheet(isPresented: $showingSetupWizard) {
            ComputerUseSetupWizard(
                model: wizardModel,
                onComplete: {
                    showingSetupWizard = false
                    refreshReadiness()
                },
                onCancel: {
                    showingSetupWizard = false
                    refreshReadiness()
                }
            )
        }
    }

    private var header: some View {
        VStack(alignment: .leading, spacing: 6) {
            Text("Computer Use")
                .font(.system(size: 26, weight: .semibold))
            Text("Browser automation, Mac input, approval, panic halt, and audit-chain controls for direct-download builds.")
                .font(.system(size: 13))
                .foregroundStyle(.secondary)
        }
    }

    private var readiness: some View {
        VStack(alignment: .leading, spacing: 10) {
            Text("Readiness")
                .font(.system(size: 13, weight: .semibold))
            statusRow(
                icon: accessibilityTrusted ? "checkmark.circle.fill" : "exclamationmark.triangle.fill",
                title: "Accessibility permission",
                detail: accessibilityTrusted
                    ? "Granted. OpenBurnBar can post approved CGEvents."
                    : "Missing. System Computer Use cannot click or type until this is granted.",
                color: accessibilityTrusted ? .green : .orange
            )
            statusRow(
                icon: "shield.lefthalf.filled",
                title: "Mac App Store build guard",
                detail: "Path C is compiled out when DISTRIBUTION_MAS is set.",
                color: .blue
            )
            statusRow(
                icon: "link",
                title: "Phone control stream",
                detail: "The iroh host now exposes a Computer Use control dispatcher for active sessions.",
                color: .teal
            )
            statusRow(
                icon: "person.crop.circle.badge.checkmark",
                title: "Approval presenter",
                detail: "Daemon-originated approvals are presented by an app-wide floating panel, not only this Settings screen.",
                color: .purple
            )
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private var actions: some View {
        HStack(spacing: 10) {
            Button {
                showingSetupWizard = true
            } label: {
                Label("Run Setup", systemImage: "wand.and.stars")
            }
            .buttonStyle(.borderedProminent)

            Button {
                requestAccessibility()
            } label: {
                Label("Open Accessibility", systemImage: "lock.open")
            }
            .buttonStyle(.bordered)

            Button {
                runPlaywrightInstaller()
            } label: {
                Label("Install Playwright", systemImage: "globe")
            }
            .buttonStyle(.bordered)

            Button {
                startSystemSession()
            } label: {
                Label("Start System Session", systemImage: "play.circle")
            }
            .buttonStyle(.bordered)
            .disabled(runtimeController == nil)

            Button {
                refreshReadiness()
            } label: {
                Label("Refresh", systemImage: "arrow.clockwise")
            }
            .buttonStyle(.bordered)
        }
    }

    private var activePanelModel: ComputerUseSessionPanelModel {
        runtimeController?.panelModel ?? panelModel
    }

    private var auditOperations: some View {
        VStack(alignment: .leading, spacing: 12) {
            VStack(alignment: .leading, spacing: 4) {
                Text("Audit operations")
                    .font(.system(size: 13, weight: .semibold))
                Text("Validate the local hash chain, export a signed .tar.gz archive, or notarize the terminal chain head.")
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }

            HStack(spacing: 10) {
                TextField("Session id", text: $auditSessionId)
                    .textFieldStyle(.roundedBorder)
                    .font(.system(size: 12, design: .monospaced))
                Toggle("Screenshots", isOn: $auditIncludeScreenshots)
                    .toggleStyle(.checkbox)
                    .font(.system(size: 12))
            }

            HStack(spacing: 10) {
                Button {
                    validateAuditChain()
                } label: {
                    Label("Validate", systemImage: "checkmark.seal")
                }
                .buttonStyle(.bordered)
                .disabled(trimmedAuditSessionId.isEmpty || auditStatus.kind == .running)

                Button {
                    exportAuditArchive()
                } label: {
                    Label("Export", systemImage: "archivebox")
                }
                .buttonStyle(.bordered)
                .disabled(trimmedAuditSessionId.isEmpty || auditStatus.kind == .running)
            }

            DisclosureGroup(isExpanded: $auditAdvancedExpanded) {
                VStack(alignment: .leading, spacing: 10) {
                    Toggle("Allow OpenTimestamps notarization for this session", isOn: $auditNotarizationOptIn)
                        .toggleStyle(.checkbox)
                        .font(.system(size: 12))
                    Text("Submits only the audit-chain root hash to OpenTimestamps and stores the returned .ots proof beside the local chain.")
                        .font(.system(size: 12))
                        .foregroundStyle(.secondary)
                    Button {
                        notarizeAuditChain()
                    } label: {
                        Label("Notarize", systemImage: "clock.badge.checkmark")
                    }
                    .buttonStyle(.bordered)
                    .disabled(
                        trimmedAuditSessionId.isEmpty
                            || auditStatus.kind == .running
                            || !auditNotarizationOptIn
                    )
                }
                .padding(.top, 8)
            } label: {
                Label("Advanced", systemImage: "wrench.and.screwdriver")
                    .font(.system(size: 13, weight: .semibold))
            }

            statusRow(
                icon: auditStatusIcon,
                title: "Audit status",
                detail: auditStatus.message,
                color: auditStatusColor
            )
        }
        .padding(16)
        .background(.background.secondary, in: RoundedRectangle(cornerRadius: 8))
    }

    private func statusRow(icon: String, title: String, detail: String, color: Color) -> some View {
        HStack(alignment: .top, spacing: 10) {
            Image(systemName: icon)
                .foregroundStyle(color)
                .frame(width: 22)
            VStack(alignment: .leading, spacing: 2) {
                Text(title)
                    .font(.system(size: 12, weight: .semibold))
                Text(detail)
                    .font(.system(size: 12))
                    .foregroundStyle(.secondary)
            }
        }
    }

    private func configureModels() {
        refreshReadiness()
        runtimeController?.refreshEntitlement()
        guard runtimeController == nil else { return }
        panelModel.scopeRules = ComputerUseDenyRegistry.builtInRules
        panelModel.setTrustMode = { mode in
            panelModel.liveTrustMode = mode
        }
        panelModel.addRule = { rule in
            panelModel.scopeRules.append(rule)
        }
        panelModel.panicHalt = {
            panelModel.recentAuditEntries.insert(
                HermesRealtimeRelayActionLogEntry(
                    entryIndex: panelModel.recentAuditEntries.count,
                    timestamp: Date(),
                    actionKind: "panic.user_halt",
                    summary: "Panic halt requested from Settings",
                    status: .panicHalted
                ),
                at: 0
            )
        }
        wizardModel.requestAccessibility = {
            requestAccessibility()
        }
        wizardModel.installPlaywright = {
            runPlaywrightInstaller()
        }
        wizardModel.runSampleAction = {
            runSetupSmoke()
        }
    }

    private var trimmedAuditSessionId: String {
        auditSessionId.trimmingCharacters(in: .whitespacesAndNewlines)
    }

    private var auditStatusIcon: String {
        switch auditStatus.kind {
        case .idle:
            return "info.circle"
        case .running:
            return "hourglass"
        case .succeeded:
            return "checkmark.circle.fill"
        case .failed:
            return "xmark.circle.fill"
        }
    }

    private var auditStatusColor: Color {
        switch auditStatus.kind {
        case .idle:
            return .blue
        case .running:
            return .yellow
        case .succeeded:
            return .green
        case .failed:
            return .red
        }
    }

    private func refreshReadiness() {
        accessibilityTrusted = AXIsProcessTrusted()
        wizardModel.accessibilityGranted = accessibilityTrusted
        wizardModel.playwrightReady = FileManager.default.fileExists(
            atPath: "OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js"
        )
    }

    private func requestAccessibility() {
        _ = AXIsProcessTrustedWithOptions(["AXTrustedCheckOptionPrompt": true] as CFDictionary)
        if let url = URL(string: "x-apple.systempreferences:com.apple.preference.security?Privacy_Accessibility") {
            NSWorkspace.shared.open(url)
        }
        refreshReadiness()
    }

    private func runPlaywrightInstaller() {
        guard let script = Bundle.main.path(forResource: "install-playwright", ofType: "sh") else {
            if let url = URL(string: "file://\(FileManager.default.currentDirectoryPath)/scripts/install-playwright.sh") {
                NSWorkspace.shared.open(url)
            }
            return
        }
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/bin/bash")
        process.arguments = [script]
        try? process.run()
    }

    private func startSystemSession() {
        guard let runtimeController else { return }
        Task { @MainActor in
            do {
                let response = try await runtimeController.startSystemSession(
                    trustMode: activePanelModel.liveTrustMode
                )
                auditSessionId = response.sessionId
                auditStatus = AuditOperationStatus(
                    kind: .succeeded,
                    message: "System session started. Audit head \(response.manifestHashHex.prefix(16))."
                )
            } catch {
                auditStatus = AuditOperationStatus(
                    kind: .failed,
                    message: "Could not start system session: \(error.localizedDescription)"
                )
            }
        }
    }

    private func runSetupSmoke() {
        wizardModel.sampleIsRunning = true
        wizardModel.sampleStatus.openCalculator = .running
        let calculatorURL = URL(fileURLWithPath: "/System/Applications/Calculator.app")
        NSWorkspace.shared.openApplication(at: calculatorURL, configuration: NSWorkspace.OpenConfiguration()) { _, error in
            Task { @MainActor in
                wizardModel.sampleStatus.openCalculator = error == nil ? .succeeded : .failed
                wizardModel.sampleStatus.click2 = .pending
                wizardModel.sampleStatus.clickPlus = .pending
                wizardModel.sampleStatus.click2Again = .pending
                wizardModel.sampleStatus.clickEquals = .pending
                wizardModel.sampleStatus.verifiedResult = error == nil ? .succeeded : .failed
                wizardModel.sampleIsRunning = false
            }
        }
    }

    private func validateAuditChain() {
        let sessionId = trimmedAuditSessionId
        guard !sessionId.isEmpty else { return }
        auditStatus = AuditOperationStatus(kind: .running, message: "Validating audit chain for \(sessionId)...")
        Task { @MainActor in
            do {
                let result = try validateLocalAuditChain(sessionId: sessionId)
                if result.isValid {
                    auditStatus = AuditOperationStatus(
                        kind: .succeeded,
                        message: "Valid chain: \(result.entryCount) entries linked to head \(result.headHashHex?.prefix(16) ?? "unknown")."
                    )
                } else {
                    let index = result.firstInvalidEntryIndex.map(String.init) ?? "unknown"
                    auditStatus = AuditOperationStatus(
                        kind: .failed,
                        message: "Tamper or corruption detected at entry \(index): \(String(describing: result.firstInvalidReason))."
                    )
                }
            } catch {
                auditStatus = AuditOperationStatus(kind: .failed, message: error.localizedDescription)
            }
        }
    }

    private func exportAuditArchive() {
        let sessionId = trimmedAuditSessionId
        guard !sessionId.isEmpty else { return }
        auditStatus = AuditOperationStatus(kind: .running, message: "Exporting audit archive for \(sessionId)...")
        Task { @MainActor in
            do {
                let response = try await OpenBurnBarDaemonManager.shared.exportComputerUseAudit(
                    ComputerUseAuditExportRequest(
                        sessionId: sessionId,
                        includeScreenshots: auditIncludeScreenshots
                    )
                )
                let archiveURL = URL(fileURLWithPath: response.archiveURL)
                NSWorkspace.shared.activateFileViewerSelecting([archiveURL])
                let signatureSuffix = response.signatureURL == nil
                    ? ""
                    : " Signature sidecar: \(URL(fileURLWithPath: response.signatureURL!).lastPathComponent)."
                let readbackSuffix: String
                if response.signatureURL != nil {
                    if let runtimeController {
                        do {
                            try await runtimeController.publishAuditExportSignerReadback(for: response)
                            readbackSuffix = " Signer key readback published."
                        } catch {
                            readbackSuffix = " Signer key readback was not published: \(error.localizedDescription)"
                        }
                    } else {
                        readbackSuffix = " Signer key readback was not published: Computer Use runtime is not attached."
                    }
                } else {
                    readbackSuffix = ""
                }
                auditStatus = AuditOperationStatus(
                    kind: .succeeded,
                    message: "Exported \(response.entryCount) archive entries (\(response.archiveSizeBytes) bytes) to \(archiveURL.lastPathComponent).\(signatureSuffix)\(readbackSuffix)"
                )
            } catch {
                auditStatus = AuditOperationStatus(kind: .failed, message: error.localizedDescription)
            }
        }
    }

    private func notarizeAuditChain() {
        let sessionId = trimmedAuditSessionId
        guard !sessionId.isEmpty else { return }
        auditStatus = AuditOperationStatus(kind: .running, message: "Notarizing audit-chain head for \(sessionId)...")
        Task { @MainActor in
            do {
                let result = try validateLocalAuditChain(sessionId: sessionId)
                guard result.isValid, let headHash = result.headHashHex else {
                    throw NSError(
                        domain: "ComputerUseAudit",
                        code: 1,
                        userInfo: [NSLocalizedDescriptionKey: "Audit chain must validate before notarization."]
                    )
                }
                let configuration = ComputerUseOpenTimestampsClient.Configuration()
                let client = ComputerUseOpenTimestampsClient(configuration: configuration)
                let chainURL = auditChainURL(sessionId: sessionId)
                let proof = try await client.notarize(chainFileAt: chainURL)
                let proofURL = try ComputerUseOpenTimestampsArchive.writeProof(
                    proofBytes: proof,
                    sourceChainURL: chainURL,
                    calendarURL: configuration.calendarURL
                )
                NSWorkspace.shared.activateFileViewerSelecting([proofURL])
                auditStatus = AuditOperationStatus(
                    kind: .succeeded,
                    message: "Wrote OpenTimestamps proof \(proofURL.lastPathComponent) for head \(headHash.prefix(16))."
                )
            } catch {
                auditStatus = AuditOperationStatus(kind: .failed, message: error.localizedDescription)
            }
        }
    }

    private func validateLocalAuditChain(sessionId: String) throws -> ComputerUseAuditChain.ValidationResult {
        let manifestURL = auditSessionDirectory(sessionId: sessionId).appendingPathComponent("manifest.json")
        let chainURL = auditChainURL(sessionId: sessionId)
        let headURL = auditSessionDirectory(sessionId: sessionId).appendingPathComponent("head.json")
        let manifest = try ComputerUseAuditHasher.canonicalJSONDecoder.decode(
            ComputerUseSessionManifest.self,
            from: Data(contentsOf: manifestURL)
        )
        let expectedHeadHash: String?
        if FileManager.default.fileExists(atPath: headURL.path) {
            struct HeadFile: Decodable { let hashHex: String }
            expectedHeadHash = try ComputerUseAuditHasher.canonicalJSONDecoder
                .decode(HeadFile.self, from: Data(contentsOf: headURL))
                .hashHex
        } else {
            expectedHeadHash = nil
        }
        return try ComputerUseAuditChain().validate(
            at: chainURL,
            sessionManifestHashHex: ComputerUseAuditChain().hashSessionManifest(manifest),
            expectedHeadHashHex: expectedHeadHash
        )
    }

    private func auditSessionDirectory(sessionId: String) -> URL {
        OpenBurnBarAppPaths.live().supportDirectory
            .appendingPathComponent("computer-use-audit", isDirectory: true)
            .appendingPathComponent(sessionId, isDirectory: true)
    }

    private func auditChainURL(sessionId: String) -> URL {
        auditSessionDirectory(sessionId: sessionId)
            .appendingPathComponent("chain.jsonl", isDirectory: false)
    }
}
#endif
