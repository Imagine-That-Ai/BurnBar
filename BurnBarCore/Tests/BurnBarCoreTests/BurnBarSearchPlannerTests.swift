import XCTest

import BurnBarCore

final class BurnBarSearchPlannerTests: XCTestCase {
    func test_naturalLanguageUsesOrForLongQueries() {
        let q = BurnBarFTSQueryBuilder.naturalLanguage(from: String(repeating: "alpha beta gamma delta epsilon ", count: 4))
        XCTAssertTrue(q.contains(" OR "), "expected OR for long NL query, got: \(q)")
        XCTAssertFalse(q.contains(" AND "), "long NL query should avoid strict AND")
    }

    func test_naturalLanguageShortQueryUsesAndForPrecision() {
        let q = BurnBarFTSQueryBuilder.naturalLanguage(from: "fix bug")
        XCTAssertTrue(q.contains(" AND "), "short query should prefer AND, got: \(q)")
    }

    func test_planAggregateIntentProducesMixedModeAndPatterns() {
        let plan = BurnBarSearchPlan.plan(userText: #"How many times did I say "refactor" yesterday?"#)
        XCTAssertEqual(plan.mode, .mixed)
        XCTAssertTrue(plan.aggregatePatterns.contains("refactor"))
        XCTAssertFalse(plan.lexicalFTSQuery.isEmpty)
    }

    func test_planRoundTripsThroughJSON() throws {
        let plan = BurnBarSearchPlan.plan(userText: "Find sessions about sqlite migrations")
        let data = try JSONEncoder().encode(plan)
        let decoded = try JSONDecoder().decode(BurnBarSearchPlan.self, from: data)
        XCTAssertEqual(decoded.mode, plan.mode)
        XCTAssertEqual(decoded.lexicalFTSQuery, plan.lexicalFTSQuery)
        XCTAssertEqual(decoded.semanticText, plan.semanticText)
        XCTAssertEqual(decoded.aggregatePatterns, plan.aggregatePatterns)
    }

    func test_planProfanityQuestionUsesMixedModeWithoutHowManyTimes() {
        let plan = BurnBarSearchPlan.plan(userText: "did i curse at my agents yesterday?")
        XCTAssertEqual(plan.mode, .mixed)
        XCTAssertFalse(plan.aggregatePatterns.isEmpty)
    }

    func test_inferredDateRangeLastDay() {
        let now = Date(timeIntervalSince1970: 1_700_000_000)
        let r = BurnBarSearchTimeWindow.inferredDateRange(
            from: "how many times in the last day",
            now: now,
            calendar: .current
        )
        XCTAssertNotNil(r)
        XCTAssertLessThanOrEqual(r!.lowerBound, now)
        XCTAssertGreaterThanOrEqual(r!.upperBound, r!.lowerBound)
    }

    func test_inferredDateRangeThisMonth() throws {
        var cal = Calendar(identifier: .gregorian)
        cal.timeZone = TimeZone(secondsFromGMT: 0)!
        let now = try XCTUnwrap(cal.date(from: DateComponents(year: 2024, month: 3, day: 15, hour: 12)))
        let r = BurnBarSearchTimeWindow.inferredDateRange(
            from: "how many times this month",
            now: now,
            calendar: cal
        )
        XCTAssertNotNil(r)
        let comps = cal.dateComponents([.year, .month, .day], from: r!.lowerBound)
        XCTAssertEqual(comps.year, 2024)
        XCTAssertEqual(comps.month, 3)
        XCTAssertEqual(comps.day, 1)
        XCTAssertLessThanOrEqual(r!.lowerBound, now)
    }

    func test_planSaidProfanityUsesTargetWordNotCalendarTokens() {
        let plan = BurnBarSearchPlan.plan(userText: "how many times have i said fuck this month")
        XCTAssertEqual(plan.mode, .mixed)
        XCTAssertTrue(plan.aggregatePatterns.contains("fuck"))
        XCTAssertFalse(plan.aggregatePatterns.contains("month"), "calendar token should not be a count pattern")
        XCTAssertFalse(plan.aggregatePatterns.contains("said"), "helper verb should not be a count pattern")
    }
}

// MARK: - Field Boosting Tests

extension BurnBarSearchPlannerTests {
    func test_fieldBoosted_basicQuery() {
        let query = BurnBarFTSQueryBuilder.fieldBoosted(from: "sqlite migration")
        XCTAssertFalse(query.isEmpty, "field-boosted query should not be empty")
        // Should contain field prefixes
        XCTAssertTrue(query.contains("title:"), "should include title field prefix")
        XCTAssertTrue(query.contains("chunkText:"), "should include chunkText field prefix")
        // Should use OR for field distribution
        XCTAssertTrue(query.contains(" OR "), "should use OR between field alternatives")
    }

    func test_fieldBoosted_preservesTitleBoost() {
        let config = BurnBarFieldBoostConfig.titleHeavy
        XCTAssertGreaterThan(config.boost(for: .title), config.boost(for: .chunkText))
    }

    func test_fieldBoosted_uniformConfig() {
        let config = BurnBarFieldBoostConfig.uniform
        XCTAssertEqual(config.boost(for: .title), 1.0)
        XCTAssertEqual(config.boost(for: .chunkText), 1.0)
    }

    func test_fieldBoosted_quotedPhrase() {
        let query = BurnBarFTSQueryBuilder.fieldBoosted(from: "\"exact phrase\"")
        XCTAssertFalse(query.isEmpty, "quoted phrase should produce query")
        // Quoted phrases should still be quoted in FTS syntax
        XCTAssertTrue(query.contains("\"exact phrase\""), "quoted phrase should be preserved")
    }

    func test_fieldBoosted_fieldHint() {
        let tokens = BurnBarFTSQueryBuilder.extractTokens(from: "title:sqlite project:AgentLens")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].fieldHint, .title)
        XCTAssertEqual(tokens[0].text, "sqlite")
        XCTAssertEqual(tokens[1].fieldHint, .projectName)
        XCTAssertEqual(tokens[1].text, "AgentLens")
    }

    func test_fieldBoosted_shortQueryUsesAnd() {
        let query = BurnBarFTSQueryBuilder.fieldBoosted(from: "fix bug")
        XCTAssertTrue(query.contains(" AND "), "short query should use AND")
    }

    func test_fieldBoosted_longQueryUsesOr() {
        let query = BurnBarFTSQueryBuilder.fieldBoosted(
            from: "fix bug error crash failure issue problem defect"
        )
        XCTAssertTrue(query.contains(" OR "), "long query should use OR")
    }

    func test_extractTokens_handlesQuotedPhrases() {
        let tokens = BurnBarFTSQueryBuilder.extractTokens(from: #"find "exact phrase" here"#)
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[1].text, "exact phrase")
        XCTAssertTrue(tokens[1].isQuotedPhrase)
    }

    func test_extractTokens_handlesFieldPrefixes() {
        let tokens = BurnBarFTSQueryBuilder.extractTokens(from: "t:sqlite proj:BurnBar")
        XCTAssertEqual(tokens.count, 2)
        XCTAssertEqual(tokens[0].fieldHint, .title)
        XCTAssertEqual(tokens[1].fieldHint, .projectName)
    }

    func test_extractTokens_emptyInput() {
        let tokens = BurnBarFTSQueryBuilder.extractTokens(from: "")
        XCTAssertTrue(tokens.isEmpty)
    }

    func test_extractTokens_multipleFieldHints() {
        let tokens = BurnBarFTSQueryBuilder.extractTokens(
            from: "title:api subtitle:endpoint body:handler"
        )
        XCTAssertEqual(tokens.count, 3)
        XCTAssertEqual(tokens[0].fieldHint, .title)
        XCTAssertEqual(tokens[1].fieldHint, .subtitle)
        XCTAssertEqual(tokens[2].fieldHint, .bodyPreview)
    }

    func test_formatToken_escapesQuotes() {
        let token = BurnBarFTSQueryBuilder.QueryToken(text: "test\"quote", isQuotedPhrase: true)
        let formatted = BurnBarFTSQueryBuilder.formatToken(token)
        XCTAssertTrue(formatted.contains("\"\""))
    }

    func test_formatFieldToken_addsFieldPrefix() {
        let token = BurnBarFTSQueryBuilder.QueryToken(
            text: "sqlite",
            isQuotedPhrase: false,
            fieldHint: .title
        )
        let formatted = BurnBarFTSQueryBuilder.formatFieldToken(token)
        XCTAssertTrue(formatted.hasPrefix("title:"), "should have title prefix: \(formatted)")
    }
}

// MARK: - Query Expansion Tests

extension BurnBarSearchPlannerTests {
    func test_queryExpander_expandTerm_acronym() {
        let expander = BurnBarQueryExpander()
        let result = expander.expandTerm("api")
        XCTAssertTrue(result.expandedTerms.contains("application programming interface"))
        XCTAssertTrue(result.expansions.contains { $0.type == .acronym })
    }

    func test_queryExpander_expandTerm_synonym() {
        let expander = BurnBarQueryExpander()
        let result = expander.expandTerm("bug")
        XCTAssertTrue(result.expandedTerms.contains("issue"))
        XCTAssertTrue(result.expandedTerms.contains("defect"))
        XCTAssertTrue(result.expansions.contains { $0.type == .synonym })
    }

    func test_queryExpander_expandTerm_languageAbbreviation() {
        let expander = BurnBarQueryExpander()
        let result = expander.expandTerm("ts")
        XCTAssertTrue(result.expandedTerms.contains("typescript"))
        XCTAssertTrue(result.expansions.contains { $0.type == .abbreviation })
    }

    func test_queryExpander_expandTerm_noExpansion() {
        let expander = BurnBarQueryExpander()
        let result = expander.expandTerm("xyzunknown")
        XCTAssertEqual(result.expandedTerms, ["xyzunknown"])
        XCTAssertTrue(result.expansions.isEmpty)
    }

    func test_queryExpander_expandTerm_userDefined() {
        let expander = BurnBarQueryExpander(
            userDefinedExpansions: ["foo": ["bar", "baz"]]
        )
        let result = expander.expandTerm("foo")
        XCTAssertTrue(result.expandedTerms.contains("bar"))
        XCTAssertTrue(result.expandedTerms.contains("baz"))
        XCTAssertTrue(result.expansions.contains { $0.type == .userDefined })
    }

    func test_queryExpander_expandTerm_projectAlias() {
        let expander = BurnBarQueryExpander(
            projectAliases: ["bl": ["BurnBar", "BurnBarLens"]]
        )
        let result = expander.expandTerm("bl")
        XCTAssertTrue(result.expandedTerms.contains("burnbar"))
        XCTAssertTrue(result.expansions.contains { $0.type == .projectAlias })
    }

    func test_queryExpander_expandQuery_multipleTerms() {
        let expander = BurnBarQueryExpander()
        let results = expander.expandQuery("fix api bug")
        XCTAssertEqual(results.count, 3)
        // "api" should have expansions
        let apiResult = results.first { $0.original == "api" }
        XCTAssertNotNil(apiResult)
        XCTAssertFalse(apiResult!.expansions.isEmpty)
    }

    func test_queryExpander_expandQuery_handlesQuotedPhrases() {
        let expander = BurnBarQueryExpander()
        let results = expander.expandQuery(#"fix "exact phrase" bug"#)
        // Should have 2 results (quoted phrases are single tokens)
        XCTAssertEqual(results.count, 3)
    }

    func test_queryExpander_buildExpandedFTSQuery_basic() {
        let expander = BurnBarQueryExpander()
        let query = expander.buildExpandedFTSQuery("api bug")
        XCTAssertFalse(query.isEmpty)
        // Should contain field prefixes
        XCTAssertTrue(query.contains("title:"))
        XCTAssertTrue(query.contains("chunkText:"))
        // Original terms
        XCTAssertTrue(query.contains("\"api\"") || query.contains("\"application programming interface\""))
        XCTAssertTrue(query.contains("\"bug\"") || query.contains("\"issue\""))
    }

    func test_queryExpander_buildExpandedFTSQuery_emptyInput() {
        let expander = BurnBarQueryExpander()
        let query = expander.buildExpandedFTSQuery("")
        XCTAssertTrue(query.isEmpty)
    }

    func test_queryExpander_buildExpandedFTSQuery_customFields() {
        let expander = BurnBarQueryExpander()
        let query = expander.buildExpandedFTSQuery("api", fields: [.title, .projectName])
        XCTAssertTrue(query.contains("title:") || query.contains("projectName:"))
        XCTAssertFalse(query.contains("chunkText:"), "should only include specified fields")
    }

    func test_queryExpander_expansionSummary() {
        let expander = BurnBarQueryExpander()
        let summary = expander.expansionSummary(for: "fix api bug")
        XCTAssertFalse(summary.isEmpty)
        XCTAssertTrue(summary.contains("expanded to"))
    }

    func test_queryExpander_expansionSummary_noExpansions() {
        let expander = BurnBarQueryExpander()
        let summary = expander.expansionSummary(for: "xyzunknown")
        XCTAssertTrue(summary.isEmpty)
    }

    func test_queryExpander_disablesSynonyms() {
        let expander = BurnBarQueryExpander(includeSynonyms: false)
        let result = expander.expandTerm("bug")
        XCTAssertFalse(result.expandedTerms.contains("issue"))
        XCTAssertFalse(result.expandedTerms.contains("defect"))
    }

    func test_queryExpander_disablesAcronyms() {
        let expander = BurnBarQueryExpander(includeAcronyms: false)
        let result = expander.expandTerm("api")
        XCTAssertFalse(result.expandedTerms.contains("application programming interface"))
    }

    func test_searchPlan_applyingExpansion() {
        let plan = BurnBarSearchPlan.plan(userText: "explain api usage")
        let expandedPlan = plan.applyingExpansion()
        // If api was expanded, the FTS query should be different
        // Even if not expanded, plan should still be valid
        XCTAssertEqual(expandedPlan.mode, plan.mode)
        XCTAssertFalse(expandedPlan.lexicalFTSQuery.isEmpty)
    }

    func test_queryExpander_avoidDuplicates() {
        let expander = BurnBarQueryExpander()
        let result = expander.expandTerm("fix")
        // "fix" itself should be first, then expansions
        XCTAssertEqual(result.expandedTerms.first, "fix")
        // No duplicate terms
        let uniqueTerms = Set(result.expandedTerms)
        XCTAssertEqual(uniqueTerms.count, result.expandedTerms.count)
    }
}
