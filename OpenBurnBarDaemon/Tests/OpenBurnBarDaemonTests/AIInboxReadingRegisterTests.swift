import OpenBurnBarEngine
@testable import OpenBurnBarDaemon
import XCTest

/// Locks the reading-register dial and the per-item rewrite directive.
///
/// The expensive property here is **byte-stability**. The analyst system prompt
/// is the largest fixed part of every tick's input, and DeepSeek prices a cache
/// hit at roughly 1/50th of a miss. A register implemented by interpolating the
/// user's preference into a sentence would produce a fresh prompt on every call
/// and quietly multiply the feature's running cost. So every variant is a
/// SELECTED static constant, and these tests prove it.
final class AIInboxReadingRegisterTests: XCTestCase {

    // MARK: - Byte-stability

    /// The shipped default must be byte-identical to the prompt that existed
    /// before the dial did: same string, same cache entry, same behavior for
    /// anyone who never opens the setting.
    func test_defaultRegisterAddsNothingToThePrompt() {
        XCTAssertEqual(
            BurnBarAIInboxPromptBuilder.readingRegisterSection(detail: .standard, register: .professional),
            ""
        )
        XCTAssertEqual(
            BurnBarAIInboxPromptBuilder.analystSystemPrompt(founderLens: false),
            BurnBarAIInboxPromptBuilder.analystSystemPrompt
        )
        XCTAssertEqual(
            BurnBarAIInboxPromptBuilder.analystSystemPrompt(
                founderLens: false,
                detail: .standard,
                register: .professional
            ),
            BurnBarAIInboxPromptBuilder.analystSystemPrompt
        )
    }

    /// All nine combinations resolve to distinct prompts, and each is stable
    /// across calls.
    func test_everyDetailRegisterPairIsDistinctAndByteStable() {
        var seen: [String: String] = [:]
        for detail in BurnBarInboxBriefDetail.allCases {
            for register in BurnBarInboxBriefRegister.allCases {
                let key = "\(detail.rawValue)/\(register.rawValue)"
                let first = BurnBarAIInboxPromptBuilder.readingRegisterSection(
                    detail: detail,
                    register: register
                )
                let second = BurnBarAIInboxPromptBuilder.readingRegisterSection(
                    detail: detail,
                    register: register
                )
                XCTAssertEqual(first, second, "\(key) must be byte-stable across calls")
                if let owner = seen[first] {
                    XCTFail("\(key) collides with \(owner) — the dial would be a no-op")
                }
                seen[first] = key
            }
        }
        XCTAssertEqual(seen.count, 9)
    }

    /// The whole system prompt, not just the section, stays distinct per pair —
    /// including when the Founder Lens is on.
    func test_systemPromptIsDistinctAndStablePerPair() {
        var prompts = Set<String>()
        for detail in BurnBarInboxBriefDetail.allCases {
            for register in BurnBarInboxBriefRegister.allCases {
                let prompt = BurnBarAIInboxPromptBuilder.analystSystemPrompt(
                    founderLens: true,
                    detail: detail,
                    register: register
                )
                XCTAssertEqual(
                    prompt,
                    BurnBarAIInboxPromptBuilder.analystSystemPrompt(
                        founderLens: true,
                        detail: detail,
                        register: register
                    )
                )
                prompts.insert(prompt)
            }
        }
        XCTAssertEqual(prompts.count, 9)
    }

    /// Prefix caching only pays when the shared head is genuinely shared. The
    /// register goes last, so every variant still starts with the same bytes.
    func test_everyVariantSharesTheBasePromptPrefix() {
        for detail in BurnBarInboxBriefDetail.allCases {
            for register in BurnBarInboxBriefRegister.allCases {
                for lens in [true, false] {
                    let prompt = BurnBarAIInboxPromptBuilder.analystSystemPrompt(
                        founderLens: lens,
                        detail: detail,
                        register: register
                    )
                    XCTAssertTrue(
                        prompt.hasPrefix(BurnBarAIInboxPromptBuilder.analystSystemPrompt),
                        "\(detail.rawValue)/\(register.rawValue)/lens=\(lens) broke the cached prefix"
                    )
                }
            }
        }
    }

    // MARK: - Content

    /// The register the repo owner actually asked for. It has to *say* the
    /// things that produce plain writing, not merely be named after them.
    func test_plainEnglishFragmentDemandsPlainWriting() {
        let fragment = BurnBarAIInboxPromptBuilder.registerFragment(.plainEnglish)
        for anchor in ["Everyday words", "Short sentences", "gloss", "abbreviations"] {
            XCTAssertTrue(fragment.contains(anchor), "plain English register lost: \(anchor)")
        }
        // It must not commit the sins the Founder Lens bans.
        XCTAssertEqual(BurnBarFounderLens.violations(in: fragment), [])
    }

    func test_briefAndDeepFragmentsPullInOppositeDirections() {
        XCTAssertTrue(BurnBarAIInboxPromptBuilder.detailFragment(.brief).contains("cut it to the bone"))
        XCTAssertTrue(BurnBarAIInboxPromptBuilder.detailFragment(.deep).contains("explain the mechanism"))
        XCTAssertEqual(BurnBarAIInboxPromptBuilder.detailFragment(.standard), "")
        XCTAssertEqual(BurnBarAIInboxPromptBuilder.registerFragment(.professional), "")
    }

    /// The register is the user's own instruction about how they want to be
    /// written to, so it gets the last word over the base voice and the lens.
    func test_registerSectionComesAfterTheLens() {
        let prompt = BurnBarAIInboxPromptBuilder.analystSystemPrompt(
            founderLens: true,
            detail: .standard,
            register: .plainEnglish
        )
        let lensIndex = try? XCTUnwrap(prompt.range(of: "Founder Lens v"))
        let registerIndex = try? XCTUnwrap(prompt.range(of: "## Reading register"))
        guard let lensIndex, let registerIndex else { return }
        XCTAssertTrue(lensIndex.lowerBound < registerIndex.lowerBound)
    }

    // MARK: - action_hints schema

    /// The hint schema has to be in the STATIC prompt, not appended per tick —
    /// otherwise it defeats the caching the rest of this suite protects.
    func test_actionHintsSchemaIsInTheStaticPrompt() {
        let prompt = BurnBarAIInboxPromptBuilder.analystSystemPrompt
        for anchor in [
            "\"action_hints\"",
            "\"evidence_id\": \"must be from the valid ids list\"",
            "\"verb\": \"short imperative button label <= 28 chars\"",
            "\"why\": \"one short clause explaining what this accomplishes\"",
            "## About action_hints"
        ] {
            XCTAssertTrue(prompt.contains(anchor), "system prompt lost: \(anchor)")
        }
        // The prompt must state the boundary, not merely rely on Swift to hold
        // it: a model told it cannot supply a URL argues about labels instead
        // of trying to smuggle destinations.
        XCTAssertTrue(prompt.contains("You cannot supply a URL"))
        XCTAssertTrue(prompt.contains("every destination is built from the evidence"))
    }

    // MARK: - Config plumbing

    func test_configCarriesTheRegisterThroughNormalization() {
        let config = BurnBarInboxConfig(briefDetail: .deep, briefRegister: .expert)
        XCTAssertEqual(config.briefDetail, .deep)
        XCTAssertEqual(config.briefRegister, .expert)
    }

    // MARK: - Reply directives

    /// A directive turns a reply into a rewrite request without a new RPC, a
    /// new contract-canon entry, or a second copy of the budget/egress gates.
    func test_directiveAddsARewriteSectionToTheReplyPrompt() {
        let plain = BurnBarAIInboxReplyService.systemPrompt(pack: .engOps, directive: .plainEnglish)
        let base = BurnBarAIInboxReplyService.systemPrompt(pack: .engOps)
        XCTAssertTrue(plain.hasPrefix(base), "the rewrite section appends; it does not rewrite the prompt")
        XCTAssertTrue(plain.contains("This turn is a rewrite request"))
        XCTAssertTrue(plain.contains("Everyday words"))
        XCTAssertFalse(base.contains("This turn is a rewrite request"))
    }

    func test_everyDirectiveProducesADistinctStableReplyPrompt() {
        var prompts = Set<String>()
        for directive in BurnBarInboxReplyDirective.allCases {
            let prompt = BurnBarAIInboxReplyService.systemPrompt(pack: .engOps, directive: directive)
            XCTAssertEqual(
                prompt,
                BurnBarAIInboxReplyService.systemPrompt(pack: .engOps, directive: directive),
                "\(directive.rawValue) must be byte-stable"
            )
            prompts.insert(prompt)
        }
        // Five directives plus the undirected baseline.
        prompts.insert(BurnBarAIInboxReplyService.systemPrompt(pack: .engOps))
        XCTAssertEqual(prompts.count, BurnBarInboxReplyDirective.allCases.count + 1)
    }

    /// "plain English" must mean the same thing in a reply as it does in a
    /// brief — one definition, reused, rather than two that drift.
    func test_rewriteSectionReusesTheAnalystRegisterFragments() {
        XCTAssertTrue(
            BurnBarAIInboxReplyService.rewriteSection(.expert)
                .contains(BurnBarAIInboxPromptBuilder.registerFragment(.expert))
        )
        XCTAssertTrue(
            BurnBarAIInboxReplyService.rewriteSection(.shorter)
                .contains(BurnBarAIInboxPromptBuilder.detailFragment(.brief))
        )
        // `.professional` contributes no analyst fragment, so the rewrite text
        // has to carry the instruction itself rather than emit an empty block.
        XCTAssertTrue(
            BurnBarAIInboxReplyService.rewriteSection(.professional).contains("colleague who shares this context")
        )
    }

    /// The thread stores a sentence, never the wire token.
    func test_storedUserTurnReadsAsASentence() {
        let raw = BurnBarInboxReplyDirective.plainEnglish.encodedBody()
        let rendered = BurnBarAIInboxReplyService.renderedUserTurn(
            rawBody: raw,
            parsed: BurnBarInboxReplyDirective.parse(body: raw)
        )
        XCTAssertEqual(rendered, BurnBarInboxReplyDirective.plainEnglish.userTurnMarkdown)
        XCTAssertFalse(rendered.contains(BurnBarInboxReplyDirective.bodyPrefix))
    }

    func test_storedUserTurnKeepsTheFreeTextTheUserTyped() {
        let raw = BurnBarInboxReplyDirective.plainEnglish.encodedBody(followUp: "especially the CI part")
        let rendered = BurnBarAIInboxReplyService.renderedUserTurn(
            rawBody: raw,
            parsed: BurnBarInboxReplyDirective.parse(body: raw)
        )
        XCTAssertTrue(rendered.hasPrefix(BurnBarInboxReplyDirective.plainEnglish.userTurnMarkdown))
        XCTAssertTrue(rendered.hasSuffix("especially the CI part"))
    }

    /// An ordinary reply is untouched — including one that merely mentions the
    /// token, which is how injected text would try to reach the directive path.
    func test_ordinaryReplyPassesThroughUnchanged() {
        let body = "Why is @burnbar/rewrite:expert showing up in my inbox?"
        XCTAssertEqual(
            BurnBarAIInboxReplyService.renderedUserTurn(
                rawBody: body,
                parsed: BurnBarInboxReplyDirective.parse(body: body)
            ),
            body
        )
    }
}
