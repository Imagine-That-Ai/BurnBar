import XCTest
import OpenBurnBarCore
@testable import OpenBurnBar

/// G9 tests for the global prompt token arbiter. The arbiter is a pure value type,
/// so these are synchronous and need no DataStore or live backend.
///
/// Coverage required by docs/MEMORY_FRONTEND_PLAN.md §6 (F-1):
///   * never exceeds ceiling
///   * user turn + tool defs always retained
///   * ollama floor (conservative floor for ollama / unknown local backends)
final class PromptTokenArbiterTests: XCTestCase {

    // MARK: - Per-model budget (ollama floor, cloud ceiling)

    func testOllamaGetsConservativeFloorWithinCeiling() {
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        // Conservative ceiling for ollama / unknown local backends.
        XCTAssertLessThanOrEqual(arbiter.augmentedSystemBudget, 3_072, "ollama budget must respect the conservative ceiling")
        XCTAssertGreaterThanOrEqual(arbiter.augmentedSystemBudget, 1_536, "ollama budget must stay above the floor")
    }

    func testUnknownLocalBackendMatchesOllamaFloor() {
        let ollama = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        let unknown = PromptTokenArbiter.make(model: nil, historyAndUserTurnTokens: 0)
        XCTAssertEqual(
            unknown.augmentedSystemBudget,
            ollama.augmentedSystemBudget,
            "unknown / local backend must get the same conservative floor as ollama"
        )
        XCTAssertEqual(unknown.memoryBudget, ollama.memoryBudget)
    }

    func testCloudModelGetsLargerBudgetThanOllama() {
        let ollama = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        let cloud = PromptTokenArbiter.make(model: .claude, historyAndUserTurnTokens: 0)
        XCTAssertGreaterThan(cloud.augmentedSystemBudget, ollama.augmentedSystemBudget, "cloud budget must be larger than the ollama floor")
        XCTAssertLessThanOrEqual(cloud.augmentedSystemBudget, 24_576, "cloud budget must respect its ceiling")
    }

    // MARK: - User turn + history reservation (never starved)

    func testHistorySubtractionShrinksSystemBudget() {
        // ollama window 8192, output reserve 2048. With 0 history: available 6144,
        // ceiling 3072 -> 3072. With 4000 history: available 2144 -> 2144 (above floor).
        let noHistory = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        let withHistory = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 4_000)
        XCTAssertEqual(noHistory.augmentedSystemBudget, 3_072)
        XCTAssertEqual(withHistory.augmentedSystemBudget, 2_144)
        XCTAssertLessThan(withHistory.augmentedSystemBudget, noHistory.augmentedSystemBudget,
                          "reserved history + user turn must subtract from the system budget")
    }

    func testFloorDoesNotExceedRemainingContext() {
        // ollama window 8192, output reserve 2048, history 5000 leaves only 1144.
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 5_000)
        XCTAssertEqual(
            arbiter.augmentedSystemBudget,
            1_144,
            "floor must not allocate more system prompt than remains in the context window"
        )
    }

    func testSystemWrapperReserveShrinksSystemBudget() {
        let noWrapper = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 4_000)
        let withWrapper = PromptTokenArbiter.make(
            model: .ollama,
            historyAndUserTurnTokens: 4_000,
            systemWrapperTokens: 400
        )
        XCTAssertEqual(withWrapper.augmentedSystemBudget, noWrapper.augmentedSystemBudget - 400)
    }

    // MARK: - Never exceeds ceiling

    func testAssembledPromptNeverExceedsCeilingWhenCoreAndToolDefsFit() {
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        let huge = Self.repeatingText(length: 60_000)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona line. OpenBurnBar analyst."),
            PromptTokenSection(id: .toolDefs, content: "Workspace path /tmp/x. Tools enabled."),
            PromptTokenSection(id: .focus, content: huge),
            PromptTokenSection(id: .evidence, content: huge),
            PromptTokenSection(id: .memory, content: huge)
        ])
        XCTAssertLessThanOrEqual(
            result.estimatedTokens,
            arbiter.augmentedSystemBudget,
            "assembled prompt must never exceed the augmented-system budget when core + tool defs fit"
        )
    }

    func testAssembledPromptNeverExceedsCeilingForCloudModel() {
        let arbiter = PromptTokenArbiter.make(model: .kimi, historyAndUserTurnTokens: 0)
        let huge = Self.repeatingText(length: 200_000)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .focus, content: huge),
            PromptTokenSection(id: .evidence, content: huge),
            PromptTokenSection(id: .memory, content: huge)
        ])
        XCTAssertLessThanOrEqual(result.estimatedTokens, arbiter.augmentedSystemBudget)
    }

    // MARK: - Tool defs + persona always retained

    func testToolDefsAlwaysRetainedEvenWhenEvidenceHuge() {
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        let toolDefs = "Workspace path /tmp/project. Desktop control: cursor, keyboard. Tools available."
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: toolDefs),
            PromptTokenSection(id: .focus, content: Self.repeatingText(length: 60_000)),
            PromptTokenSection(id: .evidence, content: Self.repeatingText(length: 60_000)),
            PromptTokenSection(id: .memory, content: Self.repeatingText(length: 60_000))
        ])
        XCTAssertTrue(result.systemPrompt.contains("Workspace path"), "tool defs must always be retained (G9)")
        XCTAssertTrue(result.systemPrompt.contains("Persona."), "persona (core) must always be retained")
    }

    func testToolDefsRetainedWhenHistoryConsumesBudget() {
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 4_000)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "TOOLS_PRESENT_MARKER"),
            PromptTokenSection(id: .evidence, content: Self.repeatingText(length: 30_000))
        ])
        XCTAssertTrue(result.systemPrompt.contains("TOOLS_PRESENT_MARKER"), "tool defs retained even with heavy history")
    }

    // MARK: - Priority-ordered dropping (focus > evidence > memory)

    func testFocusKeptOverEvidenceWhenBothHugeAndBudgetSmall() {
        // Tiny budget so focus consumes the pool and evidence is dropped.
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 4_000)
        let focusMarker = "FOCUS_MARKER_CONTENT"
        let evidenceMarker = "EVIDENCE_MARKER_CONTENT"
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .focus, content: focusMarker + Self.repeatingText(length: 60_000)),
            PromptTokenSection(id: .evidence, content: evidenceMarker + Self.repeatingText(length: 60_000))
        ])
        XCTAssertTrue(result.systemPrompt.contains(focusMarker), "focus must be kept (priority over evidence)")
        XCTAssertTrue(result.droppedSections.contains(.evidence), "evidence must be dropped before focus")
        XCTAssertFalse(result.systemPrompt.contains(evidenceMarker), "dropped evidence must not appear in the prompt")
    }

    // MARK: - Memory shared pool (subtracts, never appends uncapped)

    func testMemoryBudgetIsCarvedFromSharedPool() {
        let arbiter = PromptTokenArbiter.make(model: .claude, historyAndUserTurnTokens: 0)
        XCTAssertGreaterThan(arbiter.memoryBudget, 0, "memory budget must be reserved")
        XCTAssertLessThan(arbiter.memoryBudget, arbiter.augmentedSystemBudget, "memory must share, not consume, the budget")
    }

    func testMemoryCappedAtMemoryBudget() {
        let arbiter = PromptTokenArbiter.make(model: .claude, historyAndUserTurnTokens: 0)
        // Evidence tiny so memory gets its full cap.
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .evidence, content: "small evidence"),
            PromptTokenSection(id: .memory, content: Self.repeatingText(length: 200_000))
        ])
        XCTAssertLessThanOrEqual(result.estimatedTokens, arbiter.augmentedSystemBudget)
        XCTAssertTrue(result.truncatedSections.contains(.memory), "memory exceeding its cap must be truncated")
    }

    func testMemoryDroppedWhenEvidenceConsumesSharedPool() {
        // Evidence has keep-priority; when it fills the pool, memory is dropped.
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 4_000)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .evidence, content: "EVIDENCE_MARKER " + Self.repeatingText(length: 60_000)),
            PromptTokenSection(id: .memory, content: "MEMORY_MARKER " + Self.repeatingText(length: 60_000))
        ])
        XCTAssertTrue(result.systemPrompt.contains("EVIDENCE_MARKER"), "evidence kept with priority over memory")
        XCTAssertTrue(result.droppedSections.contains(.memory), "memory dropped when evidence consumes the pool")
        XCTAssertFalse(result.systemPrompt.contains("MEMORY_MARKER"), "dropped memory must not appear")
    }

    func testMemoryAndEvidenceBothFitWhenSmall() {
        let arbiter = PromptTokenArbiter.make(model: .claude, historyAndUserTurnTokens: 0)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .evidence, content: "evidence body"),
            PromptTokenSection(id: .memory, content: "memory body")
        ])
        XCTAssertTrue(result.systemPrompt.contains("evidence body"))
        XCTAssertTrue(result.systemPrompt.contains("memory body"))
        XCTAssertTrue(result.droppedSections.isEmpty, "nothing should be dropped when everything fits")
        XCTAssertTrue(result.truncatedSections.isEmpty, "nothing should be truncated when everything fits")
    }

    func testRollupsDropAfterEvidenceAndMemory() {
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 4_000)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .evidence, content: "EVIDENCE_MARKER " + Self.repeatingText(length: 6_000)),
            PromptTokenSection(id: .memory, content: "MEMORY_MARKER " + Self.repeatingText(length: 2_000)),
            PromptTokenSection(id: .rollups, content: "ROLLUP_MARKER " + Self.repeatingText(length: 60_000))
        ])
        XCTAssertTrue(result.systemPrompt.contains("EVIDENCE_MARKER"))
        XCTAssertTrue(result.systemPrompt.contains("MEMORY_MARKER"))
        XCTAssertTrue(result.droppedSections.contains(.rollups), "volatile rollups must drop before evidence or memory")
        XCTAssertFalse(result.systemPrompt.contains("ROLLUP_MARKER"))
    }

    // MARK: - Truncation marker

    func testTruncatedSectionGetsMarkerAndStaysWithinBudget() {
        let arbiter = PromptTokenArbiter.make(model: .ollama, historyAndUserTurnTokens: 0)
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "Tools."),
            PromptTokenSection(id: .evidence, content: Self.repeatingText(length: 60_000))
        ])
        XCTAssertTrue(result.truncatedSections.contains(.evidence), "oversized evidence must be truncated, not dropped")
        XCTAssertTrue(result.systemPrompt.contains("section truncated to respect prompt token budget"),
                      "truncated section must carry the truncation marker")
        XCTAssertLessThanOrEqual(result.estimatedTokens, arbiter.augmentedSystemBudget)
    }

    // MARK: - Model family resolution (call-site helper)

    func testArbiterModelFamilyHermesUsesSelectedFamily() {
        XCTAssertEqual(
            ChatSessionController.memoryArbiterModelFamily(backend: .hermes, resolvedModel: "ollama", hermesFamily: .ollama),
            .ollama
        )
        XCTAssertEqual(
            ChatSessionController.memoryArbiterModelFamily(backend: .hermes, resolvedModel: "claude", hermesFamily: .claude),
            .claude
        )
    }

    func testArbiterModelFamilyDetectsOllamaFromString() {
        XCTAssertEqual(
            ChatSessionController.memoryArbiterModelFamily(backend: .openclaw, resolvedModel: "ollama-llama3", hermesFamily: nil),
            .ollama
        )
    }

    func testArbiterModelFamilyCloudDefaultForNonHermes() {
        let family = ChatSessionController.memoryArbiterModelFamily(backend: .codex, resolvedModel: "gpt-5", hermesFamily: nil)
        XCTAssertNotEqual(family, .ollama, "non-ollama cloud backend must not get the ollama floor")
    }

    func testArbiterModelFamilyDetectsCommonLocalModelNames() {
        for model in ["llama3.1", "mistral-small", "qwen2.5", "deepseek-r1", "gemma3"] {
            XCTAssertEqual(
                ChatSessionController.memoryArbiterModelFamily(backend: .hermes, resolvedModel: model, hermesFamily: nil),
                .ollama,
                "\(model) should use the local-model budget"
            )
        }
    }

    func testArbiterModelFamilyResolvedModelWinsOverStaleHermesFamily() {
        XCTAssertEqual(
            ChatSessionController.memoryArbiterModelFamily(
                backend: .hermes,
                resolvedModel: "qwen2.5:latest",
                hermesFamily: .codex
            ),
            .ollama,
            "the resolved concrete model must override stale family state"
        )
    }

    func testArbiterModelFamilyHermesWithoutFamilyDefaultsToCloud() {
        let family = ChatSessionController.memoryArbiterModelFamily(backend: .hermes, resolvedModel: "hermes", hermesFamily: nil)
        XCTAssertNotEqual(family, .ollama, "Hermes without explicit family defaults to cloud (gateway router), not the ollama floor")
    }

    func testPayloadReserveUsesOnlySentCliUserTurn() {
        let oldHistory = [
            ChatMessageRecord(role: .user, content: Self.repeatingText(length: 30_000))
        ]
        let reserve = ChatSessionController.promptPayloadTokenReserve(history: [], userMessage: "current turn")
        let oldHistoryReserve = ChatSessionController.promptPayloadTokenReserve(history: oldHistory, userMessage: "current turn")
        XCTAssertLessThan(reserve, oldHistoryReserve)
        XCTAssertEqual(reserve, PromptTokenArbiter.estimateProseTokens("current turn"))
    }

    func testPayloadReserveIncludesSentAttachmentCosts() {
        let attachment = HermesAttachment(
            kind: .pdf,
            displayName: "brief.pdf",
            mimeType: "application/pdf",
            byteSize: 1024,
            workspaceRelativePath: "attachments/brief.pdf"
        )
        let history = [
            ChatMessageRecord(role: .user, content: "summarize this", attachments: [attachment])
        ]
        let reserve = ChatSessionController.promptPayloadTokenReserve(history: history, userMessage: "ignored")
        XCTAssertGreaterThanOrEqual(reserve, attachment.estimatedTokenCost)
    }

    // MARK: - G8 seal survives truncation (M1)

    func testTruncatedMemorySectionKeepsUntrustedSealBalanced() {
        let arbiter = PromptTokenArbiter.make(model: .claude, historyAndUserTurnTokens: 0)
        // A single wrapped memory block far larger than the memory cap: the arbiter must
        // truncate it mid-body, which (absent the reseal) would sever the close tag and
        // leave the trusted tool-defs concatenated inside an unterminated untrusted block.
        let wrapped = LLMSafeContent.wrapUntrusted(Self.repeatingText(length: 200_000), provenance: "memory:test@msg")
        let result = arbiter.assemble([
            PromptTokenSection(id: .core, content: "Persona."),
            PromptTokenSection(id: .toolDefs, content: "TOOLS_PRESENT_MARKER"),
            PromptTokenSection(id: .memory, content: wrapped)
        ])
        XCTAssertTrue(result.truncatedSections.contains(.memory), "precondition: the oversized memory block must truncate")
        let opens = result.systemPrompt.components(separatedBy: LLMSafeContent.untrustedOpenMarker).count - 1
        let closes = result.systemPrompt.components(separatedBy: LLMSafeContent.untrustedCloseMarker).count - 1
        XCTAssertGreaterThan(opens, 0, "the wrapped memory block must be present in the prompt")
        XCTAssertEqual(opens, closes, "every <UNTRUSTED_CONTENT> open must keep a matching close after truncation (G8)")
        XCTAssertTrue(result.systemPrompt.contains("CRITICAL RULE (never overridden)"),
                      "the re-sealed block must re-append the canonical CRITICAL RULE")
        XCTAssertTrue(result.systemPrompt.contains("TOOLS_PRESENT_MARKER"), "trusted tool defs must remain present")
        XCTAssertLessThanOrEqual(result.estimatedTokens, arbiter.augmentedSystemBudget,
                                 "reseal footer must be reserved before the cut so the prompt still honors the budget")
    }

    func testResealAppendsMissingCloseAndRuleWhenSevered() {
        let severed = LLMSafeContent.untrustedOpenMarker + "\"memory:x@y\">\nbody text with no closing tag"
        let resealed = LLMSafeContent.resealTruncatedUntrusted(severed)
        let opens = resealed.components(separatedBy: LLMSafeContent.untrustedOpenMarker).count - 1
        let closes = resealed.components(separatedBy: LLMSafeContent.untrustedCloseMarker).count - 1
        XCTAssertEqual(opens, closes, "reseal must balance the sentinels")
        XCTAssertTrue(resealed.contains("CRITICAL RULE (never overridden)"))
    }

    func testResealIsNoOpOnBalancedAndSentinelFreeText() {
        let whole = LLMSafeContent.wrapUntrusted("hello", provenance: "memory:x@y")
        XCTAssertEqual(LLMSafeContent.resealTruncatedUntrusted(whole), whole, "a complete wrapped block must be unchanged")
        let plain = "just trusted text, no wrappers"
        XCTAssertEqual(LLMSafeContent.resealTruncatedUntrusted(plain), plain, "sentinel-free text must be unchanged")
    }

    func testResealRestoresRuleWhenCloseSurvivesButRuleSevered() {
        // Cut a complete wrapped block a few chars PAST its close tag (inside the rule):
        // the block stays sealed (opens==closes) but its CRITICAL RULE is severed.
        let block = LLMSafeContent.wrapUntrusted("hello world", provenance: "memory:x@y")
        guard let close = block.range(of: LLMSafeContent.untrustedCloseMarker) else {
            XCTFail("wrapped block must contain a close marker")
            return
        }
        let cut = block.index(close.upperBound, offsetBy: 4) // a few chars into "\nCRIT..."
        let severed = String(block[..<cut])
        XCTAssertFalse(severed.hasSuffix(LLMSafeContent.criticalRule), "precondition: the rule is severed")
        let resealed = LLMSafeContent.resealTruncatedUntrusted(severed)
        XCTAssertTrue(resealed.hasSuffix(LLMSafeContent.criticalRule), "the severed rule must be re-appended")
        let opens = resealed.components(separatedBy: LLMSafeContent.untrustedOpenMarker).count - 1
        let closes = resealed.components(separatedBy: LLMSafeContent.untrustedCloseMarker).count - 1
        XCTAssertEqual(opens, closes, "the block must remain balanced (no extra close added)")
    }

    // MARK: - Helpers

    private static func repeatingText(length: Int) -> String {
        let pattern = "The quick brown fox jumps over the lazy dog. "
        var out = ""
        while out.count < length {
            out += pattern
        }
        return String(out.prefix(length))
    }
}
