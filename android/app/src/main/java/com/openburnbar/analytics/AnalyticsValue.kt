package com.openburnbar.analytics

/**
 * A property value the wrapper may send. Deliberately limited to strings and
 * booleans — there is **no case for a raw number**, so a bare Int/Double can
 * never reach the wire (anti-fingerprinting). Numerics must pass through
 * [AnalyticsBuckets], which returns an [AnalyticsValue.Str] bucket label.
 *
 * Ported from AgentLens/Services/Analytics/AnalyticsValue.swift. Kotlin has no
 * literal-conformance sugar, so the [str]/[bool] factories and the [String] /
 * [Boolean] extension shims below give call sites the same terseness the Swift
 * `ExpressibleBy*Literal` conformances provide.
 */
sealed interface AnalyticsValue {
    @JvmInline
    value class Str(val value: String) : AnalyticsValue

    @JvmInline
    value class Bool(val value: Boolean) : AnalyticsValue

    /** Native value for the Amplitude SDK's `Map<String, Any?>` payload. */
    val anyValue: Any
        get() = when (this) {
            is Str -> value
            is Bool -> value
        }

    companion object {
        fun str(value: String): AnalyticsValue = Str(value)
        fun bool(value: Boolean): AnalyticsValue = Bool(value)
    }
}

/** Terse builders so call sites read like the Swift dictionary literals. */
fun String.av(): AnalyticsValue = AnalyticsValue.Str(this)
fun Boolean.av(): AnalyticsValue = AnalyticsValue.Bool(this)
