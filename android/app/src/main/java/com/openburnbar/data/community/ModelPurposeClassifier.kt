package com.openburnbar.data.community

import kotlin.math.round

/** Canonical purpose categories — must match `functions/src/community/classifier.ts`. */
enum class ModelPurposeCategory {
    UI,
    BACKEND,
    LOGIC,
    WRITING,
    RESEARCH,
    DEBUGGING,
    ORCHESTRATION,
    OTHER,
    ;

    fun wireName(): String =
        when (this) {
            UI -> "ui"
            BACKEND -> "backend"
            LOGIC -> "logic"
            WRITING -> "writing"
            RESEARCH -> "research"
            DEBUGGING -> "debugging"
            ORCHESTRATION -> "orchestration"
            OTHER -> "other"
        }

    companion object {
        val all: List<ModelPurposeCategory> = entries

        fun fromWire(name: String): ModelPurposeCategory? =
            when (name.lowercase()) {
                "ui" -> UI
                "backend" -> BACKEND
                "logic" -> LOGIC
                "writing" -> WRITING
                "research" -> RESEARCH
                "debugging" -> DEBUGGING
                "orchestration" -> ORCHESTRATION
                "other" -> OTHER
                else -> null
            }
    }
}

data class ClassifierSignals(
    val fileExtensions: List<String> = emptyList(),
    val model: String? = null,
    val appSurface: String? = null,
    val hasCodeExecution: Boolean = false,
    val hasErrorOutput: Boolean = false,
    val hasSearchResults: Boolean = false,
    val hasMultiStepPlanning: Boolean = false,
    val keywords: List<String> = emptyList(),
)

data class PurposeCorrection(
    val fingerprint: String,
    val correctedTo: ModelPurposeCategory,
)

data class ClassificationResult(
    val category: ModelPurposeCategory,
    val confidence: Double,
    val contributingSignals: List<String>,
)

private val FILE_EXTENSION_MAP: Map<String, ModelPurposeCategory> =
    mapOf(
        "swift" to ModelPurposeCategory.UI,
        "xaml" to ModelPurposeCategory.UI,
        "css" to ModelPurposeCategory.UI,
        "scss" to ModelPurposeCategory.UI,
        "html" to ModelPurposeCategory.UI,
        "vue" to ModelPurposeCategory.UI,
        "svelte" to ModelPurposeCategory.UI,
        "go" to ModelPurposeCategory.BACKEND,
        "rs" to ModelPurposeCategory.BACKEND,
        "py" to ModelPurposeCategory.BACKEND,
        "java" to ModelPurposeCategory.BACKEND,
        "kt" to ModelPurposeCategory.BACKEND,
        "sql" to ModelPurposeCategory.BACKEND,
        "proto" to ModelPurposeCategory.BACKEND,
        "grpc" to ModelPurposeCategory.BACKEND,
        "ts" to ModelPurposeCategory.LOGIC,
        "tsx" to ModelPurposeCategory.LOGIC,
        "js" to ModelPurposeCategory.LOGIC,
        "mjs" to ModelPurposeCategory.LOGIC,
        "cjs" to ModelPurposeCategory.LOGIC,
        "dart" to ModelPurposeCategory.LOGIC,
        "md" to ModelPurposeCategory.WRITING,
        "txt" to ModelPurposeCategory.WRITING,
        "rst" to ModelPurposeCategory.WRITING,
        "docx" to ModelPurposeCategory.WRITING,
        "pdf" to ModelPurposeCategory.WRITING,
        "json" to ModelPurposeCategory.RESEARCH,
        "yaml" to ModelPurposeCategory.RESEARCH,
        "yml" to ModelPurposeCategory.RESEARCH,
        "csv" to ModelPurposeCategory.RESEARCH,
        "toml" to ModelPurposeCategory.RESEARCH,
    )

private val KEYWORD_MAP: Map<String, ModelPurposeCategory> =
    mapOf(
        "ui" to ModelPurposeCategory.UI,
        "design" to ModelPurposeCategory.UI,
        "frontend" to ModelPurposeCategory.UI,
        "layout" to ModelPurposeCategory.UI,
        "view" to ModelPurposeCategory.UI,
        "button" to ModelPurposeCategory.UI,
        "animation" to ModelPurposeCategory.UI,
        "theme" to ModelPurposeCategory.UI,
        "color" to ModelPurposeCategory.UI,
        "responsive" to ModelPurposeCategory.UI,
        "accessibility" to ModelPurposeCategory.UI,
        "api" to ModelPurposeCategory.BACKEND,
        "server" to ModelPurposeCategory.BACKEND,
        "database" to ModelPurposeCategory.BACKEND,
        "migration" to ModelPurposeCategory.BACKEND,
        "endpoint" to ModelPurposeCategory.BACKEND,
        "auth" to ModelPurposeCategory.BACKEND,
        "deploy" to ModelPurposeCategory.ORCHESTRATION,
        "docker" to ModelPurposeCategory.BACKEND,
        "kubernetes" to ModelPurposeCategory.BACKEND,
        "grpc" to ModelPurposeCategory.BACKEND,
        "refactor" to ModelPurposeCategory.LOGIC,
        "algorithm" to ModelPurposeCategory.LOGIC,
        "function" to ModelPurposeCategory.LOGIC,
        "type" to ModelPurposeCategory.LOGIC,
        "interface" to ModelPurposeCategory.LOGIC,
        "state" to ModelPurposeCategory.LOGIC,
        "model" to ModelPurposeCategory.LOGIC,
        "parse" to ModelPurposeCategory.LOGIC,
        "docs" to ModelPurposeCategory.WRITING,
        "documentation" to ModelPurposeCategory.WRITING,
        "readme" to ModelPurposeCategory.WRITING,
        "blog" to ModelPurposeCategory.WRITING,
        "article" to ModelPurposeCategory.WRITING,
        "essay" to ModelPurposeCategory.WRITING,
        "summary" to ModelPurposeCategory.WRITING,
        "research" to ModelPurposeCategory.RESEARCH,
        "search" to ModelPurposeCategory.RESEARCH,
        "analyze" to ModelPurposeCategory.RESEARCH,
        "data" to ModelPurposeCategory.RESEARCH,
        "benchmark" to ModelPurposeCategory.RESEARCH,
        "evaluate" to ModelPurposeCategory.RESEARCH,
        "bug" to ModelPurposeCategory.DEBUGGING,
        "error" to ModelPurposeCategory.DEBUGGING,
        "fix" to ModelPurposeCategory.DEBUGGING,
        "crash" to ModelPurposeCategory.DEBUGGING,
        "stacktrace" to ModelPurposeCategory.DEBUGGING,
        "debug" to ModelPurposeCategory.DEBUGGING,
        "test" to ModelPurposeCategory.DEBUGGING,
        "fail" to ModelPurposeCategory.DEBUGGING,
        "plan" to ModelPurposeCategory.ORCHESTRATION,
        "workflow" to ModelPurposeCategory.ORCHESTRATION,
        "pipeline" to ModelPurposeCategory.ORCHESTRATION,
        "agent" to ModelPurposeCategory.ORCHESTRATION,
        "automate" to ModelPurposeCategory.ORCHESTRATION,
        "schedule" to ModelPurposeCategory.ORCHESTRATION,
        "mission" to ModelPurposeCategory.ORCHESTRATION,
    )

/**
 * Order-sensitive: iterate in TS definition order; first substring match wins.
 */
private val MODEL_BIAS: List<Pair<String, Map<ModelPurposeCategory, Double>>> =
    listOf(
        "o1" to mapOf(ModelPurposeCategory.RESEARCH to 0.3, ModelPurposeCategory.LOGIC to 0.2),
        "o3" to mapOf(ModelPurposeCategory.RESEARCH to 0.3, ModelPurposeCategory.LOGIC to 0.2),
        "deepseek" to mapOf(ModelPurposeCategory.LOGIC to 0.3, ModelPurposeCategory.BACKEND to 0.2),
        "claude-3.5-sonnet" to mapOf(ModelPurposeCategory.WRITING to 0.15, ModelPurposeCategory.LOGIC to 0.15),
        "gpt-4o" to mapOf(ModelPurposeCategory.UI to 0.1, ModelPurposeCategory.WRITING to 0.1),
        "llama" to mapOf(ModelPurposeCategory.BACKEND to 0.15),
    )

private val SURFACE_BIAS: Map<String, Map<ModelPurposeCategory, Double>> =
    mapOf(
        "chat" to emptyMap(),
        "dashboard" to mapOf(ModelPurposeCategory.ORCHESTRATION to 0.1),
        "editor" to mapOf(ModelPurposeCategory.LOGIC to 0.1),
        "terminal" to mapOf(ModelPurposeCategory.DEBUGGING to 0.15, ModelPurposeCategory.BACKEND to 0.1),
    )

fun signalFingerprint(signals: ClassifierSignals): String {
    val parts = mutableListOf<String>()
    if (signals.fileExtensions.isNotEmpty()) {
        parts.add("ext:${signals.fileExtensions.map { it.lowercase() }.sorted().joinToString(",")}")
    }
    signals.appSurface?.let { parts.add("surf:$it") }
    if (signals.hasCodeExecution) parts.add("exec")
    if (signals.hasErrorOutput) parts.add("err")
    if (signals.hasSearchResults) parts.add("search")
    if (signals.hasMultiStepPlanning) parts.add("plan")
    return parts.joinToString("|").ifEmpty { "default" }
}

fun classifyPurpose(
    signals: ClassifierSignals,
    corrections: List<PurposeCorrection> = emptyList(),
): ClassificationResult {
    val fp = signalFingerprint(signals)
    val matched = corrections.firstOrNull { it.fingerprint == fp }
    if (matched != null) {
        return ClassificationResult(
            category = matched.correctedTo,
            confidence = 1.0,
            contributingSignals = listOf("user_correction"),
        )
    }

    val scores = ModelPurposeCategory.all.associateWith { 0.0 }.toMutableMap()
    val contributingSignals = mutableListOf<String>()

    for (ext in signals.fileExtensions) {
        val cat = FILE_EXTENSION_MAP[ext.lowercase()]
        if (cat != null) {
            scores[cat] = scores.getValue(cat) + 1.0
            contributingSignals.add("file:$ext")
        }
    }

    for (kw in signals.keywords) {
        val cat = KEYWORD_MAP[kw.lowercase()]
        if (cat != null) {
            scores[cat] = scores.getValue(cat) + 0.5
            contributingSignals.add("keyword:$kw")
        }
    }

    if (signals.hasErrorOutput) {
        scores[ModelPurposeCategory.DEBUGGING] = scores.getValue(ModelPurposeCategory.DEBUGGING) + 1.5
        contributingSignals.add("error_output")
    }
    if (signals.hasCodeExecution) {
        scores[ModelPurposeCategory.BACKEND] = scores.getValue(ModelPurposeCategory.BACKEND) + 0.5
        scores[ModelPurposeCategory.LOGIC] = scores.getValue(ModelPurposeCategory.LOGIC) + 0.5
        contributingSignals.add("code_execution")
    }
    if (signals.hasSearchResults) {
        scores[ModelPurposeCategory.RESEARCH] = scores.getValue(ModelPurposeCategory.RESEARCH) + 1.0
        contributingSignals.add("search_results")
    }
    if (signals.hasMultiStepPlanning) {
        scores[ModelPurposeCategory.ORCHESTRATION] = scores.getValue(ModelPurposeCategory.ORCHESTRATION) + 1.0
        contributingSignals.add("multi_step_planning")
    }

    signals.model?.let { model ->
        val modelLower = model.lowercase()
        for ((key, bias) in MODEL_BIAS) {
            if (modelLower.contains(key)) {
                for ((cat, weight) in bias) {
                    scores[cat] = scores.getValue(cat) + weight
                }
                contributingSignals.add("model:$key")
                break
            }
        }
    }

    signals.appSurface?.let { surface ->
        val surfaceBias = SURFACE_BIAS[surface.lowercase()]
        if (surfaceBias != null) {
            for ((cat, weight) in surfaceBias) {
                scores[cat] = scores.getValue(cat) + weight
            }
            contributingSignals.add("surface:$surface")
        }
    }

    var winner = ModelPurposeCategory.OTHER
    var maxScore = 0.0
    var totalScore = 0.0
    for (cat in ModelPurposeCategory.all) {
        val s = scores.getValue(cat)
        totalScore += s
        if (s > maxScore) {
            maxScore = s
            winner = cat
        }
    }

    if (totalScore == 0.0) {
        return ClassificationResult(
            category = ModelPurposeCategory.OTHER,
            confidence = 0.0,
            contributingSignals = emptyList(),
        )
    }

    val confidence = round((maxScore / totalScore) * 100.0) / 100.0
    return ClassificationResult(
        category = winner,
        confidence = confidence,
        contributingSignals = contributingSignals,
    )
}