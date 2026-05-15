import SwiftUI
import OpenBurnBarCore

// MARK: - Fan-Out Composer Sheet (Hermes Square §6.4 / S2)
//
// Lets the user write a prompt, pick 2–5 runtimes, and dispatch the same
// brief to all of them in parallel via `CLIAgentMissionDispatcher.dispatchFanOut`.
// Returns the resulting `groupID` to the caller so it can open the
// `MissionFanOutGroup` card in the inbox.

struct FanOutComposerSheet: View {
    @Environment(\.dismiss) private var dismiss

    let registry: AgentIdentityRegistry
    let onDispatched: (CLIAgentMissionDispatcher.FanOutDispatchResult) -> Void

    @State private var prompt: String = ""
    @State private var title: String = ""
    @State private var selectedRuntimes: Set<String> = ["claude", "codex", "hermes"]
    @State private var missionKind: MissionConsoleKind = .diligence
    @State private var depth: MissionConsoleDepth = .standard
    @State private var approvalMode: MissionConsoleApprovalMode = .existingPolicy
    @State private var commandsAllowed: Bool = false
    @State private var fileEditsAllowed: Bool = false
    @State private var mergeStrategy: MissionGroupMergeStrategy = .pickOne
    @State private var dispatching: Bool = false
    @State private var errorMessage: String?

    private var dispatchableAgents: [AgentIdentity] {
        registry.identities.filter { $0.tier == .service && $0.runtimeID != nil }
    }

    private var forecast: MissionGroupDocument.ForecastBand {
        let kindDefault = missionKind
        let depthDefault = depth
        let runtimes = selectedRuntimes
        let consoleApproval = approvalMode
        let cmdAllowed = commandsAllowed
        let fileAllowed = fileEditsAllowed
        let titleSnap = title.isEmpty ? "Fan-out" : title
        let promptSnap = prompt.isEmpty ? "—" : prompt
        let children: [MissionConsoleForecast] = runtimes.map { token in
            let draft = MissionConsoleDispatchRequest(
                title: titleSnap,
                prompt: promptSnap,
                kind: kindDefault,
                runtimeID: token,
                targetProject: nil,
                depth: depthDefault,
                approvalMode: consoleApproval,
                commandsAllowed: cmdAllowed,
                fileEditsAllowed: fileAllowed
            )
            let runtime = MissionConsoleRuntime(
                id: token, displayName: token.capitalized,
                callSign: String(token.prefix(3)).uppercased(), provider: .factory
            )
            return MissionConsoleForecastComputer.forecast(for: draft, runtime: runtime)
        }
        return MissionGroupForecastComputer.combine(children: children, parallelismLimit: runtimes.count)
    }

    var body: some View {
        NavigationStack {
            Form {
                Section(header: Text("Brief")) {
                    TextField("Title (optional)", text: $title)
                    TextEditor(text: $prompt)
                        .frame(minHeight: 96)
                        .overlay(alignment: .topLeading) {
                            if prompt.isEmpty {
                                Text("What should the fleet work on?")
                                    .foregroundStyle(DesignSystemColors.textMuted)
                                    .padding(.top, 8).padding(.leading, 4)
                            }
                        }
                }

                Section(header: Text("Runtimes (\(selectedRuntimes.count) of \(dispatchableAgents.count))")) {
                    ForEach(dispatchableAgents, id: \.id) { identity in
                        if let runtime = identity.runtimeID {
                            Toggle(isOn: Binding(
                                get: { selectedRuntimes.contains(runtime.rawValue) },
                                set: { newValue in
                                    if newValue {
                                        selectedRuntimes.insert(runtime.rawValue)
                                    } else if selectedRuntimes.count > 2 {
                                        selectedRuntimes.remove(runtime.rawValue)
                                    }
                                }
                            )) {
                                HStack(spacing: 8) {
                                    ZStack {
                                        Circle().fill(Color(hex: identity.paletteHex))
                                            .frame(width: 20, height: 20)
                                        Text(identity.glyph)
                                            .font(.system(size: 10, weight: .bold))
                                            .foregroundStyle(.white)
                                    }
                                    Text(identity.displayName)
                                }
                            }
                        }
                    }
                }

                Section(header: Text("Mission")) {
                    Picker("Kind", selection: $missionKind) {
                        ForEach(MissionConsoleKind.allCases) { kind in
                            Text(kind.displayName).tag(kind)
                        }
                    }
                    Picker("Depth", selection: $depth) {
                        ForEach(MissionConsoleDepth.allCases) { d in
                            Text(d.displayName).tag(d)
                        }
                    }
                    Picker("Approvals", selection: $approvalMode) {
                        ForEach(MissionConsoleApprovalMode.allCases) { m in
                            Text(m.displayName).tag(m)
                        }
                    }
                    Toggle("Allow shell commands", isOn: $commandsAllowed)
                    Toggle("Allow file edits", isOn: $fileEditsAllowed)
                    Picker("Merge", selection: $mergeStrategy) {
                        ForEach(MissionGroupMergeStrategy.allCases, id: \.self) { s in
                            Text(s.rawValue.capitalized).tag(s)
                        }
                    }
                }

                Section(header: Text("Forecast (worst-case sum)")) {
                    HStack {
                        Text("Tokens")
                        Spacer()
                        Text(MissionConsoleFormatting.tokenRange(forecast.tokensLow, forecast.tokensHigh))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("Cost")
                        Spacer()
                        Text(MissionConsoleFormatting.costRange(forecast.costLowUSD, forecast.costHighUSD))
                            .monospacedDigit()
                    }
                    HStack {
                        Text("ETA")
                        Spacer()
                        Text(MissionConsoleFormatting.durationRange(forecast.etaLow, forecast.etaHigh))
                            .monospacedDigit()
                    }
                }

                if let errorMessage {
                    Section {
                        Text(errorMessage)
                            .font(.caption)
                            .foregroundStyle(DesignSystemColors.error)
                    }
                }
            }
            .navigationTitle("Fan-out dispatch")
            .navigationBarTitleDisplayMode(.inline)
            .toolbar {
                ToolbarItem(placement: .cancellationAction) {
                    Button("Cancel") { dismiss() }
                }
                ToolbarItem(placement: .confirmationAction) {
                    if dispatching {
                        ProgressView().controlSize(.small)
                    } else {
                        Button("Dispatch") {
                            Task { await dispatch() }
                        }
                        .disabled(!canDispatch)
                    }
                }
            }
        }
    }

    private var canDispatch: Bool {
        !prompt.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty
            && selectedRuntimes.count >= 2
    }

    private func dispatch() async {
        dispatching = true
        errorMessage = nil
        defer { dispatching = false }
        do {
            let runtimes = Array(selectedRuntimes)
            let result = try await CLIAgentMissionDispatcher.shared.dispatchFanOut(
                title: title.trimmingCharacters(in: .whitespacesAndNewlines),
                prompt: prompt,
                missionKind: missionKind.rawValue,
                runtimeTokens: runtimes,
                targetProject: nil,
                depth: depth.rawValue,
                approvalMode: approvalMode.rawValue,
                commandsAllowed: commandsAllowed,
                fileEditsAllowed: fileEditsAllowed,
                parallelismLimit: nil,
                mergeStrategy: mergeStrategy
            )
            onDispatched(result)
            dismiss()
        } catch {
            errorMessage = error.localizedDescription
        }
    }
}
