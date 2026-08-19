package com.openburnbar.analytics

import java.io.File
import org.junit.Assert.assertEquals
import org.junit.Assert.assertNotNull
import org.junit.Assert.assertTrue
import org.junit.Test

/**
 * Governance: enforces the taxonomy's structural invariants on the Android
 * registry so an off-scheme name or property can't ship. Mirrors the casing /
 * scheme gates the taxonomy doc requires of every platform.
 */
class AnalyticsTaxonomyTest {

    private val eventNameRegex = Regex("^[a-z0-9]+(\\.[a-z0-9_]+)+$")

    @Test
    fun everyEventNameMatchesTheTaxonomyScheme() {
        for (event in AnalyticsEvent.entries) {
            assertTrue(
                "event '${event.wire}' must match surface.object.action (lowercase, dot-namespaced)",
                eventNameRegex.matches(event.wire),
            )
        }
    }

    /**
     * The taxonomy is the source of truth. Read the canonical doc, extract the
     * set of registered event wire-names (they appear as inline-code
     * `surface.object.action` tokens in the tables — backtick-wrapped tokens
     * containing a dot), and assert EVERY name in the Android registry is a
     * member of that set. An off-taxonomy name (e.g. the old
     * `search.query.performed`) makes this fail. This is the per-platform
     * "no instrumentation references a name not in the doc" governance gate.
     */
    @Test
    fun everyRegisteredEventIsPresentInTheCanonicalTaxonomyDoc() {
        val doc = locateTaxonomyDoc()
        val text = doc.readText()

        // Backtick-wrapped tokens that look like surface.object.action (a
        // lowercase head segment followed by ≥1 dotted snake_case segments).
        val tokenRegex = Regex("`([a-z0-9]+(?:\\.[a-z0-9_]+)+)`")
        val registeredInDoc = tokenRegex.findAll(text)
            .map { it.groupValues[1] }
            .toSet()

        assertTrue(
            "expected to parse a non-trivial number of event names from " +
                "${doc.path}; got ${registeredInDoc.size} — the regex or doc path is wrong",
            registeredInDoc.size >= 50,
        )

        val offTaxonomy = AnalyticsEvent.wireNames.filterNot { registeredInDoc.contains(it) }
        assertTrue(
            "these Android registry wire names are NOT registered in the canonical " +
                "taxonomy (${doc.path}); add them there first or rename to an existing " +
                "event: $offTaxonomy",
            offTaxonomy.isEmpty(),
        )
    }

    /**
     * Walk up from the JVM working directory (and a couple of likely anchors)
     * to find `docs/analytics/event-taxonomy.md`. The harness runs tests from
     * varying cwds; a missing doc is a hard failure, never a silent skip.
     */
    private fun locateTaxonomyDoc(): File {
        val relative = "docs/analytics/event-taxonomy.md"
        val anchors = buildList {
            System.getProperty("taxonomy.doc")?.let { add(File(it)) }
            add(File(System.getProperty("user.dir", ".")))
            // Common module-relative roots if cwd is the module/app dir.
            add(File(System.getProperty("user.dir", "."), "../.."))
            add(File(System.getProperty("user.dir", "."), ".."))
        }
        for (anchor in anchors) {
            if (anchor.isFile && anchor.name == "event-taxonomy.md") return anchor
            var dir: File? = anchor.absoluteFile
            while (dir != null) {
                val candidate = File(dir, relative)
                if (candidate.isFile) return candidate
                dir = dir.parentFile
            }
        }
        throw AssertionError(
            "could not locate $relative by walking up from any of " +
                "${anchors.map { it.absolutePath }}; the governance gate cannot run",
        )
    }

    @Test
    fun tier1SharedNamesAreExactlyTheCrossPlatformSpine() {
        // These names are shared byte-for-byte with macOS and the website.
        val expected = setOf(
            "app.session.started",
            "screen.viewed",
            "nav.route.changed",
            "auth.sign_in.completed",
            "auth.sign_up.completed",
            "auth.signed_out",
            "settings.changed",
            "error.handled",
            "consent.analytics.granted",
            "feature.used",
        )
        val present = AnalyticsEvent.wireNames
        for (name in expected) {
            assertTrue("Tier 1 name '$name' must exist verbatim", present.contains(name))
        }
    }

    @Test
    fun eventNamesAreUnique() {
        val names = AnalyticsEvent.entries.map { it.wire }
        assertEquals("no duplicate wire names", names.size, names.toSet().size)
    }

    @Test
    fun categoriesMapToTheFiveTaxonomyValues() {
        val valid = setOf("lifecycle", "screen_view", "primary_action", "conversion_auth", "error")
        for (event in AnalyticsEvent.entries) {
            assertTrue(
                "category '${event.category.wire}' for ${event.wire} is a valid taxonomy category",
                valid.contains(event.category.wire),
            )
        }
    }

    @Test
    fun sharedSpineCategoriesMatchTheReferenceImplementations() {
        assertEquals(AnalyticsCategory.LIFECYCLE, AnalyticsEvent.APP_SESSION_STARTED.category)
        assertEquals(AnalyticsCategory.SCREEN_VIEW, AnalyticsEvent.SCREEN_VIEWED.category)
        assertEquals(AnalyticsCategory.SCREEN_VIEW, AnalyticsEvent.NAV_ROUTE_CHANGED.category)
        assertEquals(AnalyticsCategory.CONVERSION_AUTH, AnalyticsEvent.AUTH_SIGN_IN_COMPLETED.category)
        assertEquals(AnalyticsCategory.LIFECYCLE, AnalyticsEvent.AUTH_SIGNED_OUT.category)
        assertEquals(AnalyticsCategory.PRIMARY_ACTION, AnalyticsEvent.SETTINGS_CHANGED.category)
        assertEquals(AnalyticsCategory.ERROR, AnalyticsEvent.ERROR_HANDLED.category)
        assertEquals(AnalyticsCategory.LIFECYCLE, AnalyticsEvent.CONSENT_ANALYTICS_GRANTED.category)
    }

    // ── surface bounding (anti-fingerprinting) ──

    @Test
    fun unknownRoutesCollapseToOther() {
        assertEquals(AnalyticsSurface.OTHER, AnalyticsSurface.forRoute(null))
        assertEquals(AnalyticsSurface.OTHER, AnalyticsSurface.forRoute(""))
        assertEquals(AnalyticsSurface.OTHER, AnalyticsSurface.forRoute("totally_unknown_route"))
    }

    @Test
    fun parameterizedRoutesNeverLeakArguments() {
        // A route carrying an object slug/thread id must collapse to its bounded
        // surface — the raw slug/id must never become the wire value.
        assertEquals(AnalyticsSurface.INSIGHTS, AnalyticsSurface.forRoute("agent_insights/anthropic"))
        assertEquals(AnalyticsSurface.CHAT, AnalyticsSurface.forRoute("assistants/codex?threadId=abc-123-uuid"))
        assertEquals(AnalyticsSurface.CHAT, AnalyticsSurface.forRoute("agent/aHR0cHM6Ly9leGFtcGxl"))
        // The wire value is always one of the bounded enum labels.
        val bounded = AnalyticsSurface.entries.map { it.wire }.toSet()
        for (route in listOf("agent_insights/x", "assistants/y?threadId=z", "pulse", "weird/123")) {
            assertTrue(bounded.contains(AnalyticsSurface.forRoute(route).wire))
        }
    }

    @Test
    fun knownTabRoutesMapToStableSurfaces() {
        assertEquals(AnalyticsSurface.DASHBOARD_OVERVIEW, AnalyticsSurface.forRoute("pulse"))
        assertEquals(AnalyticsSurface.DASHBOARD_ACTIVITY, AnalyticsSurface.forRoute("burn"))
        assertEquals(AnalyticsSurface.INSIGHTS, AnalyticsSurface.forRoute("insights"))
        assertEquals(AnalyticsSurface.CHAT, AnalyticsSurface.forRoute("hermes"))
        assertEquals(AnalyticsSurface.INBOX, AnalyticsSurface.forRoute("inbox"))
        assertEquals(AnalyticsSurface.FLEET, AnalyticsSurface.forRoute("fleet"))
        assertEquals(AnalyticsSurface.ACCOUNT, AnalyticsSurface.forRoute("you"))
        assertEquals(AnalyticsSurface.SETTINGS, AnalyticsSurface.forRoute("settings"))
    }

    // ── value type enforcement (no raw numerics on the wire) ──

    @Test
    fun analyticsValueOnlyCarriesStringsOrBooleans() {
        // The type has exactly two shapes; a raw number cannot be expressed.
        val s: AnalyticsValue = "21-100".av()
        val b: AnalyticsValue = true.av()
        val stringValue = s as? AnalyticsValue.Str
        val boolValue = b as? AnalyticsValue.Bool
        assertEquals("21-100", stringValue?.value)
        assertEquals(true, boolValue?.value)
        // anyValue yields only String/Boolean — never a Number.
        assertTrue(s.anyValue is String)
        assertTrue(b.anyValue is Boolean)
    }

    @Test
    fun bucketHelpersAreTheOnlyPathFromNumberToValue() {
        // A count must be bucketed to a string label before it can become a value.
        val bucketed: AnalyticsValue = AnalyticsBuckets.count(42).av()
        val bucketedString = bucketed as? AnalyticsValue.Str
        assertEquals("21-100", bucketedString?.value)
        assertNotNull(bucketed.anyValue as? String)
    }
}
