package com.openburnbar.ui.control

import com.openburnbar.data.domains.DataDomain
import com.openburnbar.data.domains.DataDomains
import java.util.Locale

/** Member data tier resolved by `getDataDomainUsage` (entitlement-derived). */
enum class DataTier(val raw: String, val label: String) {
    ULTRA("ultra", "Ultra"),
    PRO("pro", "Cloud Pro"),
    FREE("free", "Free"),
    ;

    companion object {
        fun from(raw: String?): DataTier = entries.firstOrNull { it.raw == raw } ?: FREE
    }
}

/** Tiered Pensieve caps (`limits.pensieve`) from the usage callable. */
data class PensieveLimits(
    val sources: Long,
    val chunks: Long,
    val bytes: Long,
)

/** Per-domain footprint snapshot ({ id, count, bytes }) from the usage callable. */
data class DomainUsage(
    val id: String,
    val count: Long,
    val bytes: Long,
)

/**
 * A domain joined with its server-reported footprint. `domain` is the canonical
 * registry entry (titles, tier, server-sees/device-only facets, actions); usage
 * is the live count/bytes (null until the snapshot loads).
 */
data class DomainRow(
    val domain: DataDomain,
    val usage: DomainUsage?,
) {
    val count: Long get() = usage?.count ?: 0L
    val bytes: Long get() = usage?.bytes ?: 0L
}

/** One registered recovery method from `listRecovery`. */
data class RecoveryMethod(
    val recoveryId: String,
    val kind: String,
    val createdAt: Long?,
    val confirmed: Boolean,
) {
    val kindLabel: String
        get() =
            when (kind) {
                "recovery_key" -> "Recovery key"
                "recovery_contact" -> "Recovery contact"
                else -> kind.replace("_", " ").replaceFirstChar { it.uppercase() }
            }
}

/** One tamper-evident audit event from `getAuditLog` (hash-chain link). */
data class AuditEvent(
    val seq: Long,
    val ts: Long?,
    val actor: String,
    val action: String,
    val domain: String?,
    val prevHash: String?,
    val hash: String?,
) {
    /** Registry title for this event's domain, or the raw id, or "—". */
    val domainTitle: String
        get() = domain?.let { DataDomains.domain(it)?.title ?: it } ?: "—"
}

/** Result of `verifyAuditLog` — chain integrity. */
data class AuditVerification(
    val valid: Boolean,
    val brokenAt: Long?,
)

/** Aggregate snapshot from `getDataDomainUsage`. */
data class ControlCenterSnapshot(
    val tier: DataTier,
    val pensieveLimits: PensieveLimits?,
    val rows: List<DomainRow>,
) {
    companion object {
        /** Empty snapshot: registry rows with no usage yet, free tier. */
        val empty =
            ControlCenterSnapshot(
                tier = DataTier.FREE,
                pensieveLimits = null,
                rows = DataDomains.all.map { DomainRow(domain = it, usage = null) },
            )
    }
}

/** Which yours<->server facet face the basin card is currently showing. */
enum class BasinFace { YOURS, SERVER }

private const val BYTES_PER_UNIT = 1024.0
private const val THOUSAND = 1_000L
private const val THOUSAND_D = 1_000.0
private const val MILLION = 1_000_000L
private const val MILLION_D = 1_000_000.0

/** Human-readable byte formatter shared across the control surface. */
internal fun formatBytes(bytes: Long): String {
    if (bytes <= 0L) return "0 B"
    val units = listOf("B", "KB", "MB", "GB", "TB")
    var value = bytes.toDouble()
    var unit = 0
    while (value >= BYTES_PER_UNIT && unit < units.lastIndex) {
        value /= BYTES_PER_UNIT
        unit += 1
    }
    return if (unit == 0) {
        "$bytes B"
    } else {
        String.format(Locale.US, "%.1f %s", value, units[unit])
    }
}

/** Compact count formatter (1.2k, 3.4M). */
internal fun formatCount(count: Long): String =
    when {
        count < THOUSAND -> count.toString()
        count < MILLION -> String.format(Locale.US, "%.1fk", count / THOUSAND_D)
        else -> String.format(Locale.US, "%.1fM", count / MILLION_D)
    }
