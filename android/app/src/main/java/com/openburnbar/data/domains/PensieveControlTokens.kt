@file:Suppress("MagicNumber")
// Compose layout literals (alpha); token-per-line extraction obscures structure.

package com.openburnbar.data.domains

import androidx.compose.ui.graphics.Color
import com.openburnbar.ui.tokens.PensieveTokens

/**
 * Compose-typed bridge over the generated Pensieve design tokens
 * ([PensieveTokens], which expose CSS-style hex/rgba strings). The Data &
 * Privacy Control Center binds its tier colors, brass keys/CTA, mercury basin
 * substance, and frost (sealed) accents to these so the surface never hardcodes
 * palette values — they track `packages/design-tokens/dist/compose/PensieveTokens.kt`.
 *
 * Only the obsidian-ink + mercury-silver + brass scheme is surfaced (per the
 * control-surface design constraint); wax-crimson is reserved for destructive
 * actions only.
 */
object PensieveControlTokens {
    // ── Ink (obsidian) ──
    val inkVoid = hex(PensieveTokens.colorInkVoid)
    val inkBase = hex(PensieveTokens.colorInkBase)
    val inkElevated = hex(PensieveTokens.colorInkElevated)
    val inkFurnace = hex(PensieveTokens.colorInkFurnace)

    // ── Mercury-silver (basin substance) ──
    val mercuryBright = hex(PensieveTokens.colorMercuryBright)
    val mercuryCore = hex(PensieveTokens.colorMercuryCore)
    val mercuryDeep = hex(PensieveTokens.colorMercuryDeep)
    val mercuryWash = rgba(PensieveTokens.colorMercuryWash)

    // ── Brass / amber (keys / CTA) ──
    val brassCore = hex(PensieveTokens.colorBrassCore)
    val brassBright = hex(PensieveTokens.colorBrassBright)
    val brassDeep = hex(PensieveTokens.colorBrassDeep)
    val brassGlow = rgba(PensieveTokens.colorBrassGlow)

    // ── Frost (sealed) ──
    val frostVeil = rgba(PensieveTokens.colorFrostVeil)
    val frostLine = rgba(PensieveTokens.colorFrostLine)

    // ── Wax-crimson — DESTRUCTIVE ONLY ──
    val sealCrimson = hex(PensieveTokens.colorSealCrimson)

    // ── Glass ──
    val glassBg = rgba(PensieveTokens.colorGlassBg)
    val glassBgElevated = rgba(PensieveTokens.colorGlassBgElevated)
    val glassLine = rgba(PensieveTokens.colorGlassLine)
    val glassLineBright = rgba(PensieveTokens.colorGlassLineBright)

    // ── Text ──
    val textBright = hex(PensieveTokens.colorTextBright)
    val textBase = rgba(PensieveTokens.colorTextBase)
    val textMute = rgba(PensieveTokens.colorTextMute)
    val textDim = rgba(PensieveTokens.colorTextDim)

    // ── Encryption-tier accents ──
    val tierServerReadable = hex(PensieveTokens.colorTierServerReadable)
    val tierZeroAccess = hex(PensieveTokens.colorTierZeroAccess)
    val tierEndToEnd = hex(PensieveTokens.colorTierEndToEnd)

    /** Tier accent color for a given [EncryptionTier]. */
    fun tierColor(tier: EncryptionTier): Color =
        when (tier) {
            EncryptionTier.SERVER_READABLE -> tierServerReadable
            EncryptionTier.ZERO_ACCESS -> tierZeroAccess
            EncryptionTier.END_TO_END -> tierEndToEnd
        }

    /** Human-facing label for a tier (sentence-case, benefit-first). */
    fun tierLabel(tier: EncryptionTier): String =
        when (tier) {
            EncryptionTier.SERVER_READABLE -> "Server-readable"
            EncryptionTier.ZERO_ACCESS -> "Zero-access"
            EncryptionTier.END_TO_END -> "End-to-end sealed"
        }

    /** One-line plain-language promise per tier (no jargon). */
    fun tierPromise(tier: EncryptionTier): String =
        when (tier) {
            EncryptionTier.SERVER_READABLE ->
                "Stored as plain data so the cockpit can show it. BurnBar's servers can read this."
            EncryptionTier.ZERO_ACCESS ->
                "Encrypted at rest. BurnBar holds only the wrapped key under your device's trust."
            EncryptionTier.END_TO_END ->
                "Sealed on your device with your vault key. BurnBar never sees the contents or the key."
        }

    // ── Parsers ──
    // Accepts "#rrggbb" / "#aarrggbb" hex and "rgba(r, g, b, a)" strings exactly
    // as emitted by Style Dictionary into the generated token file.
    private fun hex(value: String): Color {
        val raw = value.removePrefix("#")
        return when (raw.length) {
            6 -> Color(("FF$raw").toLong(16))
            8 -> Color(raw.toLong(16)) // already AARRGGBB
            else -> Color.Unspecified
        }
    }

    private fun rgba(value: String): Color {
        val inner = value.substringAfter("(", "").substringBefore(")", "")
        if (inner.isBlank()) return Color.Unspecified
        val parts = inner.split(",").map { it.trim() }
        if (parts.size < 3) return Color.Unspecified
        val r = parts[0].toIntOrNull() ?: return Color.Unspecified
        val g = parts[1].toIntOrNull() ?: return Color.Unspecified
        val b = parts[2].toIntOrNull() ?: return Color.Unspecified
        val a = parts.getOrNull(3)?.toFloatOrNull() ?: 1f
        return Color(red = r / 255f, green = g / 255f, blue = b / 255f, alpha = a)
    }
}
