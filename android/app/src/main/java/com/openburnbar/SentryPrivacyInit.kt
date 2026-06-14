package com.openburnbar

import android.content.Context
import io.sentry.Breadcrumb
import io.sentry.SentryEvent
import io.sentry.android.core.SentryAndroid

/**
 * T-AND-06 — installs the [SentryPrivacyScrubber] as Sentry's `beforeSend` + `beforeBreadcrumb`
 * hooks so no crash/ANR payload or breadcrumb can ship prompt/credential fragments off device.
 *
 * Sentry is otherwise auto-initialized from the manifest (DSN, environment, ANR, trace sample).
 * `SentryAndroid.init(context) { options -> ... }` reads that same manifest configuration first
 * and then applies this block, so wiring the scrubbers here adds the redaction WITHOUT replacing
 * any of the existing manifest-driven setup. Called once from [BurnBarApplication.onCreate].
 */
object SentryPrivacyInit {
    fun install(context: Context) {
        SentryAndroid.init(context) { options ->
            options.beforeSend =
                io.sentry.SentryOptions.BeforeSendCallback { event, _ ->
                    scrubEvent(event)
                    event
                }
            options.beforeBreadcrumb =
                io.sentry.SentryOptions.BeforeBreadcrumbCallback { breadcrumb, _ ->
                    scrubBreadcrumb(breadcrumb)
                    breadcrumb
                }
        }
    }

    /** Visible for tests: redact an event's message, breadcrumbs, and extras in place. */
    internal fun scrubEvent(event: SentryEvent) {
        event.message?.let { message ->
            message.formatted = SentryPrivacyScrubber.scrubMessage(message.formatted)
            message.message = SentryPrivacyScrubber.scrubMessage(message.message)
        }
        event.breadcrumbs?.forEach { scrubBreadcrumb(it) }
        event.extras?.let { extras ->
            event.setExtras(SentryPrivacyScrubber.scrubDataMap(extras))
        }
    }

    /** Visible for tests: redact a breadcrumb's message + data in place. */
    internal fun scrubBreadcrumb(breadcrumb: Breadcrumb) {
        breadcrumb.message = SentryPrivacyScrubber.scrubMessage(breadcrumb.message)
        val data = breadcrumb.data
        if (data.isNotEmpty()) {
            val scrubbed = SentryPrivacyScrubber.scrubDataMap(data)
            for ((key, value) in scrubbed) {
                breadcrumb.setData(key, value ?: SentryPrivacyScrubber.REDACTED)
            }
        }
    }
}
