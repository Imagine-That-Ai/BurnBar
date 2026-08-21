package com.openburnbar.ui.recap

import androidx.compose.foundation.background
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.shape.CircleShape
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.draw.clip
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.recap.MonthlyRecap
import com.openburnbar.data.recap.RecapCard
import com.openburnbar.data.recap.RecapSealState
import com.openburnbar.ui.theme.AuroraColors
import java.util.Locale

@Composable
fun RecapDeckView(recap: MonthlyRecap, modifier: Modifier = Modifier, onShareCard: ((RecapCard) -> Unit)? = null, onShareRecap: (() -> Unit)? = null) {
    BoxWithConstraints(modifier = modifier.fillMaxWidth()) {
        val isTablet = maxWidth >= 600.dp
        val columns = if (isTablet) 2 else 1

        Column(
            verticalArrangement = Arrangement.spacedBy(RecapTheme.Layout.gutter),
            modifier = Modifier.fillMaxWidth(),
        ) {
            RecapDeckHeader(recap = recap)

            Spacer(modifier = Modifier.height(4.dp))

            // Pack cards into rows
            val rows = packCardsIntoRows(recap.cards, columns)
            rows.forEach { rowCards ->
                if (rowCards.size == 1) {
                    val card = rowCards[0]
                    RecapCardView(card = card, onShare = onShareCard)
                } else {
                    Row(
                        horizontalArrangement = Arrangement.spacedBy(RecapTheme.Layout.gutter),
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        rowCards.forEach { card ->
                            Box(modifier = Modifier.weight(1f)) {
                                RecapCardView(card = card, onShare = onShareCard)
                            }
                        }
                    }
                }
            }

            Spacer(modifier = Modifier.height(8.dp))

            RecapClosingCard(recap = recap, onShare = onShareRecap)
        }
    }
}

@Composable
fun RecapDeckHeader(recap: MonthlyRecap, modifier: Modifier = Modifier) {
    Column(
        verticalArrangement = Arrangement.spacedBy(8.dp),
        modifier = modifier.fillMaxWidth(),
    ) {
        Row(
            verticalAlignment = Alignment.CenterVertically,
            horizontalArrangement = Arrangement.spacedBy(8.dp),
        ) {
            Text(
                text = recap.window.displayLabel().uppercase(Locale.getDefault()),
                style = RecapTheme.Typography.eyebrow,
                color = AuroraColors.lightTextMuted,
            )

            if (recap.sealState == RecapSealState.PREVIEW) {
                RecapBadge(text = "So far", tint = AuroraColors.whimsy)
            }
            if (recap.isPartial) {
                RecapBadge(text = "Sample", tint = AuroraColors.warning)
            }
        }

        Text(
            text = recap.title,
            style = RecapTheme.Typography.heroHeadline.copy(fontSize = 32.sp, lineHeight = 38.sp),
            color = AuroraColors.lightTextPrimary,
        )

        if (!recap.subtitle.isNullOrEmpty()) {
            Text(
                text = recap.subtitle,
                style = RecapTheme.Typography.cardBody,
                color = AuroraColors.lightTextSecondary,
            )
        }

        if (recap.isPartial) {
            Text(
                text = "Summarised from part of the month, so totals and records are held back.",
                style = RecapTheme.Typography.caption,
                color = AuroraColors.lightTextMuted,
            )
        }
    }
}

@Composable
fun RecapBadge(text: String, tint: Color, modifier: Modifier = Modifier) {
    Box(
        modifier = modifier
            .clip(CircleShape)
            .background(tint.copy(alpha = 0.14f))
            .padding(horizontal = 7.dp, vertical = 3.dp),
    ) {
        Text(
            text = text.uppercase(Locale.getDefault()),
            style = RecapTheme.Typography.eyebrow.copy(fontSize = 9.sp, letterSpacing = 0.8.sp),
            color = tint,
        )
    }
}

private fun packCardsIntoRows(cards: List<RecapCard>, columns: Int): List<List<RecapCard>> {
    if (columns == 1) {
        return cards.map { listOf(it) }
    }
    val rows = mutableListOf<List<RecapCard>>()
    var i = 0
    while (i < cards.size) {
        val c1 = cards[i]
        val span1 = c1.size.columnSpan(columns)
        if (span1 >= 2 || i + 1 >= cards.size) {
            rows.add(listOf(c1))
            i++
        } else {
            val c2 = cards[i + 1]
            val span2 = c2.size.columnSpan(columns)
            if (span2 >= 2) {
                rows.add(listOf(c1))
                i++
            } else {
                rows.add(listOf(c1, c2))
                i += 2
            }
        }
    }
    return rows
}
