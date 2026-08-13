import Foundation
import OpenBurnBarKernel

enum SafariLearningSecurity {
    struct SanitizedText: Sendable, Equatable {
        let text: String
        let redactionFindingIDs: [String]
    }

    static func sanitizeForPersistence(_ raw: String) throws -> SanitizedText {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        let explicitSensitiveFindings = explicitSensitiveFindings(in: trimmed)
        if explicitSensitiveFindings.isEmpty == false {
            throw SafariLearningCoordinatorError.sensitiveContentRejected(
                explicitSensitiveFindings
            )
        }
        let initial = MemorySecretPIIGate.evaluate(trimmed, policy: .reject)
        let initialFindings = initial.findings
        let secrets = initialFindings.filter { $0.kind == .secret }
        if secrets.isEmpty == false {
            throw SafariLearningCoordinatorError.sensitiveContentRejected(
                secrets.map(\.id)
            )
        }
        guard initialFindings.isEmpty == false else {
            return SanitizedText(text: trimmed, redactionFindingIDs: [])
        }

        switch MemorySecretPIIGate.evaluate(trimmed, policy: .redact) {
        case .allow:
            return SanitizedText(text: trimmed, redactionFindingIDs: [])
        case .redact(let text, let findings):
            let residual = MemorySecretPIIGate.findings(in: text)
            guard residual.isEmpty else {
                throw SafariLearningCoordinatorError.sensitiveContentRejected(
                    residual.map(\.id)
                )
            }
            return SanitizedText(
                text: text.trimmingCharacters(in: .whitespacesAndNewlines),
                redactionFindingIDs: stableUnique(findings.map(\.id))
            )
        case .reject(let findings):
            throw SafariLearningCoordinatorError.sensitiveContentRejected(
                findings.map(\.id)
            )
        }
    }

    /// Scans every user/model/page-controlled field that will be materialized into
    /// a portable SKILL.md. Learned skills are instruction-bearing artifacts, so
    /// v1 deliberately quarantines executable structures instead of attempting
    /// to prove an arbitrary script safe.
    static func skillInjectionFindings(fields: [String]) -> [String] {
        let combined = fields.joined(separator: "\n")
        let folded = normalizedForSecurityScanning(combined)
            .lowercased()
        let compact = folded.unicodeScalars
            .filter { CharacterSet.alphanumerics.contains($0) }
            .map(String.init)
            .joined()
        var findings: [String] = []

        let phraseRules: [(String, String)] = [
            ("ignore previous", "prompt-injection:ignore-previous"),
            ("ignore all previous", "prompt-injection:ignore-previous"),
            ("ignore the system", "prompt-injection:ignore-system"),
            ("ignore developer", "prompt-injection:ignore-developer"),
            ("system prompt", "prompt-injection:system-prompt"),
            ("developer message", "prompt-injection:developer-message"),
            ("you are now", "prompt-injection:role-reassignment"),
            ("act as root", "prompt-injection:privilege-escalation"),
            ("jailbreak", "prompt-injection:jailbreak"),
            ("do not tell the user", "prompt-injection:concealment"),
            ("without asking", "prompt-injection:bypass-approval"),
            ("without approval", "prompt-injection:bypass-approval"),
            ("bypass approval", "prompt-injection:bypass-approval"),
            ("disable safety", "prompt-injection:disable-safety"),
            ("reveal secret", "prompt-injection:secret-exfiltration"),
            ("exfiltrate", "prompt-injection:exfiltration"),
            ("document.cookie", "script-access:cookie"),
            ("localstorage", "script-access:local-storage"),
            ("sessionstorage", "script-access:session-storage"),
            ("launchctl", "auto-run:launchctl"),
            ("crontab", "auto-run:cron"),
            ("curl | sh", "script-execution:pipe-shell"),
            ("curl|sh", "script-execution:pipe-shell"),
            ("wget | sh", "script-execution:pipe-shell"),
            ("wget|sh", "script-execution:pipe-shell"),
            ("rm -rf", "script-execution:destructive-shell"),
            ("sudo ", "script-execution:privileged-shell"),
            ("osascript", "script-execution:apple-events")
        ]
        for (needle, finding) in phraseRules where folded.contains(needle) {
            findings.append(finding)
        }

        // Catch spacing, punctuation, and zero-width obfuscation of the highest
        // confidence phrases without relying on locale-sensitive word matching.
        let compactRules: [(String, String)] = [
            ("ignoreprevious", "prompt-injection:ignore-previous"),
            ("ignoreallprevious", "prompt-injection:ignore-previous"),
            ("ignoresystem", "prompt-injection:ignore-system"),
            ("ignoredeveloper", "prompt-injection:ignore-developer"),
            ("systemprompt", "prompt-injection:system-prompt"),
            ("developermessage", "prompt-injection:developer-message"),
            ("youarenow", "prompt-injection:role-reassignment"),
            ("bypassapproval", "prompt-injection:bypass-approval"),
            ("disablesafety", "prompt-injection:disable-safety"),
            ("documentcookie", "script-access:cookie"),
            ("localstorage", "script-access:local-storage"),
            ("sessionstorage", "script-access:session-storage"),
            ("launchctl", "auto-run:launchctl"),
            ("crontab", "auto-run:cron"),
            ("curlsh", "script-execution:pipe-shell"),
            ("wgetsh", "script-execution:pipe-shell"),
            ("rmrf", "script-execution:destructive-shell")
        ]
        for (needle, finding) in compactRules where compact.contains(needle) {
            findings.append(finding)
        }

        let regexRules: [(String, String)] = [
            (#"(?is)<\s*(system|assistant|developer)(?:\s|>)"#, "prompt-injection:forged-role-tag"),
            (#"(?is)<!--.*?(ignore|system|developer|instruction).*?-->"#, "prompt-injection:hidden-comment"),
            (#"(?im)^\s*(system|assistant|developer)\s*:"# , "prompt-injection:forged-role-line"),
            (#"(?i)\b(?:javascript|data|file)\s*:"# , "unsafe-url-scheme"),
            (#"(?im)^\s*(?:`{3,}|~{3,})[^\n]*$"#, "script-ast:fenced-code"),
            (#"(?is)<\s*(?:script|iframe|object|embed|applet)\b"#, "script-ast:active-html"),
            (#"(?is)<\s*(?:form|link|meta|svg)\b[^>]*(?:action|href|http-equiv|on[a-z]{3,})\s*="#, "script-ast:active-html"),
            (#"(?is)\bon[a-z]{3,}\s*="#, "script-ast:inline-event-handler"),
            (#"(?im)^\s*(?:auto[_-]?run|autorun|cron|schedule|hook)\s*:\s*(?:true|yes|on|[1-9])\b"#, "auto-run:declaration"),
            (#"(?i)\b(?:bash|zsh|sh|fish)\s+-c\b"#, "script-execution:shell-interpreter"),
            (#"(?i)\b(?:python(?:3)?\s+-c|node\s+-e|ruby\s+-e|perl\s+-e)\b"#, "script-execution:language-interpreter"),
            (#"(?i)\b(?:child_process|subprocess\.(?:run|popen|call)|os\.system|Process\s*\(|NSTask)\b"#, "script-execution:process-api"),
            (#"(?m)^\s*(?:eval|exec)\s*\("#, "script-execution:dynamic-eval"),
            (#"\$\([^)]+\)"#, "script-execution:command-substitution"),
            (#"`[^`\n]*(?:curl|wget|sudo|rm\s+-rf|launchctl|crontab)[^`\n]*`"#, "script-execution:inline-shell")
        ]
        for (pattern, finding) in regexRules {
            if matches(pattern, in: folded) {
                findings.append(finding)
            }
        }

        if combined.unicodeScalars.contains(where: {
            (0x202A...0x202E).contains($0.value)
                || (0x2066...0x2069).contains($0.value)
        }) {
            findings.append("prompt-injection:bidi-control")
        }

        let secretFindings = MemorySecretPIIGate.findings(in: combined)
        findings.append(contentsOf: secretFindings.map { "sensitive:\($0.id)" })
        return stableUnique(findings)
    }

    static func skillInjectionFindings(title: String, content: String) -> [String] {
        skillInjectionFindings(fields: [title, content])
    }

    static func isNoisyObservation(_ content: String) -> Bool {
        let trimmed = content.trimmingCharacters(in: .whitespacesAndNewlines)
        let folded = trimmed.lowercased()
        let exactNoise: Set<String> = [
            "done", "success", "successful", "it worked", "fixed", "page loaded",
            "clicked", "complete", "completed", "ok", "okay", "thanks", "thank you"
        ]
        if exactNoise.contains(folded) {
            return true
        }
        if folded.contains("<html")
            || folded.contains("<!doctype")
            || folded.contains("<body")
            || folded.contains("<script")
            || folded.contains("<style")
            || folded.contains("__next_data__")
            || folded.contains("webpackchunk") {
            return true
        }
        let lines = trimmed.split(whereSeparator: \.isNewline)
        if lines.count > 40 {
            return true
        }
        if trimmed.utf8.count > 8 * 1_024 {
            return true
        }
        if trimmed.utf8.count > 4 * 1_024, lines.count > 16 {
            return true
        }
        if matches(#"(?is)(?:<\s*[a-z][^>]{0,256}>.*?){4,}"#, in: trimmed) {
            return true
        }
        if trimmed.utf8.count > 2 * 1_024,
           matchCount(#""[^"\n]{1,80}"\s*:"# , in: trimmed, stoppingAt: 24) >= 24 {
            return true
        }

        let visible = trimmed.unicodeScalars.filter {
            CharacterSet.whitespacesAndNewlines.contains($0) == false
        }
        guard visible.count >= 8 else { return true }
        let distinct = Set(visible.map(\.value))
        if distinct.count <= 3 {
            return true
        }
        let words = trimmed.split { $0.isWhitespace || $0.isNewline }
        let alphabeticWords = words.filter { word in
            word.unicodeScalars.contains { CharacterSet.letters.contains($0) }
        }
        return alphabeticWords.count < 3
    }

    static func stableUnique(_ values: [String]) -> [String] {
        var seen = Set<String>()
        return values.filter { seen.insert($0).inserted }
    }

    private static func explicitSensitiveFindings(in text: String) -> [String] {
        let rules: [(String, String)] = [
            (
                #"(?im)^\s*(?:authorization|proxy-authorization|cookie|set-cookie|x-api-key)\s*:\s*\S+"#,
                "safari-sensitive-header"
            ),
            (
                #"(?i)\b(?:api[_ -]?key|access[_ -]?token|refresh[_ -]?token|id[_ -]?token|session[_ -]?(?:id|token|key)|password|passwd|client[_ -]?secret|private[_ -]?key)\b\s*[:=]\s*(?:bearer\s+)?[^\s,;]{3,}"#,
                "safari-credential-assignment"
            ),
            (
                #"(?i)\bdocument\s*\.\s*cookie\b\s*(?:[=;]|\[)"#,
                "safari-cookie-material"
            ),
            (
                #"(?i)\b(?:localStorage|sessionStorage)\s*(?:\.|\[)"#,
                "safari-browser-storage-material"
            )
        ]
        return stableUnique(
            rules.compactMap { pattern, finding in
                matches(pattern, in: text) ? finding : nil
            }
        )
    }

    private static func normalizedForSecurityScanning(_ text: String) -> String {
        let compatibilityNormalized = text.precomposedStringWithCompatibilityMapping
            .folding(
                options: [.caseInsensitive, .diacriticInsensitive],
                locale: Locale(identifier: "en_US_POSIX")
            )
        let removedFormatScalars = compatibilityNormalized.unicodeScalars.filter { scalar in
            switch scalar.value {
            case 0x200B...0x200F, 0x202A...0x202E, 0x2060...0x206F, 0xFEFF:
                return false
            default:
                return true
            }
        }
        return String(removedFormatScalars.map(Character.init))
    }

    private static func matches(_ pattern: String, in text: String) -> Bool {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return false
        }
        return expression.firstMatch(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) != nil
    }

    private static func matchCount(
        _ pattern: String,
        in text: String,
        stoppingAt limit: Int
    ) -> Int {
        guard let expression = try? NSRegularExpression(pattern: pattern) else {
            return 0
        }
        var count = 0
        expression.enumerateMatches(
            in: text,
            range: NSRange(text.startIndex..., in: text)
        ) { _, _, stop in
            count += 1
            if count >= limit {
                stop.pointee = true
            }
        }
        return count
    }
}

private func stableUnique(_ values: [String]) -> [String] {
    SafariLearningSecurity.stableUnique(values)
}
