import Foundation
import OpenBurnBarKernel

// MARK: - Plasma model ladder
//
// The asset's three-tier cascade is `Gateway Proxy › Model Provider › Model`.
// BurnBar's honest equivalent, and the one this file builds, is:
//
//   Rung 1  AGENT     which agent answers      (ChatBackendID)
//   Rung 2  PROVIDER  whose weights it calls   (grouped from the live catalog)
//   Rung 3  MODEL     the exact model id sent  (what the request carries)
//
// The old picker was one flat `Menu` that mixed all three into a single string
// per row — `"Sonnet 4.6 (claude-sonnet-4-6) · Claude Code model catalog · 47%
// left"` — with no way to see which providers an agent can even reach. The
// ladder splits that string into the three questions it was answering at once.
//
// Everything here is pure and synchronous so the cascade's rules — grouping,
// the automatic row's placement, the single-provider skip, orphaned selections
// — are unit-testable without a live catalog or a rendered view.

/// Which rung of the cascade is on screen.
enum PlasmaLadderLevel: Int, CaseIterable, Equatable {
    case agent = 1
    case provider = 2
    case model = 3
}

/// One selectable model, already flattened out of whichever catalog produced it.
struct PlasmaModelEntry: Identifiable, Equatable {
    /// The exact `model` argument the request will carry. Empty means "let the
    /// agent decide", which is a real, selectable choice — not a missing value.
    let id: String
    let title: String
    let detail: String?
    let providerID: String
    /// The label the catalog itself used, which beats any id-derived guess for
    /// a provider this build has never heard of.
    let providerName: String?
    let isDisabled: Bool

    init(
        id: String,
        title: String,
        detail: String? = nil,
        providerID: String,
        providerName: String? = nil,
        isDisabled: Bool = false
    ) {
        self.id = id
        self.title = title
        self.detail = detail
        self.providerID = providerID
        self.providerName = providerName
        self.isDisabled = isDisabled
    }
}

/// Rung 2: every provider the active agent can actually reach right now.
struct PlasmaProviderGroup: Identifiable, Equatable {
    let id: String
    let displayName: String
    /// Where these models are billed from — "Droid Core quota", "OpenBurnBar
    /// proxy", "Claude Code model catalog". The single most load-bearing fact
    /// the flat menu buried mid-string.
    let sourceSummary: String?
    let entries: [PlasmaModelEntry]
}

enum PlasmaModelLadder {
    /// Identity for the synthetic "let the agent decide" choice. A catalog is
    /// free to advertise its own empty-id default row meaning the same thing,
    /// and both land in one `ForEach`, so the synthetic one is namespaced out
    /// of the catalog's id space rather than colliding with it.
    static let automaticChoiceID = "__plasma_automatic"

    /// Cap on how many distinct billing sources a provider row spells out
    /// before it summarises. Two fit the pill; a third would truncate it.
    private static let sourceSummaryLimit = 2

    // MARK: Group builders

    /// Groups a Mac CLI runtime catalog (Codex, Claude Code, Droid, Forge, …).
    static func groups(fromCLI options: [CLIRuntimeModelOption]) -> [PlasmaProviderGroup] {
        let entries = options.map(entry(fromCLI:))
        let sourceLabels = Dictionary(grouping: options) { normalizedProviderID($0.providerID) }
            .mapValues { rows in rows.map(\.source.displayLabel).uniquedPreservingOrder() }
        return assemble(entries: entries) { providerID in
            sourceLabels[providerID].flatMap(summarize)
        }
    }

    /// Groups an OpenAI-compatible gateway catalog (Hermes, OpenClaw, Pi, and
    /// the Elder Wand fusion gateway).
    static func groups(fromGateway models: [OpenAICompatibleAdvertisedModel]) -> [PlasmaProviderGroup] {
        let entries = models.map(entry(fromGateway:))
        return assemble(entries: entries) { providerID in
            let count = entries.filter { $0.providerID == providerID && !$0.isDisabled }.count
            let total = entries.filter { $0.providerID == providerID }.count
            if count == total { return "\(count) routable" }
            return "\(count) of \(total) routable"
        }
    }

    /// A stored selection the live catalog no longer advertises still has to
    /// appear, disabled and labelled — silently dropping it is how a picker
    /// starts lying about what the next request will send.
    static func includingOrphanedSelection(
        _ groups: [PlasmaProviderGroup],
        selection rawSelection: String,
        note: String
    ) -> [PlasmaProviderGroup] {
        let selection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        guard !selection.isEmpty else { return groups }
        let known = groups.contains { group in
            group.entries.contains { $0.id == selection }
        }
        guard !known else { return groups }

        let orphan = PlasmaModelEntry(
            id: selection,
            title: selection,
            detail: note,
            providerID: "unknown",
            isDisabled: true
        )
        if let index = groups.firstIndex(where: { $0.id == "unknown" }) {
            var patched = groups
            let existing = patched[index]
            patched[index] = PlasmaProviderGroup(
                id: existing.id,
                displayName: existing.displayName,
                sourceSummary: existing.sourceSummary,
                entries: existing.entries + [orphan]
            )
            return patched
        }
        return groups + [
            PlasmaProviderGroup(
                id: "unknown",
                displayName: "Not advertised",
                sourceSummary: note,
                entries: [orphan]
            )
        ]
    }

    // MARK: Cascade rules

    /// The rung to open on after an agent is chosen.
    ///
    /// A provider rung holding one pill is a click that teaches nothing, so a
    /// single-provider agent (every CLI runtime with one auth, which is most of
    /// them) drops the user straight onto its models.
    static func levelAfterChoosingAgent(groupCount: Int) -> PlasmaLadderLevel {
        groupCount > 1 ? .provider : .model
    }

    /// The rung `Back` returns to from the model rung — mirroring the skip, so
    /// forward and backward never disagree about whether rung 2 exists.
    static func levelBehindModels(groupCount: Int) -> PlasmaLadderLevel {
        groupCount > 1 ? .provider : .agent
    }

    /// "Let the agent decide" is a real choice, so its pill sits on every rung
    /// where a model is being chosen — not only on whichever rung the forward
    /// flow happens to land on. Walking the breadcrumb must never strand a user
    /// on a rung that cannot express "automatic".
    static func showsAutomaticRow(on level: PlasmaLadderLevel) -> Bool {
        level != .agent
    }

    /// Keeps the ladder pointed at a group that still exists after a catalog
    /// refresh drops one, so a live discovery can never strand the user on an
    /// empty rung.
    static func resolvedGroupID(
        preferred: String?,
        selection rawSelection: String,
        groups: [PlasmaProviderGroup]
    ) -> String? {
        if let preferred, groups.contains(where: { $0.id == preferred }) { return preferred }
        let selection = rawSelection.trimmingCharacters(in: .whitespacesAndNewlines)
        if !selection.isEmpty,
           let owner = groups.first(where: { group in group.entries.contains { $0.id == selection } }) {
            return owner.id
        }
        return groups.first?.id
    }

    // MARK: Entry factories

    private static func entry(fromCLI option: CLIRuntimeModelOption) -> PlasmaModelEntry {
        let modelID = option.modelID.trimmingCharacters(in: .whitespacesAndNewlines)
        let segments = option.displayName
            .components(separatedBy: " · ")
            .map { $0.trimmingCharacters(in: .whitespacesAndNewlines) }
            .filter { !$0.isEmpty }
        let title = segments.first ?? (modelID.isEmpty ? option.displayName : modelID)

        // `OpenBurnBarModelDisplayName.compose` packs model, provider, route and
        // reasoning into one ` · ` string. The provider is rung 2's job, so the
        // detail line keeps only what rung 3 adds: the id that will be sent, the
        // reasoning level, and where the tokens are billed.
        var detail: [String] = []
        if !modelID.isEmpty, modelID.caseInsensitiveCompare(title) != .orderedSame {
            detail.append(modelID)
        }
        detail.append(contentsOf: segments.dropFirst().filter { $0.hasPrefix("Reasoning:") })
        detail.append(option.source.displayLabel)

        return PlasmaModelEntry(
            id: modelID,
            title: title,
            detail: detail.joined(separator: " · "),
            providerID: normalizedProviderID(option.providerID),
            providerName: option.providerName
        )
    }

    private static func entry(fromGateway model: OpenAICompatibleAdvertisedModel) -> PlasmaModelEntry {
        let name = model.displayName.trimmingCharacters(in: .whitespacesAndNewlines)
        let title = name.isEmpty ? model.id : name
        var detail: [String] = []
        if model.id.caseInsensitiveCompare(title) != .orderedSame {
            detail.append(model.id)
        }
        if !model.routeEligible {
            detail.append("No eligible route — add or enable an account that serves it")
        }
        return PlasmaModelEntry(
            id: model.id,
            title: title,
            detail: detail.isEmpty ? nil : detail.joined(separator: " · "),
            providerID: normalizedProviderID(model.providerID ?? ""),
            providerName: model.providerName,
            isDisabled: !model.routeEligible
        )
    }

    // MARK: Helpers

    private static func assemble(
        entries: [PlasmaModelEntry],
        summary: (String) -> String?
    ) -> [PlasmaProviderGroup] {
        var order: [String] = []
        var buckets: [String: [PlasmaModelEntry]] = [:]
        var seenIDs: Set<String> = []
        for entry in entries {
            // Two catalog sources can advertise the same model; a rung that
            // lists it twice looks broken and doubles the group's count badge.
            guard seenIDs.insert("\(entry.providerID)|\(entry.id)").inserted else { continue }
            if buckets[entry.providerID] == nil {
                order.append(entry.providerID)
                buckets[entry.providerID] = []
            }
            buckets[entry.providerID]?.append(entry)
        }
        return order.map { providerID in
            let members = buckets[providerID] ?? []
            return PlasmaProviderGroup(
                id: providerID,
                displayName: providerDisplayName(
                    providerID,
                    providerName: members.compactMap(\.providerName).first
                ),
                sourceSummary: summary(providerID),
                entries: members
            )
        }
    }

    static func normalizedProviderID(_ raw: String) -> String {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        return trimmed.isEmpty ? "unknown" : trimmed
    }

    /// Rung 2's heading for a provider.
    ///
    /// The canonical label wins over the runtime-supplied one. A CLI is free to
    /// report its provider as `"openai"`, and echoing that verbatim would put a
    /// lowercase id where the app everywhere else says "OpenAI". The supplied
    /// name is the fallback, for providers the canonical table has never heard
    /// of — which is the only case where it knows more than we do.
    static func providerDisplayName(_ providerID: String, providerName: String? = nil) -> String {
        guard providerID != "unknown" else { return "Unlabelled provider" }
        // Compared exactly, not case-insensitively: "OpenAI" for `openai` is
        // precisely the improvement being looked for, and a case-insensitive
        // test would throw it away as a re-spelling of the id.
        if let canonical = OpenBurnBarModelDisplayName.providerLabel(providerID: providerID),
           canonical != providerID {
            return canonical
        }
        if let supplied = providerName?.trimmingCharacters(in: .whitespacesAndNewlines), !supplied.isEmpty {
            return supplied
        }
        return providerID
    }

    private static func summarize(_ labels: [String]) -> String? {
        guard !labels.isEmpty else { return nil }
        if labels.count <= sourceSummaryLimit {
            return labels.joined(separator: " · ")
        }
        let head = labels.prefix(sourceSummaryLimit).joined(separator: " · ")
        return "\(head) +\(labels.count - sourceSummaryLimit) more"
    }
}
