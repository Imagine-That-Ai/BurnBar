import Foundation
import OpenBurnBarCore
import OpenBurnBarFirestoreModels

/// Swift port of `functions/src/community/classifier.ts` — metadata-only purpose labels.
/// `MODEL_BIAS` is an **ordered** list; iterate in array order and break at the first substring match.
enum ModelPurposeClassifier {
    struct Signals: Sendable {
        var fileExtensions: [String] = []
        /// Session title/summary keywords (TS: `keywords`).
        var keywords: [String] = []
        var model: String?
        var appSurface: String?
        var hasErrorOutput: Bool = false
        var hasCodeExecution: Bool = false
        var hasSearchResults: Bool = false
        var hasMultiStepPlanning: Bool = false
    }

    struct Result: Sendable {
        var category: FirestoreModelPurposeCategory
        var confidence: Double
    }

    private static let fileExtensionMap: [String: FirestoreModelPurposeCategory] = [
        "swift": .ui, "xaml": .ui, "css": .ui, "scss": .ui, "html": .ui, "vue": .ui, "svelte": .ui,
        "go": .backend, "rs": .backend, "py": .backend, "java": .backend, "kt": .backend,
        "sql": .backend, "proto": .backend, "grpc": .backend,
        "ts": .logic, "tsx": .logic, "js": .logic, "mjs": .logic, "cjs": .logic, "dart": .logic,
        "md": .writing, "txt": .writing, "rst": .writing, "docx": .writing, "pdf": .writing,
        "json": .research, "yaml": .research, "yml": .research, "csv": .research, "toml": .research
    ]

    private static let keywordMap: [String: FirestoreModelPurposeCategory] = [
        "ui": .ui, "design": .ui, "frontend": .ui, "layout": .ui, "view": .ui, "button": .ui,
        "animation": .ui, "theme": .ui, "color": .ui, "responsive": .ui, "accessibility": .ui,
        "api": .backend, "server": .backend, "database": .backend, "migration": .backend,
        "endpoint": .backend, "auth": .backend, "deploy": .backend, "docker": .backend,
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
        "mission": .orchestration
    ]

    /// ORDERED — first substring match wins (golden: `o1-deepseek-hybrid` → `o1` → research).
    private static let modelBias: [(substring: String, bias: [FirestoreModelPurposeCategory: Double])] = [
        ("o1", [.research: 0.3, .logic: 0.2]),
        ("o3", [.research: 0.3, .logic: 0.2]),
        ("deepseek", [.logic: 0.3, .backend: 0.2]),
        ("claude-3.5-sonnet", [.writing: 0.15, .logic: 0.15]),
        ("gpt-4o", [.ui: 0.1, .writing: 0.1]),
        ("llama", [.backend: 0.15])
    ]

    private static let surfaceBias: [String: [FirestoreModelPurposeCategory: Double]] = [
        "chat": [:],
        "dashboard": [.orchestration: 0.1],
        "editor": [.logic: 0.1],
        "terminal": [.debugging: 0.15, .backend: 0.1]
    ]

    static func classify(_ signals: Signals) -> Result {
        var scores = Dictionary(
            uniqueKeysWithValues: FirestoreModelPurposeCategory.allCases.map { ($0, 0.0) }
        )

        if !signals.fileExtensions.isEmpty {
            for ext in signals.fileExtensions {
                let key = ext.lowercased()
                if let cat = fileExtensionMap[key] {
                    scores[cat, default: 0] += 1.0
                }
            }
        }

        if !signals.keywords.isEmpty {
            for kw in signals.keywords {
                let key = kw.lowercased()
                if let cat = keywordMap[key] {
                    scores[cat, default: 0] += 0.5
                }
            }
        }

        if signals.hasErrorOutput {
            scores[.debugging, default: 0] += 1.5
        }
        if signals.hasCodeExecution {
            scores[.backend, default: 0] += 0.5
            scores[.logic, default: 0] += 0.5
        }
        if signals.hasSearchResults {
            scores[.research, default: 0] += 1.0
        }
        if signals.hasMultiStepPlanning {
            scores[.orchestration, default: 0] += 1.0
        }

        if let model = signals.model {
            let modelLower = model.lowercased()
            for entry in modelBias where modelLower.contains(entry.substring) {
                for (cat, weight) in entry.bias {
                    scores[cat, default: 0] += weight
                }
                break
            }
        }

        if let surface = signals.appSurface?.lowercased(),
           let bias = surfaceBias[surface] {
            for (cat, weight) in bias {
                scores[cat, default: 0] += weight
            }
        }

        var winner: FirestoreModelPurposeCategory = .other
        var maxScore = 0.0
        var totalScore = 0.0
        for cat in FirestoreModelPurposeCategory.allCases {
            totalScore += scores[cat, default: 0]
            if scores[cat, default: 0] > maxScore {
                maxScore = scores[cat, default: 0]
                winner = cat
            }
        }

        if totalScore == 0 {
            return Result(category: .other, confidence: 0)
        }

        let confidence = (maxScore / totalScore * 100).rounded() / 100
        return Result(category: winner, confidence: confidence)
    }

    /// Golden fixture: `o1-deepseek-hybrid` must classify as research (o1 before deepseek).
    static func classifyModelBiasTieOrder() -> Result {
        classify(Signals(model: "o1-deepseek-hybrid"))
    }

    /// Merge snapshot purpose mix with live rollup model keys for display.
    static func displayPurposeMix(
        snapshot: FirestoreCommunityShareSnapshotDoc?,
        modelSummaries: [RollupModelSummary]
    ) -> [(label: String, share: Double)] {
        if let snapshot, !snapshot.purposeMix.isEmpty {
            return snapshot.purposeMix
                .sorted { $0.value > $1.value }
                .prefix(8)
                .map { (label: $0.key, share: $0.value) }
        }
        guard !modelSummaries.isEmpty else { return [] }
        let total = Double(modelSummaries.reduce(0) { $0 + $1.tokens })
        guard total > 0 else { return [] }
        return modelSummaries.prefix(6).map { summary in
            let signals = Signals(keywords: [summary.model], model: summary.model)
            let cat = classify(signals).category
            return (label: cat.rawValue, share: Double(summary.tokens) / total)
        }
    }
}
