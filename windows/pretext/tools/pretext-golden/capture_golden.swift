import WebKit
import Foundation

// Headless WKWebView golden capture for the Pretext parity corpus.
// Loads the VERBATIM pretext.bundle.min.js + runs each corpus case through the
// SAME method table as the WebView2 bridge, emitting golden.mac.json.

let args = CommandLine.arguments
guard args.count >= 4 else { FileHandle.standardError.write("usage: capture <bundle.js> <corpus.json> <out.json>\n".data(using: .utf8)!); exit(2) }
let bundlePath = args[1], corpusPath = args[2], outPath = args[3]

let bundle = try String(contentsOfFile: bundlePath, encoding: .utf8)
let corpusText = try String(contentsOfFile: corpusPath, encoding: .utf8)

// The measure script mirrors Resources/Pretext/index.html method-for-method.
let measureScript = """
window.__corpus = \(corpusText);
window.__measureAll = function () {
  var Pretext = window.Pretext, RI = window.PretextRichInline;
  var out = {};
  var cases = window.__corpus.cases || [];
  for (var i = 0; i < cases.length; i++) {
    var c = cases[i];
    try {
      var opts = c.options || undefined;
      if (c.method === 'layout') {
        var p = Pretext.prepare(c.text, c.font, opts);
        var r = Pretext.layout(p, c.maxWidth, c.lineHeight);
        out[c.id] = { height: r.height, lineCount: r.lineCount };
      } else if (c.method === 'layoutWithLines') {
        var p2 = Pretext.prepareWithSegments(c.text, c.font, opts);
        var r2 = Pretext.layoutWithLines(p2, c.maxWidth, c.lineHeight);
        out[c.id] = {
          height: r2.height, lineCount: r2.lineCount,
          lineWidths: r2.lines.map(function (l) { return l.width; }),
          lineTexts: r2.lines.map(function (l) { return l.text; })
        };
      } else if (c.method === 'measureLineStats') {
        var p3 = Pretext.prepare(c.text, c.font, opts);
        var s = Pretext.measureLineStats(p3, c.maxWidth);
        out[c.id] = { lineCount: s.lineCount, maxLineWidth: s.maxLineWidth };
      } else if (c.method === 'measureNaturalWidth') {
        var p4 = Pretext.prepare(c.text, c.font, opts);
        out[c.id] = { width: Pretext.measureNaturalWidth(p4) };
      } else if (c.method === 'layoutRichInline') {
        var items = (c.items || []).map(function (it) {
          var e = { text: it.text, font: it.font, extraWidth: it.extraWidth || 0 };
          if (it.breakNever) e.break = 'never';
          return e;
        });
        var pr = RI.prepareRichInline(items);
        var widths = [];
        RI.walkRichInlineLineRanges(pr, c.maxWidth, function (range) {
          var line = RI.materializeRichInlineLineRange(pr, range);
          widths.push(line.width);
        });
        out[c.id] = { lineCount: widths.length, lineWidths: widths };
      } else {
        out[c.id] = { error: 'unknown method ' + c.method };
      }
    } catch (e) {
      out[c.id] = { error: String(e && e.message ? e.message : e) };
    }
  }
  return out;
};
"""

final class Cap: NSObject, WKNavigationDelegate {
    let out: String
    init(out: String) { self.out = out }
    func webView(_ w: WKWebView, didFinish n: WKNavigation!) {
        w.evaluateJavaScript("JSON.stringify(window.__measureAll())") { r, e in
            if let e { FileHandle.standardError.write("EVAL ERR \(e)\n".data(using: .utf8)!); exit(3) }
            guard let s = r as? String else { FileHandle.standardError.write("no result\n".data(using: .utf8)!); exit(4) }
            // Wrap results with metadata into the golden schema.
            let results = s
            let golden = """
            {
              "schemaVersion": 1,
              "capturedOn": "macos-webkit",
              "engine": "WebKit (WKWebView, macOS headless capture)",
              "note": "Authoritative Mac golden captured from the verbatim pretext.bundle.min.js via headless WKWebView. Regenerate with tools/pretext-golden/capture_golden.swift.",
              "results": \(results)
            }
            """
            do {
                try golden.write(toFile: self.out, atomically: true, encoding: .utf8)
            } catch {
                FileHandle.standardError.write("WRITE ERR \(error)\n".data(using: .utf8)!)
                exit(7)
            }
            FileHandle.standardError.write("WROTE \(self.out)\n".data(using: .utf8)!)
            exit(0)
        }
    }
    func webView(_ w: WKWebView, didFail n: WKNavigation!, withError e: Error) { FileHandle.standardError.write("navFail \(e)\n".data(using: .utf8)!); exit(5) }
}
let wv = WKWebView(frame: .zero)
let cap = Cap(out: outPath)
wv.navigationDelegate = cap
let html = "<!doctype html><html><head><meta charset='utf-8'></head><body><script>\(bundle)</script><script>\(measureScript)</script></body></html>"
wv.loadHTMLString(html, baseURL: nil)
DispatchQueue.main.asyncAfter(deadline: .now() + 20) { FileHandle.standardError.write("TIMEOUT\n".data(using: .utf8)!); exit(6) }
RunLoop.main.run()
