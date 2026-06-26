package com.openburnbar.ui.text

import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.State
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.ui.platform.LocalContext
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.text.TextExpansionMatcher
import com.openburnbar.data.text.TextExpansionSnippet
import com.openburnbar.data.text.TextExpansionSurface
import com.openburnbar.data.text.toTextExpansionSnippet
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.withContext

@Composable
fun rememberTextExpansionSnippets(): State<List<TextExpansionSnippet>> {
    val context = LocalContext.current
    val snippets = remember { mutableStateOf<List<TextExpansionSnippet>>(emptyList()) }
    LaunchedEffect(context) {
        snippets.value =
            withContext(Dispatchers.IO) {
                AppDatabase.getDatabase(context)
                    .textExpansionDao()
                    .getEnabled()
                    .map { it.toTextExpansionSnippet() }
            }
    }
    return snippets
}

fun expandStaticTextSnippetDraft(
    draft: String,
    snippets: List<TextExpansionSnippet>,
    surface: TextExpansionSurface = TextExpansionSurface.IN_APP_THREAD,
): String = TextExpansionMatcher.expandStaticIfAvailable(
    text = draft,
    snippets = snippets,
    surface = surface,
)?.text ?: draft
