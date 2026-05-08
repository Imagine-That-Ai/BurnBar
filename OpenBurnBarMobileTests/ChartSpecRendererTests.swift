import XCTest
@testable import OpenBurnBarMobile

final class ChartSpecRendererTests: XCTestCase {

    func testDecodesNativeChartEnvelope() {
        let json = #"""
        {"kind":"swift_chart","title":"Cost","swift_chart":{"kind":"bar","title":"Cost","series":[{"name":"USD","points":[{"x":"Claude Code","y":92.10},{"x":"Codex","y":24.80}]}],"valueFormat":"currency"}}
        """#
        let result = ChartSpecRenderer.decode(json)
        if case .swiftChart(let spec) = result {
            XCTAssertEqual(spec.kind, .bar)
            XCTAssertEqual(spec.series.count, 1)
            XCTAssertEqual(spec.series[0].points.count, 2)
        } else {
            XCTFail("Expected swiftChart, got \(result)")
        }
    }

    func testDecodesMermaidEnvelope() {
        let json = #"""
        {"kind":"mermaid","title":"Flow","mermaid":{"title":"Flow","source":"sequenceDiagram\\nA->>B: hi"}}
        """#
        let result = ChartSpecRenderer.decode(json)
        if case .mermaid(let spec) = result {
            XCTAssertEqual(spec.title, "Flow")
            XCTAssertTrue(spec.source.contains("sequenceDiagram"))
        } else {
            XCTFail("Expected mermaid, got \(result)")
        }
    }

    func testDecodesInsightEnvelope() {
        let json = #"""
        {"kind":"insight","title":"Saved","insight":{"title":"You saved $12.40","body":"Cache reads carried 58%.","sparkline":[1,2,3],"tone":"positive"}}
        """#
        let result = ChartSpecRenderer.decode(json)
        if case .insight(let spec) = result {
            XCTAssertEqual(spec.tone, "positive")
            XCTAssertEqual(spec.sparkline?.count, 3)
        } else {
            XCTFail("Expected insight, got \(result)")
        }
    }

    func testDecodesComposedEnvelope() {
        let json = #"""
        {
          "kind": "composed",
          "title": "Mixed",
          "components": [
            {"kind":"insight","title":"Saved","insight":{"title":"Note","body":"Hi","sparkline":[1,2],"tone":"neutral"}},
            {"kind":"mermaid","mermaid":{"source":"graph TD\nA-->B"}}
          ]
        }
        """#
        let result = ChartSpecRenderer.decode(json)
        if case .composed(let items) = result {
            XCTAssertEqual(items.count, 2)
        } else {
            XCTFail("Expected composed, got \(result)")
        }
    }

    func testDecodesAsciiEnvelope() {
        let json = #"""
        {
          "kind": "ascii",
          "title": "Cost by provider",
          "ascii": {
            "title": "Cost by provider",
            "subtitle": "USD, last 7 days",
            "variant": "bar",
            "blocks": [
              {"label":"Claude Code","lines":["▉▉▉▉▉▉▉▉  $92.10"],"accent":"#E07868"},
              {"label":"Codex","lines":["▉▉▉  $24.80"],"accent":"#9080D8"}
            ],
            "footnote": "7-day window"
          }
        }
        """#
        let result = ChartSpecRenderer.decode(json)
        if case .ascii(let spec) = result {
            XCTAssertEqual(spec.variant, .bar)
            XCTAssertEqual(spec.blocks.count, 2)
            XCTAssertEqual(spec.blocks[0].accent, "#E07868")
            XCTAssertTrue(spec.blocks[0].lines[0].contains("▉"))
        } else {
            XCTFail("Expected ascii, got \(result)")
        }
    }

    func testAsciiSanitizerCapsLineWidthAndBlockCount() {
        let runaway = String(repeating: "█", count: 500)
        let manyBlocks = (0..<30).map { i in
            AsciiSpec.Block(label: "block-\(i)", lines: [runaway])
        }
        let spec = AsciiSpec(
            title: "huge",
            subtitle: nil,
            variant: .bar,
            blocks: manyBlocks,
            footnote: nil
        )
        let cleaned = ChartSpecRenderer.sanitizeAscii(spec)
        XCTAssertLessThanOrEqual(cleaned.blocks.count, 12,
                                 "Sanitizer must cap block count to keep payload small.")
        for block in cleaned.blocks {
            for line in block.lines {
                XCTAssertLessThanOrEqual(line.count, 96,
                                         "Each line must be capped to <= 96 cells.")
            }
        }
    }

    func testAsciiSanitizerStripsAnsiEscapes() {
        let raw = "\u{1B}[31m▉▉▉ red bar\u{1B}[0m"
        let block = AsciiSpec.Block(label: nil, lines: [raw])
        let spec = AsciiSpec(variant: .bar, blocks: [block])
        let cleaned = ChartSpecRenderer.sanitizeAscii(spec)
        let line = cleaned.blocks[0].lines[0]
        XCTAssertFalse(line.contains("\u{1B}["), "ANSI escapes must be stripped.")
        XCTAssertTrue(line.contains("▉"))
    }

    func testExtractsJSONFromProseWrapped() {
        let raw = """
        Sure, here's the chart you asked for:
        ```json
        {"kind":"insight","title":"Hello","insight":{"title":"Hi","body":"world"}}
        ```
        Hope that helps!
        """
        let result = ChartSpecRenderer.decode(raw)
        if case .insight(let spec) = result {
            XCTAssertEqual(spec.title, "Hi")
        } else {
            XCTFail("Expected to recover JSON from prose, got \(result)")
        }
    }

    func testMalformedJSONReturnsErrorRendering() {
        let raw = "definitely not json at all"
        let result = ChartSpecRenderer.decode(raw)
        if case .error(let msg) = result {
            XCTAssertFalse(msg.isEmpty)
        } else {
            XCTFail("Expected error rendering")
        }
    }

    func testExtractFirstJSONObjectHandlesNestedBraces() {
        let raw = "preface {\"a\": {\"b\": 1}, \"c\": [1,2,3]} suffix"
        let extracted = ChartSpecRenderer.extractFirstJSONObject(raw)
        XCTAssertEqual(extracted, "{\"a\": {\"b\": 1}, \"c\": [1,2,3]}")
    }
}

// MARK: - Mermaid Sanitization

final class MermaidSanitizationTests: XCTestCase {

    func testStripsScriptTag() {
        let raw = "graph TD\n<script>alert(1)</script>\nA-->B"
        let sanitized = ChartSpecRenderer.sanitizeMermaid(raw)
        XCTAssertFalse(sanitized.contains("<script>"))
    }

    func testStripsJavaScriptProtocol() {
        let raw = "click A javascript:alert(1) \"x\""
        let sanitized = ChartSpecRenderer.sanitizeMermaid(raw)
        XCTAssertFalse(sanitized.lowercased().contains("javascript:"))
    }

    func testStripsInlineEventHandlers() {
        let raw = "<div onclick=\"x()\">A</div>"
        let sanitized = ChartSpecRenderer.sanitizeMermaid(raw)
        XCTAssertFalse(sanitized.lowercased().contains("onclick"))
    }

    func testStripsCodeFences() {
        let raw = """
        ```mermaid
        graph TD
          A-->B
        ```
        """
        let sanitized = ChartSpecRenderer.sanitizeMermaid(raw)
        XCTAssertFalse(sanitized.contains("```"))
        XCTAssertTrue(sanitized.contains("graph TD"))
    }
}
