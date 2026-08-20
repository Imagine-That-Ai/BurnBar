// Compose renderer for Living Layout Space Budget.
// Lays out slots into columns, animates continuous reflow via PensieveMotion.

package com.openburnbar.ui.pulse.layout

import androidx.compose.animation.animateContentSize
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Box
import androidx.compose.foundation.layout.BoxWithConstraints
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.fillMaxHeight
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.verticalScroll
import androidx.compose.runtime.Composable
import androidx.compose.runtime.LaunchedEffect
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableIntStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.unit.Dp
import androidx.compose.ui.unit.dp
import com.openburnbar.ui.components.StaggeredEntrance
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.LocalAuroraReduceMotion
import com.openburnbar.ui.tokens.PensieveMotion
import kotlin.math.max

/**
 * Living layout renderer.
 *
 * Replaces hardcoded ScrollView/VStack combinations with pure Space Budget resolution.
 * - Fills or scrolls: when the plan fits, slots take resolved heights consuming all dead space.
 *   When it overflows, the surface scrolls and slots hug content.
 * - Reflows into columns instead of capping width.
 * - Choreographed with PensieveMotion settle and arrive spring specs.
 */
@Composable
fun HomeLivingLayout(
    slots: List<HomeSlot>,
    modifier: Modifier = Modifier,
    gutter: Dp = AuroraSpacing.MD.dp,
    padding: Dp = AuroraSpacing.MD.dp,
    slotContent: @Composable (String, HomeSpacePlan.Placement) -> Unit,
) {
    val reduceMotion = LocalAuroraReduceMotion.current
    var columns by remember { mutableIntStateOf(1) }

    BoxWithConstraints(modifier = modifier.fillMaxSize()) {
        val rawWidth = maxWidth.value
        val rawHeight = maxHeight.value
        val canvasWidth = max(0f, rawWidth - padding.value * 2)
        val canvasHeight = max(0f, rawHeight - padding.value * 2)

        LaunchedEffect(rawWidth, slots.size) {
            val nextColumns = HomeSpaceBudget.columns(forWidth = rawWidth, current = columns, slots = slots.size)
            if (nextColumns != columns) {
                columns = nextColumns
            }
        }

        val plan = remember(canvasWidth, canvasHeight, slots, gutter.value, columns) {
            HomeSpaceBudget.resolve(
                canvasWidth = canvasWidth,
                canvasHeight = canvasHeight,
                slots = slots,
                gutter = gutter.value,
                columns = columns,
            )
        }

        val contentModifier = Modifier
            .fillMaxSize()
            .padding(padding)
            .animateContentSize(animationSpec = PensieveMotion.settleSpec(reduceMotion))

        if (plan.overflows) {
            Box(
                modifier = contentModifier.verticalScroll(rememberScrollState()),
            ) {
                LivingLayoutComposition(
                    plan = plan,
                    gutter = gutter,
                    slotContent = slotContent,
                )
            }
        } else {
            Box(modifier = contentModifier) {
                LivingLayoutComposition(
                    plan = plan,
                    gutter = gutter,
                    slotContent = slotContent,
                )
            }
        }
    }
}

@Composable
private fun LivingLayoutComposition(plan: HomeSpacePlan, gutter: Dp, slotContent: @Composable (String, HomeSpacePlan.Placement) -> Unit) {
    Column(
        modifier = Modifier.fillMaxWidth(),
        verticalArrangement = Arrangement.spacedBy(gutter),
    ) {
        val spanningIds = plan.visibleSpanningIDs
        spanningIds.forEachIndexed { index, id ->
            LivingLayoutSlotWrapper(
                id = id,
                plan = plan,
                staggerIndex = index,
                slotContent = slotContent,
            )
        }

        if (plan.columns > 1) {
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.spacedBy(gutter),
                verticalAlignment = Alignment.Top,
            ) {
                plan.columnGroups.forEach { group ->
                    Column(
                        modifier = Modifier
                            .weight(1f)
                            .fillMaxHeight(),
                        verticalArrangement = Arrangement.spacedBy(gutter),
                    ) {
                        group.forEachIndexed { index, id ->
                            LivingLayoutSlotWrapper(
                                id = id,
                                plan = plan,
                                staggerIndex = index + spanningIds.size,
                                slotContent = slotContent,
                            )
                        }
                    }
                }
            }
        } else {
            val singleGroup = plan.columnGroups.firstOrNull() ?: emptyList()
            singleGroup.forEachIndexed { index, id ->
                LivingLayoutSlotWrapper(
                    id = id,
                    plan = plan,
                    staggerIndex = index + spanningIds.size,
                    slotContent = slotContent,
                )
            }
        }
    }
}

@Composable
private fun LivingLayoutSlotWrapper(id: String, plan: HomeSpacePlan, staggerIndex: Int, slotContent: @Composable (String, HomeSpacePlan.Placement) -> Unit) {
    val placement = plan.placement(id) ?: return
    if (!placement.isVisible) return

    val slotModifier = Modifier.fillMaxWidth().let { mod ->
        if (placement.height != null && !plan.overflows) {
            mod.height(placement.height.dp)
        } else {
            mod
        }
    }

    StaggeredEntrance(index = staggerIndex) {
        Box(modifier = slotModifier) {
            slotContent(id, placement)
        }
    }
}
