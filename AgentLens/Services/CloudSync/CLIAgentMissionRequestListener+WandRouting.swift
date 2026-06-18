import Foundation
@preconcurrency import FirebaseFirestore
import OpenBurnBarCore

struct MissionGroupClaimContext: Sendable {
    let groupID: String
    let siblingIndex: Int
    let siblingCount: Int
    let parallelismLimit: Int
    let tierCap: Int
}

struct CLIAgentMissionWandRoutingSelection: Sendable {
    let requestedRuntime: String
    let modelID: String
    let displayName: String?
    let provider: String?
    let source: String?

    var claimSummaryFragment: String {
        let label = displayName?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty ?? modelID
        if let provider = provider?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return "The Wand routed this worker to \(label) via \(provider)."
        }
        return "The Wand routed this worker to \(label)."
    }
}

private struct MinistrySelectionPayload: Decodable, Sendable {
    let status: String?
    let selectedCount: Int?
    let requestedCount: Int?
    let reason: String?
    let selectedForIndex: MinistryCandidate?
}

private struct MinistryCandidate: Decodable, Sendable {
    let arg: String?
    let model: String?
    let displayName: String?
    let provider: String?
    let source: String?
}

private enum CLIAgentMissionWandRoutingError: LocalizedError, Sendable {
    case selectorUnavailable
    case selectorFailed(String)
    case insufficientCandidates(requested: Int, selected: Int, reason: String?)
    case missingModelArgument

    var errorDescription: String? {
        switch self {
        case .selectorUnavailable:
            return "The Wand routing selector is not available on this Mac."
        case let .selectorFailed(reason):
            return "The Wand routing selector failed: \(reason)"
        case let .insufficientCandidates(requested, selected, reason):
            let detail = reason.map { " \($0)." } ?? ""
            return "The Wand could only find \(selected) route-eligible model(s) for \(requested) worker(s).\(detail)"
        case .missingModelArgument:
            return "The Wand routing selector returned no launchable model argument."
        }
    }
}

extension CLIAgentMissionRequestListener {
    func resolveWandRoutingIfNeeded(
        context: MissionGroupClaimContext?,
        data: [String: Any]
    ) async throws -> CLIAgentMissionWandRoutingSelection? {
        guard let context else { return nil }
        let payload = try await CLIAgentMissionWandRouter.select(
            context: context,
            targetProject: (data["targetProject"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
        )
        let requested = payload.requestedCount ?? context.siblingCount
        let selected = payload.selectedCount ?? 0
        guard payload.status == "ok" else {
            throw CLIAgentMissionWandRoutingError.selectorFailed(payload.reason ?? "unknown selector failure")
        }
        guard selected >= requested else {
            throw CLIAgentMissionWandRoutingError.insufficientCandidates(
                requested: requested,
                selected: selected,
                reason: payload.reason
            )
        }
        guard let candidate = payload.selectedForIndex,
              let modelID = candidate.arg?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty else {
            throw CLIAgentMissionWandRoutingError.missingModelArgument
        }
        return CLIAgentMissionWandRoutingSelection(
            requestedRuntime: ChatBackendID.droid.rawValue,
            modelID: modelID,
            displayName: candidate.displayName?.nilIfEmpty ?? candidate.model?.nilIfEmpty,
            provider: candidate.provider?.nilIfEmpty,
            source: candidate.source?.nilIfEmpty
        )
    }
}

private enum CLIAgentMissionWandRouter {
    static func select(
        context: MissionGroupClaimContext,
        targetProject: String?
    ) async throws -> MinistrySelectionPayload {
        try await Task.detached(priority: .utility) {
            guard let scriptURL = selectorScriptURL() else {
                throw CLIAgentMissionWandRoutingError.selectorUnavailable
            }
            let repoRoot = repoRootURL(from: scriptURL)
            let process = Process()
            process.executableURL = URL(fileURLWithPath: "/usr/bin/env")
            var arguments = [
                "python3",
                scriptURL.path,
                "--count",
                "\(context.siblingCount)",
                "--sibling-index",
                "\(context.siblingIndex)"
            ]
            if let repoRoot {
                arguments += ["--repo-root", repoRoot.path]
            }
            process.arguments = arguments

            var environment = ProcessInfo.processInfo.environment
            environment["OPENBURNBAR_WAND_PARALLEL_MAX"] = "\(context.tierCap)"
            if let targetProject {
                environment["OPENBURNBAR_WAND_TARGET_PROJECT"] = targetProject
            }
            process.environment = environment

            let stdout = Pipe()
            let stderr = Pipe()
            process.standardOutput = stdout
            process.standardError = stderr
            try process.run()

            let deadline = Date().addingTimeInterval(12)
            while process.isRunning && Date() < deadline {
                try await Task.sleep(nanoseconds: 50_000_000)
            }
            if process.isRunning {
                process.terminate()
                process.waitUntilExit()
                throw CLIAgentMissionWandRoutingError.selectorFailed("selector timed out")
            }

            let output = stdout.fileHandleForReading.readDataToEndOfFile()
            let errorOutput = stderr.fileHandleForReading.readDataToEndOfFile()
            let decoder = JSONDecoder()
            do {
                let payload = try decoder.decode(MinistrySelectionPayload.self, from: output)
                if process.terminationStatus != 0, payload.status != "ok" {
                    let reason = payload.reason
                        ?? String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty
                        ?? "exit \(process.terminationStatus)"
                    throw CLIAgentMissionWandRoutingError.selectorFailed(reason)
                }
                return payload
            } catch let routingError as CLIAgentMissionWandRoutingError {
                throw routingError
            } catch {
                let stderrText = String(data: errorOutput, encoding: .utf8)?.trimmingCharacters(in: .whitespacesAndNewlines)
                throw CLIAgentMissionWandRoutingError.selectorFailed(stderrText?.nilIfEmpty ?? error.localizedDescription)
            }
        }.value
    }

    private static func selectorScriptURL() -> URL? {
        let env = ProcessInfo.processInfo.environment
        if let override = env["OPENBURNBAR_MINISTRY_SELECTOR_CLI"]?.trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            let url = URL(fileURLWithPath: override)
            if FileManager.default.isReadableFile(atPath: url.path) { return url }
        }
        if let resourceURL = Bundle.main.resourceURL?
            .appendingPathComponent("tools/openburnbar-mcp/select_wand_models.py"),
            FileManager.default.isReadableFile(atPath: resourceURL.path) {
            return resourceURL
        }
        var probe = URL(fileURLWithPath: #filePath)
        for _ in 0..<8 {
            let candidate = probe
                .appendingPathComponent("tools")
                .appendingPathComponent("openburnbar-mcp")
                .appendingPathComponent("select_wand_models.py")
            if FileManager.default.isReadableFile(atPath: candidate.path) {
                return candidate
            }
            probe.deleteLastPathComponent()
        }
        return nil
    }

    private static func repoRootURL(from scriptURL: URL) -> URL? {
        if let override = ProcessInfo.processInfo.environment["OPENBURNBAR_REPO_ROOT"]?
            .trimmingCharacters(in: .whitespacesAndNewlines).nilIfEmpty {
            return URL(fileURLWithPath: override)
        }
        var probe = scriptURL
        for _ in 0..<8 {
            let catalog = probe
                .appendingPathComponent("OpenBurnBarCore")
                .appendingPathComponent("Sources")
                .appendingPathComponent("OpenBurnBarCore")
                .appendingPathComponent("Resources")
                .appendingPathComponent("catalog.json")
            if FileManager.default.isReadableFile(atPath: catalog.path) {
                return probe
            }
            probe.deleteLastPathComponent()
        }
        return nil
    }
}

private extension String {
    var nilIfEmpty: String? {
        let trimmed = trimmingCharacters(in: .whitespacesAndNewlines)
        return trimmed.isEmpty ? nil : trimmed
    }
}
