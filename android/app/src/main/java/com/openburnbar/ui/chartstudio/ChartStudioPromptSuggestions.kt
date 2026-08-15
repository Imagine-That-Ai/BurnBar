package com.openburnbar.ui.chartstudio

import com.openburnbar.data.derived.TrendDataDigest

/**
 * Suggested Chart Studio carousel prompts for a digest. Extracted from the
 * Compose remember lambda so JVM tests cover the digest→prompt mapping
 * without composing the scroll body.
 */
internal fun chartStudioSuggestedPrompts(digest: TrendDataDigest): List<String> {
    return ChartStudioPromptEngine.suggestedPrompts(digest)
}
