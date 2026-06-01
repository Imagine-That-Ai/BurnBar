package com.openburnbar.text

import android.inputmethodservice.InputMethodService
import android.view.View
import android.view.inputmethod.EditorInfo
import android.widget.Button
import android.widget.LinearLayout
import android.widget.TextView
import com.openburnbar.data.db.AppDatabase
import com.openburnbar.data.db.TextExpansionSnippetEntity
import com.openburnbar.data.text.TextExpansionMatcher
import com.openburnbar.data.text.TextExpansionMode
import com.openburnbar.data.text.TextExpansionScope
import com.openburnbar.data.text.TextExpansionSnippet
import com.openburnbar.data.text.TextExpansionSurface
import kotlinx.coroutines.CoroutineScope
import kotlinx.coroutines.Dispatchers
import kotlinx.coroutines.SupervisorJob
import kotlinx.coroutines.cancel
import kotlinx.coroutines.launch
import kotlinx.coroutines.withContext

private object TextExpansionImeConstants {
    const val VIEW_PADDING_HORIZONTAL_DP = 8
    const val VIEW_PADDING_TOP_DP = 6
    const val VIEW_PADDING_BOTTOM_DP = 8
    const val HEADER_TEXT_SIZE_SP = 12f
    const val INPUT_BUFFER_MAX_CHARS = 160
    const val IME_COMMITTED_TEXT_FLAG = 1
}

class TextExpansionImeService : InputMethodService() {
    private val scope = CoroutineScope(SupervisorJob() + Dispatchers.Main)
    private var snippets: List<TextExpansionSnippet> = emptyList()
    private var buffer = StringBuilder()

    override fun onCreateInputView(): View {
        return LinearLayout(this).apply {
            orientation = LinearLayout.VERTICAL
            setPadding(
                TextExpansionImeConstants.VIEW_PADDING_HORIZONTAL_DP,
                TextExpansionImeConstants.VIEW_PADDING_TOP_DP,
                TextExpansionImeConstants.VIEW_PADDING_HORIZONTAL_DP,
                TextExpansionImeConstants.VIEW_PADDING_BOTTOM_DP,
            )
            addView(
                TextView(context).apply {
                    text = "OpenBurnBar && snippets"
                    textSize = TextExpansionImeConstants.HEADER_TEXT_SIZE_SP
                },
            )
            addKeyboardRow("qwertyuiop")
            addKeyboardRow("asdfghjkl")
            addKeyboardRow("zxcvbnm")
            addView(
                LinearLayout(context).apply {
                    orientation = LinearLayout.HORIZONTAL
                    addActionButton("&&") { commitText("&&") }
                    addActionButton("Space") { commitText(" ") }
                    addActionButton("Delete") { deleteBackward() }
                    addActionButton("Return") { commitText("\n") }
                },
            )
        }
    }

    override fun onStartInput(attribute: EditorInfo?, restarting: Boolean) {
        super.onStartInput(attribute, restarting)
        buffer = StringBuilder()
        scope.launch {
            snippets =
                withContext(Dispatchers.IO) {
                    AppDatabase.getDatabase(applicationContext)
                        .textExpansionDao()
                        .getEnabled()
                        .map { it.toTextExpansionSnippet() }
                }
        }
    }

    override fun onDestroy() {
        scope.cancel()
        super.onDestroy()
    }

    private fun LinearLayout.addKeyboardRow(chars: String) {
        addView(
            LinearLayout(context).apply {
                orientation = LinearLayout.HORIZONTAL
                for (char in chars) {
                    addActionButton(char.toString()) { commitText(char.toString()) }
                }
            },
        )
    }

    private fun LinearLayout.addActionButton(label: String, action: () -> Unit) {
        addView(
            Button(context).apply {
                text = label
                minWidth = 0
                minHeight = 0
                setOnClickListener { action() }
            },
            LinearLayout.LayoutParams(0, LinearLayout.LayoutParams.WRAP_CONTENT, 1f),
        )
    }

    private fun commitText(text: String) {
        currentInputConnection?.commitText(text, TextExpansionImeConstants.IME_COMMITTED_TEXT_FLAG)
        buffer.append(text)
        if (buffer.length > TextExpansionImeConstants.INPUT_BUFFER_MAX_CHARS) {
            buffer = StringBuilder(buffer.takeLast(TextExpansionImeConstants.INPUT_BUFFER_MAX_CHARS))
        }
        maybeExpand()
    }

    private fun deleteBackward() {
        currentInputConnection?.deleteSurroundingText(1, 0)
        if (buffer.isNotEmpty()) {
            buffer.deleteAt(buffer.length - 1)
        }
    }

    private fun maybeExpand() {
        val match =
            TextExpansionMatcher.match(
                text = buffer.toString(),
                snippets = snippets,
                surface = TextExpansionSurface.ANDROID_IME,
                expandWhenUnambiguous = false,
            ) ?: return
        if (match.requiresPreview) return
        val boundaryLength = if (match.boundary == null) 0 else 1
        currentInputConnection?.deleteSurroundingText(match.token.length + boundaryLength, 0)
        currentInputConnection?.commitText(
            match.snippet.body + (match.boundary?.toString() ?: ""),
            TextExpansionImeConstants.IME_COMMITTED_TEXT_FLAG,
        )
        buffer = StringBuilder()
    }

    private fun TextExpansionSnippetEntity.toTextExpansionSnippet(): TextExpansionSnippet = TextExpansionSnippet(
        id = id,
        title = title,
        trigger = trigger,
        body = body,
        mode = TextExpansionMode.fromWireName(mode),
        isEnabled = isEnabled,
        scope = TextExpansionScope(surfaces = setOf(TextExpansionSurface.ANDROID_IME, TextExpansionSurface.IN_APP_THREAD)),
        deletedAtMillis = deletedAtMillis,
    )
}
