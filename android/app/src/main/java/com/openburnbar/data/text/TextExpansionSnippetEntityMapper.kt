package com.openburnbar.data.text

import com.openburnbar.data.db.TextExpansionSnippetEntity

fun TextExpansionSnippetEntity.toTextExpansionSnippet(): TextExpansionSnippet = TextExpansionSnippet(
    id = id,
    title = title,
    trigger = trigger,
    body = body,
    mode = TextExpansionMode.fromWireName(mode),
    isEnabled = isEnabled,
    scope = TextExpansionScope.fromJson(scopeJson),
    deletedAtMillis = deletedAtMillis,
)
