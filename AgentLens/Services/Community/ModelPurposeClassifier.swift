import Foundation
import OpenBurnBarCore

/// Canonical model-purpose classifier — port of `functions/src/community/classifier.ts`.
enum ModelPurposeCategory: String, Sendable, CaseIterable {
    case ui
    case backend
    case logic
    case writing
    case research
    case debugging
    case orchestration
    case other
}

struct ClassifierSignals: Sendable, Equatable {
    var fileExtensions: [String]?
    var model: String?
    var appSurface: String?
    var hasCodeExecution: Bool?
    var hasErrorOutput: Bool?
    var hasSearchResults: Bool?
    var hasMultiStepPlanning: Bool?
    var keywords: [String]?
}

struct PurposeCorrection: Sendable, Equatable {
    var fingerprint: String
    var correctedTo: ModelPurposeCategory
}

struct ClassificationResult: Sendable, Equatable {
    var category: ModelPurposeCategory
    var confidence: Double
    var contributingSignals: [String]
}

enum ModelPurposeClassifier {
    private static let fileExtensionMap: [String: ModelPurposeCategory] = [
        "swift": .ui, "xaml": .ui, "css": .ui, "scss": .ui, "html": .ui, "vue": .ui, "svelte": .ui,
        "go": .backend, "rs": .backend, "py": .backend, "java": .backend, "kt": .backend,
        "sql": .backend, "proto": .backend, "grpc": .backend,
        "ts": .logic, "tsx": .logic, "js": .logic, "mjs": .logic, "cjs": .logic, "dart": .logic,
        "md": .writing, "txt": .writing, "rst": .writing, "docx": .writing, "pdf": .writing,
        "json": .research, "yaml": .research, "yml": .research, "csv": .research, "toml": .research,
    ]

    private static let keywordMap: [String: ModelPurposeCategory] = [
        "ui": .ui, "design": .ui, "frontend": .ui, "layout": .ui, "view": .ui, "button": .ui,
        "animation": .ui, "theme": .ui, "color": .ui, "responsive": .ui, "accessibility": .ui,
        "api": .backend, "server": .backend, "database": .backend, "migration": .backend,
        "endpoint": .backend, "auth": .backend, "docker": .backend,
        "kubernetes": .backend, "grpc": .backend,
        "refactor": .logic, "algorithm": .logic, "function": .logic, "type": .logic,
        "interface": .logic, "state": .logic, "model": .logic, "parse": .logic,
        "docs": .writing, "documentation": .writing, "readme": .writing, "blog": .writing,
        "article": .writing, "essay": .writing, "summary": .writing,
        "research": .research, "search": .research, "analyze": .research, "data": .research,
        "benchmark": .research, "evaluate": .research,
        "bug": .debugging, "error": .debugging, "fix": .debugging, "crash": .debugging,
        "stacktrace": .debugging, "debug": .debugging, "test": .debugging, "fail": .debugging,
        "plan": .orchestration, "workflow": .orchestration, "pipeline": .orchestration,
        "agent": .orchestration, "automate": .orchestration, "schedule": .orchestration,
        "mission": .orchestration, "deploy": .orchestration,
    ]

    /// ORDERED — first substring match wins (see `model-bias-tie-order` golden).
    private static let modelBias: [(substring: String, bias: [ModelPurposeCategory: Double])] = [
        ("o1", [.research: 0.3, .logic: 0.2]),
        ("o3", [.research: 0.3, .logic: 0.2]),
        ("deepseek", [.logic: 0.3, .backend: 0.2]),
        ("claude-3.5-sonnet", [.writing: 0.15, .logic: 0.15]),
        ("gpt-4o", [.ui: 0.1, .writing: 0.1]),
        ("llama", [.backend: 0.15]),
    ]

    private static let surfaceBias: [String: [ModelPurposeCategory: Double]] = [
        "chat": [:],
        "dashboard": [.orchestration: 0.1],
        "editor": [.logic: 0.1],
        "terminal": [.debugging: 0.15, .backend: 0.1],
    ]

    static func signalFingerprint(_ signals: ClassifierSignals) -> String {
        var parts: [String] = []
        if let ext = signals.fileExtensions {
            parts.append("ext:\(ext.map { $0.lowercased() }.sorted().joined(separator: ","))")
        }
        if let surf = signals.appSurface { parts.append("surf:\(surf)") }
        if signals.hasCodeExecution == true { parts.append("exec") }
        if signals.hasErrorOutput == true { parts.append("err") }
        if signals.hasSearchResults == true { parts.append("search") }
        if signals.hasMultiStepPlanning == true { parts.append("plan") }
        return parts.isEmpty ? "default" : parts.joined(separator: "|")
    }

    static func classifyPurpose(
        _ signals: ClassifierSignals,
        corrections: [PurposeCorrection] = []
    ) -> ClassificationResult {
        let fp = signalFingerprint(signals)
        if let match = corrections.first(where: { $0.fingerprint == fp }) {
            return ClassificationResult(category: match.correctedTo, confidence: 1.0, contributingSignals: ["user_correction"])
        }

        var scores = Dictionary(uniqueKeysWithValues: ModelPurposeCategory.allCases.map { ($0, 0.0) })
        var contributing: [String] = []

        if let extensions = signals.fileExtensions {
            for ext in extensions {
                let key = ext.lowercased()
                if let cat = fileExtensionMap[key] {
                    scores[cat, default: 0] += 1.0
                    contributing.append("file:\(ext)")
                }
            }
        }

        if let keywords = signals.keywords {
            for kw in keywords {
                let key = kw.lowercased()
                if let cat = keywordMap[key] {
                    scores[cat, default: 0] += 0.5
                    contributing.append("keyword:\(kw)")
                }
            }
        }

        if signals.hasErrorOutput == true {
            scores[.debugging, default: 0] += 1.5
            contributing.append("error_output")
        }
        if signals.hasCodeExecution == true {
            scores[.backend, default: 0] += 0.5
            scores[.logic, default: 0] += 0.5
            contributing.append("code_execution")
        }
        if signals.hasSearchResults == true {
            scores[.research, default: 0] += 1.0
            contributing.append("search_results")
        }
        if signals.hasMultiStepPlanning == true {
            scores[.orchestration, default: 0] += 1.0
            contributing.append("multi_step_planning")
        }

        if let model = signals.model {
            let modelLower = model.lowercased()
            for entry in modelBias {
                if modelLower.contains(entry.substring) {
                    for (cat, weight) in entry.bias {
                        scores[cat, default: 0] += weight
                    }
                    contributing.append("model:\(entry.substring)")
                    break
                }
            }
        }

        if let surface = signals.appSurface?.lowercased(),
           let bias = surfaceBias[surface] {
            for (cat, weight) in bias {
                scores[cat, default: 0] += weight
            }
            contributing.append("surface:\(surface)")
        }

        var winner: ModelPurposeCategory = .other
        var maxScore = 0.0
        var total = 0.0
        for cat in ModelPurposeCategory.allCases {
            let s = scores[cat, default: 0]
            total += s
            if s > maxScore {
                maxScore = s
                winner = cat
            }
        }

        if total == 0 {
            return ClassificationResult(category: .other, confidence: 0, contributingSignals: [])
        }

        let confidence = (maxScore / total * 100).rounded() / 100
        return ClassificationResult(category: winner, confidence: confidence, contributingSignals: contributing)
    }
}