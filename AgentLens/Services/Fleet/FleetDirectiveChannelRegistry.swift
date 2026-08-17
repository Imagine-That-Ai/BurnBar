import OpenBurnBarKernel
import Foundation

/// Resolves the write path for an approved directive.
///
/// Every declared roster CLI gets the inbox. Hermes may also attempt its
/// documented HTTP hook (typed ack → delivered; OpenAI 200 → submitted).
/// CLI one-shot is a separate, explicit "new turn" action — never implied
/// live-TUI inject, and never the default approve path.
enum FleetDirectiveChannelRegistry {
    static func channel(
        for targetAgent: BurnBarFleetAgentID?,
        inbox: FleetInboxChannel = FleetInboxChannel(),
        hermes: HermesDirectiveChannel = HermesDirectiveChannel()
    ) -> BurnBarFleetDirectiveChannel? {
        guard let targetAgent, BurnBarFleetAgentID.declaredRoster.contains(targetAgent) else {
            return nil
        }
        let extra: BurnBarFleetDirectiveChannel?
        if targetAgent == .hermes, hermes.supports(targetAgent: targetAgent) {
            extra = hermes
        } else {
            extra = nil
        }
        return FleetCompositeDirectiveChannel(inbox: inbox, extra: extra)
    }

    static func oneShot(for targetAgent: BurnBarFleetAgentID) -> FleetCLIOneShotChannel? {
        FleetCLIOneShotChannel(targetAgent: targetAgent)
    }
}

/// Inbox first, then an optional extra hook. Inbox success is `submitted`.
/// Extra `delivered` upgrades. Extra failure does not erase a successful
/// inbox write.
final class FleetCompositeDirectiveChannel: BurnBarFleetDirectiveChannel, Sendable {
    let inbox: FleetInboxChannel
    let extra: BurnBarFleetDirectiveChannel?

    init(inbox: FleetInboxChannel, extra: BurnBarFleetDirectiveChannel?) {
        self.inbox = inbox
        self.extra = extra
    }

    var channelName: String {
        if extra != nil { return "fleet-inbox+extra" }
        return inbox.channelName
    }

    func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
        inbox.supports(targetAgent: targetAgent)
    }

    func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
        let inboxOutcome = await inbox.deliver(directive)
        switch inboxOutcome {
        case .failed, .unsupported:
            return inboxOutcome
        case .delivered, .submitted:
            break
        }
        guard let extra else { return inboxOutcome }
        let extraOutcome = await extra.deliver(directive)
        switch extraOutcome {
        case .delivered:
            return .delivered
        case .submitted, .unsupported:
            return .submitted
        case .failed:
            // Inbox already wrote. Keep submitted; the extra hook is optional.
            return .submitted
        }
    }
}

/// Starts a **new turn** in the thread's repo when a documented binary is
/// on PATH. Never claims live TUI inject. Result is `submitted` at best.
final class FleetCLIOneShotChannel: BurnBarFleetDirectiveChannel, Sendable {
    let targetAgent: BurnBarFleetAgentID
    let binaryName: String
    let lookupPATH: (@Sendable (String) -> String?)?

    init(
        targetAgent: BurnBarFleetAgentID,
        lookupPATH: (@Sendable (String) -> String?)? = nil
    ) {
        self.targetAgent = targetAgent
        self.binaryName = Self.binaryName(for: targetAgent)
        self.lookupPATH = lookupPATH
    }

    var channelName: String { "cli-oneshot:\(binaryName)" }

    func supports(targetAgent: BurnBarFleetAgentID) -> Bool {
        targetAgent == self.targetAgent && !binaryName.isEmpty
    }

    func deliver(_ directive: BurnBarFleetDirective) async -> BurnBarFleetDeliveryOutcome {
        guard supports(targetAgent: directive.targetAgent ?? targetAgent) else {
            return .unsupported(reason: "No documented one-shot binary for \(targetAgent.wireValue).")
        }
        guard !binaryName.isEmpty else {
            return .unsupported(reason: "No documented one-shot binary for \(targetAgent.wireValue).")
        }
        let resolved = lookupPATH?(binaryName) ?? resolveBinary(binaryName)
        guard let resolved else {
            return .unsupported(reason: "\(binaryName) is not on PATH; inbox is the write path.")
        }
        return await runNewTurn(binary: resolved, directive: directive, cwd: nil)
    }

    static func binaryName(for agent: BurnBarFleetAgentID) -> String {
        switch agent {
        case .claudeCode: return "claude"
        case .codex: return "codex"
        case .grokCLI: return "grok"
        case .factoryDroid: return "droid"
        case .geminiCLI: return "gemini"
        case .pi: return "pi"
        case .cursor: return "cursor"
        case .kimi: return "kimi"
        case .hermes, .grokBot, .unknown: return ""
        }
    }

    private func resolveBinary(_ name: String) -> String? {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/which")
        process.arguments = [name]
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = Pipe()
        do {
            try process.run()
            process.waitUntilExit()
        } catch {
            return nil
        }
        guard process.terminationStatus == 0 else { return nil }
        let data = pipe.fileHandleForReading.readDataToEndOfFile()
        let path = String(data: data, encoding: .utf8)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
        return (path?.isEmpty == false) ? path : nil
    }

    private func runNewTurn(
        binary: String,
        directive: BurnBarFleetDirective,
        cwd: String?
    ) async -> BurnBarFleetDeliveryOutcome {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: binary)
        process.arguments = ["-p", directive.payload]
        if let cwd, FileManager.default.fileExists(atPath: cwd) {
            process.currentDirectoryURL = URL(fileURLWithPath: cwd, isDirectory: true)
        }
        process.standardOutput = Pipe()
        process.standardError = Pipe()
        do {
            try process.run()
        } catch {
            return .failed(reason: "one-shot failed to start: \(error.localizedDescription)")
        }
        process.waitUntilExit()
        if process.terminationStatus == 0 {
            return .submitted
        }
        return .failed(reason: "one-shot \(binaryName) exited \(process.terminationStatus)")
    }
}
