package com.openburnbar.data.insights.services

// Evidence and context-budget shaping.
internal const val INSIGHT_EVIDENCE_ROWS_PER_SOURCE = 8
internal const val INSIGHT_BENCHMARK_EVIDENCE_LIMIT = 12
internal const val INSIGHT_PROVIDER_TRIM_THRESHOLD = 12
internal const val INSIGHT_MODEL_TRIM_THRESHOLD = 16
internal const val INSIGHT_DAILY_TRIM_THRESHOLD = 90

// Result-shaping caps shared by the gateways and the rule-based engine.
internal const val INSIGHT_MAX_CITATIONS = 3
internal const val INSIGHT_MAX_FINDINGS = 6
internal const val INSIGHT_MAX_MISSION_CANDIDATES = 5
internal const val INSIGHT_MAX_GROUNDED_POINTS = 4
internal const val INSIGHT_GROUNDED_FINDING_LIMIT = 3
internal const val INSIGHT_RANKING_ROW_LIMIT = 5
internal const val INSIGHT_DEFAULT_RANKING_LIMIT = 8

// Benchmark-advice tuning.
internal const val INSIGHT_MAX_BENCHMARK_RECOMMENDATIONS = 3
internal const val INSIGHT_BENCHMARK_RANKING_ROW_LIMIT = 6
internal const val INSIGHT_BENCHMARK_COST_MARGIN = 0.12
internal const val INSIGHT_BENCHMARK_SCORE_TOLERANCE = 0.08
internal const val INSIGHT_DEFAULT_BENCHMARK_CONFIDENCE = 0.6
internal const val INSIGHT_HIGH_CONFIDENCE_FLOOR = 0.75
internal const val INSIGHT_LOW_CONFIDENCE_CEILING = 0.45

// Mission-intelligence thresholds.
internal const val INSIGHT_QUOTA_HOT_UTILIZATION = 0.8
internal const val INSIGHT_DOMINANT_MODEL_COST_SHARE = 0.35

// Local (Ollama) gateway HTTP tuning.
internal const val INSIGHT_CONNECT_TIMEOUT_SECONDS = 10
internal const val INSIGHT_READ_TIMEOUT_SECONDS = 180
internal const val INSIGHT_LOCAL_MODEL_TEMPERATURE = 0.2

/** Length of the `YYYY-MM-DD` prefix of an ISO-8601 day key. */
internal const val INSIGHT_ISO_DATE_LENGTH = 10
