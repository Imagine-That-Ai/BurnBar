import XCTest
import GRDB
import OpenBurnBarCore
@testable import OpenBurnBar

private typealias AppAgentProvider = OpenBurnBar.AgentProvider
private typealias AppTokenUsage = OpenBurnBar.TokenUsage
private typealias AppUsageSource = OpenBurnBar.UsageSource
@MainActor
final class OpenBurnBarAuthoringReplayGoldenTests: XCTestCase {
    func test_replayGolden_draftAndRefineGrounding() async throws {
        let harness = try OpenBurnBarSearchIntegrationHarness(name: "replay-authoring-grounding")
        defer { harness.cleanup() }

        let now = harness.clock.now()
        let skillContextDocument = SearchDocumentRecord(
            id: "doc-authoring-skill-context",
            sourceKind: .skillDoc,
            sourceID: "artifact-skill-context",
            sourceVersionID: "skill-context-v1",
            provider: nil,
            projectName: "OpenBurnBar",
            title: "Skill Grounding Context",
            subtitle: "SKILL.md",
            bodyPreview: "Skill context for release hardening.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-authoring-skill-context",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(skillContextDocument)
        try harness.dataStore.replaceSearchChunks(
            documentID: skillContextDocument.id,
            title: skillContextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-authoring-skill-context",
                    documentID: skillContextDocument.id,
                    sourceKind: .skillDoc,
                    sourceID: skillContextDocument.sourceID,
                    sourceVersionID: skillContextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 140,
                    sectionPath: "Release",
                    text: "skill-grounding-needle release hardening checklist with rollback drills and smoke validations.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let agentContextDocument = SearchDocumentRecord(
            id: "doc-authoring-agent-context",
            sourceKind: .agentDoc,
            sourceID: "artifact-agent-context",
            sourceVersionID: "agent-context-v1",
            provider: nil,
            projectName: "OpenBurnBar",
            title: "Agent Grounding Context",
            subtitle: "AGENTS.md",
            bodyPreview: "Agent context for escalation policy.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-authoring-agent-context",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(agentContextDocument)
        try harness.dataStore.replaceSearchChunks(
            documentID: agentContextDocument.id,
            title: agentContextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-authoring-agent-context",
                    documentID: agentContextDocument.id,
                    sourceKind: .agentDoc,
                    sourceID: agentContextDocument.sourceID,
                    sourceVersionID: agentContextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 144,
                    sectionPath: "Escalation",
                    text: "agent-grounding-needle escalation policy with handoff rules, ownership boundaries, and response contracts.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let generator = ReplayStubArtifactAuthoringTextGenerator(
            responses: [
                """
                # Skill Draft
                Add release hardening checks.

                ## Grounding
                - [R1] Skill context applied.
                """,
                """
                # Skill Refine
                Improve escalation and rollback sections.

                ## Grounding
                - [R1] Agent context applied.
                """,
                """
                # Agent Draft
                Define ownership and escalation boundaries.

                ## Grounding
                - [R1] Agent context applied.
                """,
                """
                # Agent Refine
                Tighten release sequencing and guardrails.

                ## Grounding
                - [R1] Skill context applied.
                """
            ]
        )
        let settings = OpenBurnBarHarnessArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [harness.fileRoots.registeredProjectRootURL.path],
            artifactDiscoveryAdditionalKnownPatterns: []
        )
        let service = ArtifactAuthoringService(
            dataStore: harness.dataStore,
            retrievalService: harness.makeSearchService(semanticEnabled: false),
            settingsProvider: settings,
            textGenerator: generator,
            nowProvider: { harness.clock.now() }
        )

        let draftSkill = try await service.draftSkill(
            request: "Draft release hardening workflow steps.",
            projectName: "OpenBurnBar",
            retrievalQuery: "skill-grounding-needle",
            contextLimit: 4
        )
        let refineSkill = try await service.refineSkill(
            existingMarkdown: "# Existing Skill\nCurrent checklist.",
            instructions: "Refine with escalation and rollback details.",
            projectName: "OpenBurnBar",
            retrievalQuery: "agent-grounding-needle",
            contextLimit: 4
        )
        let draftAgent = try await service.draftAgentDoc(
            request: "Draft ownership and escalation policy for agents.",
            projectName: "OpenBurnBar",
            retrievalQuery: "agent-grounding-needle",
            contextLimit: 4
        )
        let refineAgent = try await service.refineAgentDoc(
            existingMarkdown: "# Existing Agent Doc\nCurrent operating policy.",
            instructions: "Refine sequencing and release guardrails.",
            projectName: "OpenBurnBar",
            retrievalQuery: "skill-grounding-needle",
            contextLimit: 4
        )

        let snapshot = AuthoringReplayGoldenSnapshot(
            scenario: "authoring-draft-refine-grounding",
            cases: [
                summarizeAuthoringCase(name: "draft-skill", draft: draftSkill),
                summarizeAuthoringCase(name: "refine-skill", draft: refineSkill),
                summarizeAuthoringCase(name: "draft-agent-doc", draft: draftAgent),
                summarizeAuthoringCase(name: "refine-agent-doc", draft: refineAgent)
            ]
        )
        try OpenBurnBarReplayGoldens.assertGolden(snapshot, fixtureFile: "authoring-draft-refine-grounding.json")
    }

    func test_optionalSmoke_realProviderAuthoringIntegration() async throws {
        let smokeEnabled = ProcessInfo.processInfo.environment["OPENBURNBAR_REAL_PROVIDER_SMOKE"] == "1"
            || ProcessInfo.processInfo.environment["BURNBAR_REAL_PROVIDER_SMOKE"] == "1"
        guard smokeEnabled else {
            throw XCTSkip("Set OPENBURNBAR_REAL_PROVIDER_SMOKE=1 to run optional real provider smoke coverage.")
        }

        let harness = try OpenBurnBarSearchIntegrationHarness(name: "real-provider-authoring-smoke")
        defer { harness.cleanup() }

        let now = harness.clock.now()
        let contextDocument = SearchDocumentRecord(
            id: "doc-smoke-context",
            sourceKind: .skillDoc,
            sourceID: "artifact-smoke-context",
            sourceVersionID: "smoke-v1",
            provider: nil,
            projectName: "OpenBurnBar",
            title: "Smoke Context",
            subtitle: "SKILL.md",
            bodyPreview: "Smoke context for real provider test.",
            sourceUpdatedAt: now,
            indexedAt: now,
            contentHash: "hash-smoke-context",
            createdAt: now,
            updatedAt: now
        )
        try harness.dataStore.upsertSearchDocument(contextDocument)
        try harness.dataStore.replaceSearchChunks(
            documentID: contextDocument.id,
            title: contextDocument.title,
            chunks: [
                SearchChunkRecord(
                    id: "chunk-smoke-context",
                    documentID: contextDocument.id,
                    sourceKind: .skillDoc,
                    sourceID: contextDocument.sourceID,
                    sourceVersionID: contextDocument.sourceVersionID,
                    ordinal: 0,
                    startOffset: 0,
                    endOffset: 96,
                    sectionPath: "Smoke",
                    text: "smoke-grounding-needle release hardening smoke validation context.",
                    createdAt: now,
                    updatedAt: now
                )
            ]
        )

        let settings = OpenBurnBarHarnessArtifactDiscoverySettings(
            artifactDiscoveryEnabled: true,
            artifactDiscoveryRegisteredRoots: [harness.fileRoots.registeredProjectRootURL.path],
            artifactDiscoveryAdditionalKnownPatterns: []
        )
        let service = ArtifactAuthoringService(
            dataStore: harness.dataStore,
            retrievalService: harness.makeSearchService(semanticEnabled: false),
            settingsProvider: settings,
            textGenerator: CLIArtifactAuthoringTextGenerator(),
            nowProvider: { harness.clock.now() }
        )

        do {
            let draft = try await service.draftSkill(
                request: "Draft two concise release hardening bullets.",
                projectName: "OpenBurnBar",
                retrievalQuery: "smoke-grounding-needle",
                contextLimit: 2
            )
            XCTAssertFalse(draft.content.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
            XCTAssertTrue(draft.references.isEmpty == false)
        } catch let error as ArtifactAuthoringError {
            if case .cliUnavailable = error {
                throw XCTSkip("No real CLI provider is available in this environment.")
            }
            throw error
        }
    }

    private func summarizeAuthoringCase(name: String, draft: ArtifactAuthoringDraft) -> AuthoringReplayCaseSnapshot {
        AuthoringReplayCaseSnapshot(
            name: name,
            sourceKind: draft.sourceKind.rawValue,
            operation: draft.operation.rawValue,
            retrievalQuery: draft.retrievalQuery,
            referenceSourceIDs: draft.references.map(\.sourceID),
            referenceKinds: draft.references.map(\.sourceKind.rawValue),
            hasGroundingInstruction: draft.userPrompt.contains("## Grounding"),
            hasReferenceLabel: draft.userPrompt.contains("[R1]"),
            includesExistingMarkdownBlock: draft.userPrompt.contains("Existing markdown to refine:"),
            generatedHasGroundingSection: draft.content.localizedCaseInsensitiveContains("## grounding"),
            generatedHasReferenceCitation: draft.content.contains("[R1]")
        )
    }
}
