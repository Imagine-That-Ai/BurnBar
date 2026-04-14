import XCTest
@testable import OpenBurnBar

// MARK: - Test Fixtures

private enum ExportFixtures {
    static let referenceDate = Date(timeIntervalSince1970: 1_740_000_000)  // 2025-02-19 UTC
    static let calendar = Calendar(identifier: .gregorian)

    static func daysAgo(_ days: Int) -> Date {
        calendar.date(byAdding: .day, value: -days, to: referenceDate)!
    }

    static func makePack(
        sessions: [ContextPackSession] = [],
        keyFiles: [String] = ["file1.swift", "file2.swift"],
        keyCommands: [String] = ["npm test", "npm build"],
        project: String? = "TestProject",
        usageSummary: String = "3 sessions; providers: claude-code; 2025-02-15 – 2025-02-19; ~5000 chars",
        charEstimate: Int = 5000,
        dateWindow: ContextPackDateWindow = ContextPackDateWindow(
            start: Date(timeIntervalSince1970: 1_739_400_000),
            end: Date(timeIntervalSince1970: 1_740_000_000)
        )
    ) -> ContextPack {
        ContextPack(
            project: project,
            sessions: sessions,
            keyFiles: keyFiles,
            keyCommands: keyCommands,
            usageSummary: usageSummary,
            charEstimate: charEstimate,
            dateWindow: dateWindow
        )
    }

    static func makeSession(
        id: String = "session-1",
        provider: String = "claude-code",
        sessionId: String = "s-1",
        projectName: String = "TestProject",
        title: String = "Test Session",
        daysOld: Int = 2,
        bodyText: String = "## Test Session\n\nProvider: Claude Code | Project: TestProject\n\nSummary: Testing context pack export.\n\nKey files: file1.swift\n\nKey commands: npm test\n\nSession body text here."
    ) -> ContextPackSession {
        ContextPackSession(
            id: id,
            provider: provider,
            sessionId: sessionId,
            projectName: projectName,
            title: title,
            startTime: daysAgo(daysOld),
            endTime: daysAgo(daysOld).addingTimeInterval(3600),
            indexedAt: daysAgo(daysOld).addingTimeInterval(7200),
            summary: "Test summary",
            keyFiles: ["file1.swift"],
            keyCommands: ["npm test"],
            keyTools: [],
            messageCount: 10,
            bodyText: bodyText,
            reasonLabel: "same project, recent",
            rankScore: 5.0
        )
    }
}

// MARK: - ContextPackExportTests

@MainActor
final class ContextPackExportTests: XCTestCase {

    // MARK: - VAL-CTXEXP-001: All targets produce semantically equivalent shared body content

    func test_allTargetsContainSameSessionBodyContent() {
        let sessions = [
            ExportFixtures.makeSession(id: "s1", bodyText: "## Session One\n\nProvider: Claude Code | Project: TestProject\n\nKey files: a.swift\n\nKey commands: cmd1\n\nContent of session one."),
            ExportFixtures.makeSession(id: "s2", bodyText: "## Session Two\n\nProvider: Claude Code | Project: TestProject\n\nKey files: b.swift\n\nKey commands: cmd2\n\nContent of session two."),
        ]
        let pack = ExportFixtures.makePack(sessions: sessions)

        let bodies = ContextPackExportTarget.allCases.map { target -> String in
            ContextPackExporter.export(pack, target: target)
        }

        // All exports should contain the session body content
        for (target, body) in zip(ContextPackExportTarget.allCases, bodies) {
            XCTAssertTrue(
                body.contains("## Session One"),
                "[\(target.rawValue)] should contain session one title"
            )
            XCTAssertTrue(
                body.contains("## Session Two"),
                "[\(target.rawValue)] should contain session two title"
            )
            XCTAssertTrue(
                body.contains("Content of session one."),
                "[\(target.rawValue)] should contain session one content"
            )
            XCTAssertTrue(
                body.contains("Content of session two."),
                "[\(target.rawValue)] should contain session two content"
            )
        }
    }

    // MARK: - VAL-CTXEXP-002: Claude and Hermes use CLAUDE-style + context_pack XML envelope

    func test_claudeExportsUseCLAUDEStyleWithXMLEnvelope() {
        let pack = ExportFixtures.makePack()
        let output = ContextPackExporter.export(pack, target: .claude)

        // Should have CLAUDE-style header
        XCTAssertTrue(output.hasPrefix("# Context Pack"), "Claude export should start with CLAUDE-style header")
        XCTAssertTrue(output.contains("# This context pack provides relevant session history and project context."))

        // Should have XML envelope
        XCTAssertTrue(output.contains("<context_pack>"), "Claude export should have opening context_pack tag")
        XCTAssertTrue(output.contains("</context_pack>"), "Claude export should have closing context_pack tag")

        // Should have summary section
        XCTAssertTrue(output.contains("## Summary"), "Claude export should have Summary section")
        XCTAssertTrue(output.contains(pack.usageSummary))

        // Sessions should be inside the envelope
        let envelopeStart = output.range(of: "<context_pack>")!.upperBound
        let envelopeEnd = output.range(of: "</context_pack>")!.lowerBound
        let envelopeContent = String(output[envelopeStart..<envelopeEnd])
        XCTAssertTrue(envelopeContent.contains("## Sessions"), "Sessions should be inside envelope")
    }

    func test_hermesExportsUseCLAUDEStyleWithXMLEnvelope() {
        let pack = ExportFixtures.makePack()
        let output = ContextPackExporter.export(pack, target: .hermes)

        // Hermes uses the same CLAUDE-style + context_pack envelope
        XCTAssertTrue(output.hasPrefix("# Context Pack"), "Hermes export should start with CLAUDE-style header")
        XCTAssertTrue(output.contains("<context_pack>"), "Hermes export should have opening context_pack tag")
        XCTAssertTrue(output.contains("</context_pack>"), "Hermes export should have closing context_pack tag")
        XCTAssertTrue(output.contains("## Summary"))
    }

    // MARK: - VAL-CTXEXP-003: Codex uses minimal ## Context framing

    func test_codexExportsUseMinimalContextFraming() {
        let pack = ExportFixtures.makePack()
        let output = ContextPackExporter.export(pack, target: .codex)

        // Should have minimal ## Context header
        XCTAssertTrue(output.hasPrefix("## Context"), "Codex export should start with ## Context")
        XCTAssertTrue(output.contains("Project: TestProject"), "Codex export should have project info")

        // Should NOT have XML envelope tags
        XCTAssertFalse(output.contains("<context_pack>"), "Codex export should not have context_pack tag")
        XCTAssertFalse(output.contains("</context_pack>"), "Codex export should not have context_pack closing tag")

        // Should have minimal framing (Summary, Key files, Sessions)
        XCTAssertTrue(output.contains("Summary:"), "Codex export should have Summary line")
        XCTAssertTrue(output.contains("Key files:"), "Codex export should have Key files section")
        XCTAssertTrue(output.contains("## Sessions"), "Codex export should have Sessions section")
    }

    // MARK: - VAL-CTXEXP-004: Cursor uses cursorrules-style framing

    func test_cursorExportsUseCursorrulesStyleFraming() {
        let pack = ExportFixtures.makePack()
        let output = ContextPackExporter.export(pack, target: .cursor)

        // Should have cursorrules-style HTML comment header
        XCTAssertTrue(output.contains("<!--"), "Cursor export should have HTML comment opening")
        XCTAssertTrue(output.contains("context-pack:"), "Cursor export should have context-pack marker")
        XCTAssertTrue(output.contains("-->"), "Cursor export should have HTML comment closing")

        // Should have version in metadata
        XCTAssertTrue(output.contains("version: 1.0"), "Cursor export should specify version 1.0")

        // Should use markdown code fences for files and commands
        XCTAssertTrue(output.contains("### Key Files"), "Cursor export should have Key Files section")
        XCTAssertTrue(output.contains("### Key Commands"), "Cursor export should have Key Commands section")
        XCTAssertTrue(output.contains("### Sessions"), "Cursor export should have Sessions section")

        // Should NOT have XML envelope
        XCTAssertFalse(output.contains("<context_pack>"), "Cursor export should not have XML envelope")
    }

    // MARK: - VAL-CTXEXP-005: Markdown uses canonical markdown brief structure

    func test_markdownExportsUseCanonicalBriefStructure() {
        let pack = ExportFixtures.makePack(
            charEstimate: 5000,
            dateWindow: ContextPackDateWindow(
                start: Date(timeIntervalSince1970: 1_739_400_000),
                end: Date(timeIntervalSince1970: 1_740_000_000)
            )
        )
        let output = ContextPackExporter.export(pack, target: .markdown)

        // Should have markdown title
        XCTAssertTrue(output.hasPrefix("# Context Pack"), "Markdown export should start with title")
        XCTAssertTrue(output.contains("TestProject"), "Markdown export should include project name")

        // Should have metadata table
        XCTAssertTrue(output.contains("| Property | Value |"), "Markdown export should have property table header")
        XCTAssertTrue(output.contains("| Sessions |"), "Markdown export should have Sessions row")
        XCTAssertTrue(output.contains("| Est. Characters |"), "Markdown export should have char estimate row")

        // Should have Summary section
        XCTAssertTrue(output.contains("## Summary"), "Markdown export should have Summary section")

        // Should have Key Files and Key Commands sections
        XCTAssertTrue(output.contains("## Key Files"), "Markdown export should have Key Files section")
        XCTAssertTrue(output.contains("## Key Commands"), "Markdown export should have Key Commands section")

        // Should have Sessions section
        XCTAssertTrue(output.contains("## Sessions"), "Markdown export should have Sessions section")

        // Should NOT have XML envelope
        XCTAssertFalse(output.contains("<context_pack>"), "Markdown export should not have XML envelope")
    }

    // MARK: - VAL-CTXEXP-006: Empty pack produces valid empty export for all targets

    func test_emptyPackProducesValidEmptyExport() {
        let emptyPack = ExportFixtures.makePack(sessions: [], keyFiles: [], keyCommands: [])

        for target in ContextPackExportTarget.allCases {
            let output = ContextPackExporter.export(emptyPack, target: target)

            // Should be non-nil and not crash
            XCTAssertNotNil(output, "[\(target.rawValue)] Export should produce output for empty pack")

            // Output should contain basic structure even when empty
            switch target {
            case .claude, .hermes:
                XCTAssertTrue(output.contains("# Context Pack"), "[\(target.rawValue)] Should have header")
                XCTAssertTrue(output.contains("<context_pack>"), "[\(target.rawValue)] Should have XML envelope")
                XCTAssertTrue(output.contains("</context_pack>"), "[\(target.rawValue)] Should have closing tag")
            case .codex:
                XCTAssertTrue(output.contains("## Context"), "[\(target.rawValue)] Should have Context header")
            case .cursor:
                XCTAssertTrue(output.contains("<!--"), "[\(target.rawValue)] Should have HTML comment")
            case .markdown:
                XCTAssertTrue(output.contains("# Context Pack"), "[\(target.rawValue)] Should have title")
            }
        }
    }

    // MARK: - VAL-CTXEXP-007: Locale/timezone-stable deterministic export output

    func test_exportOutputDeterministicAcrossRuns() {
        let sessions = [
            ExportFixtures.makeSession(id: "det-1", bodyText: "## Deterministic Session\n\nProvider: Claude Code | Project: TestProject\n\nSummary: Testing determinism.\n\nKey files: det.swift\n\nKey commands: det-cmd\n\nDeterministic content body."),
        ]
        let pack = ExportFixtures.makePack(sessions: sessions, usageSummary: "1 session; providers: claude-code; ~200 chars")

        for target in ContextPackExportTarget.allCases {
            var results: [String] = []
            for _ in 0..<5 {
                let output = ContextPackExporter.export(pack, target: target)
                results.append(output)
            }

            // All 5 runs should produce identical output
            let first = results[0]
            for (i, result) in results.enumerated() where i > 0 {
                XCTAssertEqual(
                    result,
                    first,
                    "[\(target.rawValue)] Run \(i) produced different output than run 0"
                )
            }
        }
    }

    // MARK: - VAL-CTXEXP-008: Export includes all session data correctly

    func test_exportIncludesAllSessionsAndMetadata() {
        let sessions = [
            ExportFixtures.makeSession(
                id: "multi-1",
                title: "First Session",
                bodyText: "## First Session\n\nProvider: Claude Code | Project: TestProject\n\nSummary: First session summary.\n\nKey files: first.swift\n\nKey commands: first-cmd\n\nFirst session body content."
            ),
            ExportFixtures.makeSession(
                id: "multi-2",
                title: "Second Session",
                bodyText: "## Second Session\n\nProvider: Claude Code | Project: TestProject\n\nSummary: Second session summary.\n\nKey files: second.swift\n\nKey commands: second-cmd\n\nSecond session body content."
            ),
            ExportFixtures.makeSession(
                id: "multi-3",
                title: "Third Session",
                bodyText: "## Third Session\n\nProvider: Claude Code | Project: TestProject\n\nSummary: Third session summary.\n\nKey files: third.swift\n\nKey commands: third-cmd\n\nThird session body content."
            ),
        ]
        let pack = ExportFixtures.makePack(
            sessions: sessions,
            keyFiles: ["file1.swift", "file2.swift", "file3.swift"],
            keyCommands: ["npm test", "npm build", "npm run"],
            usageSummary: "3 sessions; providers: claude-code; ~600 chars"
        )

        for target in ContextPackExportTarget.allCases {
            let output = ContextPackExporter.export(pack, target: target)

            // Verify all sessions are present
            XCTAssertTrue(
                output.contains("## First Session"),
                "[\(target.rawValue)] Should contain first session"
            )
            XCTAssertTrue(
                output.contains("## Second Session"),
                "[\(target.rawValue)] Should contain second session"
            )
            XCTAssertTrue(
                output.contains("## Third Session"),
                "[\(target.rawValue)] Should contain third session"
            )

            // Verify all key files are present
            XCTAssertTrue(
                output.contains("file1.swift"),
                "[\(target.rawValue)] Should contain file1.swift"
            )
            XCTAssertTrue(
                output.contains("file2.swift"),
                "[\(target.rawValue)] Should contain file2.swift"
            )
            XCTAssertTrue(
                output.contains("file3.swift"),
                "[\(target.rawValue)] Should contain file3.swift"
            )

            // Verify all key commands are present
            XCTAssertTrue(
                output.contains("npm test"),
                "[\(target.rawValue)] Should contain npm test"
            )
            XCTAssertTrue(
                output.contains("npm build"),
                "[\(target.rawValue)] Should contain npm build"
            )
            XCTAssertTrue(
                output.contains("npm run"),
                "[\(target.rawValue)] Should contain npm run"
            )

            // Verify usage summary is present
            XCTAssertTrue(
                output.contains("3 sessions"),
                "[\(target.rawValue)] Should contain session count"
            )
        }
    }

    // MARK: - VAL-CTXEXP-009: Project name correctly propagated to exports

    func test_projectNamePropagatedToAllExports() {
        let pack = ExportFixtures.makePack(project: "MyAwesomeProject")

        for target in ContextPackExportTarget.allCases {
            let output = ContextPackExporter.export(pack, target: target)
            XCTAssertTrue(
                output.contains("MyAwesomeProject"),
                "[\(target.rawValue)] Should contain project name 'MyAwesomeProject'"
            )
        }
    }

    func test_nilProjectHandledGracefully() {
        let pack = ExportFixtures.makePack(project: nil)

        for target in ContextPackExportTarget.allCases {
            let output = ContextPackExporter.export(pack, target: target)
            XCTAssertNotNil(output, "[\(target.rawValue)] Should produce output even with nil project")

            // Should not crash and should produce valid output
            switch target {
            case .claude, .hermes:
                XCTAssertTrue(output.hasPrefix("# Context Pack"))
                XCTAssertTrue(output.contains("<context_pack>"))
            case .codex:
                XCTAssertTrue(output.hasPrefix("## Context"))
            case .cursor:
                XCTAssertTrue(output.contains("<!--"))
            case .markdown:
                XCTAssertTrue(output.hasPrefix("# Context Pack"))
            }
        }
    }

    // MARK: - VAL-CTXEXP-010: Shared body semantics equivalence

    func test_sharedBodyContentMatchesAcrossAllTargets() {
        let sessions = [
            ExportFixtures.makeSession(
                id: "equiv-1",
                bodyText: "## Equivalence Test\n\nProvider: Claude Code | Project: TestProject\n\nThis is the exact body text that should appear in all exports."
            ),
        ]
        let pack = ExportFixtures.makePack(sessions: sessions)

        let bodies = ContextPackExportTarget.allCases.map { target -> String in
            ContextPackExporter.export(pack, target: target)
        }

        // All exports should contain the exact session body text
        let expectedBodyText = "## Equivalence Test\n\nProvider: Claude Code | Project: TestProject\n\nThis is the exact body text that should appear in all exports."

        for (target, body) in zip(ContextPackExportTarget.allCases, bodies) {
            XCTAssertTrue(
                body.contains(expectedBodyText),
                "[\(target.rawValue)] Should contain exact shared body text"
            )
        }
    }

    // MARK: - VAL-CTXEXP-011: Target-specific envelope differences

    func test_eachTargetHasDistinctEnvelopeStructure() {
        let pack = ExportFixtures.makePack(
            sessions: [ExportFixtures.makeSession()],
            keyFiles: ["a.swift"],
            keyCommands: ["cmd"]
        )

        let outputs = Dictionary(
            uniqueKeysWithValues: ContextPackExportTarget.allCases.map { target in
                (target, ContextPackExporter.export(pack, target: target))
            }
        )

        // CLAUDE and HERMES should have XML envelope
        XCTAssertTrue(outputs[.claude]!.contains("<context_pack>"))
        XCTAssertTrue(outputs[.hermes]!.contains("<context_pack>"))

        // CODEX should NOT have XML envelope
        XCTAssertFalse(outputs[.codex]!.contains("<context_pack>"))

        // CURSOR should have HTML comment style
        XCTAssertTrue(outputs[.cursor]!.contains("<!--"))
        XCTAssertTrue(outputs[.cursor]!.contains("-->"))

        // MARKDOWN should have table format
        XCTAssertTrue(outputs[.markdown]!.contains("| Property | Value |"))

        // CODEX should have minimal ## Context header
        XCTAssertTrue(outputs[.codex]!.hasPrefix("## Context"))
        XCTAssertFalse(outputs[.claude]!.hasPrefix("## Context"))
        XCTAssertFalse(outputs[.cursor]!.hasPrefix("## Context"))
    }

    // MARK: - VAL-CTXEXP-012: Export file extension mapping

    func test_exportTargetFileExtensions() {
        XCTAssertEqual(ContextPackExportTarget.claude.fileExtension, "txt")
        XCTAssertEqual(ContextPackExportTarget.codex.fileExtension, "txt")
        XCTAssertEqual(ContextPackExportTarget.cursor.fileExtension, "txt")
        XCTAssertEqual(ContextPackExportTarget.hermes.fileExtension, "txt")
        XCTAssertEqual(ContextPackExportTarget.markdown.fileExtension, "md")
    }

    // MARK: - VAL-CTXEXP-013: Export target display names

    func test_exportTargetDisplayNames() {
        XCTAssertEqual(ContextPackExportTarget.claude.displayName, "Claude Code")
        XCTAssertEqual(ContextPackExportTarget.codex.displayName, "Codex")
        XCTAssertEqual(ContextPackExportTarget.cursor.displayName, "Cursor")
        XCTAssertEqual(ContextPackExportTarget.hermes.displayName, "Hermes")
        XCTAssertEqual(ContextPackExportTarget.markdown.displayName, "Markdown")
    }

    // MARK: - VAL-CTXEXP-014: XML-sensitive key-files and key-commands preserve envelope integrity

    func test_xmlSensitiveKeyFilesAndCommandsPreserveEnvelopeIntegrity() {
        // Filenames and commands containing XML-sensitive characters
        let xmlSensitiveFiles = [
            "path/to/file<with>angles.swift",
            "script<alert>('xss').js",
            "module&module.ts",
            "test\"quote\".py",
            "array['key'].rb"
        ]
        let xmlSensitiveCommands = [
            "echo 'hello & goodbye'",
            "npm run build <file.txt",
            "cat > output.txt",
            "grep -E 'pattern|another' file",
            "curl -X POST \"http://example.com\""
        ]

        let pack = ExportFixtures.makePack(
            sessions: [ExportFixtures.makeSession()],
            keyFiles: xmlSensitiveFiles,
            keyCommands: xmlSensitiveCommands
        )

        for target in [ContextPackExportTarget.claude, ContextPackExportTarget.hermes] {
            let output = ContextPackExporter.export(pack, target: target)

            // Verify envelope tags are present and properly formed
            let openTagCount = output.components(separatedBy: "<context_pack>").count - 1
            let closeTagCount = output.components(separatedBy: "</context_pack>").count - 1
            XCTAssertEqual(openTagCount, 1, "[\(target.rawValue)] Should have exactly one opening context_pack tag")
            XCTAssertEqual(closeTagCount, 1, "[\(target.rawValue)] Should have exactly one closing context_pack tag")

            // Verify the envelope is properly closed (opening tag comes before closing tag)
            if let openRange = output.range(of: "<context_pack>"),
               let closeRange = output.range(of: "</context_pack>") {
                XCTAssertLessThan(openRange.lowerBound, closeRange.lowerBound,
                    "[\(target.rawValue)] Opening tag should come before closing tag")
            }

            // Verify XML-escaped content appears in output
            // < should become &lt;
            XCTAssertTrue(output.contains("&lt;"),
                "[\(target.rawValue)] Should contain escaped < character")
            // > should become &gt;
            XCTAssertTrue(output.contains("&gt;"),
                "[\(target.rawValue)] Should contain escaped > character")
            // & should become &amp;
            XCTAssertTrue(output.contains("&amp;"),
                "[\(target.rawValue)] Should contain escaped & character")

            // Verify raw XML-sensitive characters do NOT appear inside the envelope
            let envelopeContent: String
            if let openRange = output.range(of: "<context_pack>"),
               let closeRange = output.range(of: "</context_pack>") {
                envelopeContent = String(output[openRange.upperBound..<closeRange.lowerBound])
            } else {
                envelopeContent = output
            }

            // These raw sequences should NOT appear inside the envelope
            XCTAssertFalse(envelopeContent.contains("<context_pack>"),
                "[\(target.rawValue)] No nested context_pack tags should exist inside envelope")
            XCTAssertFalse(envelopeContent.contains("</context_pack>"),
                "[\(target.rawValue)] No nested closing tags should exist inside envelope")
        }
    }

    func test_xmlSensitiveFilenamesAreProperlyEscapedInExports() {
        // Test that XML-sensitive filenames are escaped only in XML envelope targets
        // (claude/hermes). Other targets (codex, cursor, markdown) don't use XML
        let xmlSensitiveFiles = ["file<with>angles.swift", "test\"quote\".py"]

        let pack = ExportFixtures.makePack(
            sessions: [ExportFixtures.makeSession()],
            keyFiles: xmlSensitiveFiles,
            keyCommands: ["npm test"]
        )

        // Only XML-enveloped targets require escaping
        let xmlTargets: [ContextPackExportTarget] = [.claude, .hermes]

        for target in xmlTargets {
            let output = ContextPackExporter.export(pack, target: target)

            // The escaped version should appear
            XCTAssertTrue(output.contains("file&lt;with&gt;angles.swift") ||
                         output.contains("file&lt;with&gt;angles"),
                "[\(target.rawValue)] Should contain escaped filename")
            XCTAssertTrue(output.contains("test&quot;quote&quot;.py") ||
                         output.contains("test&quot;quote&quot;"),
                "[\(target.rawValue)] Should contain escaped quote in filename")
        }

        // Non-XML targets should still contain the raw filenames (no escaping needed)
        let codexOutput = ContextPackExporter.export(pack, target: .codex)
        XCTAssertTrue(codexOutput.contains("file<with>angles.swift"),
            "[codex] Should contain raw filename (no XML escaping needed)")
    }
}
