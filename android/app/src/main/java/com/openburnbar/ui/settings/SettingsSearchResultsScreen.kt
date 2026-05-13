package com.openburnbar.ui.settings

import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxSize
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.lazy.LazyColumn
import androidx.compose.foundation.lazy.items
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.automirrored.filled.NavigateNext
import androidx.compose.material.icons.filled.Search
import androidx.compose.material3.Button
import androidx.compose.material3.Icon
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.Surface
import androidx.compose.material3.Text
import androidx.compose.runtime.Composable
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.ui.theme.AuroraRadius
import com.openburnbar.ui.theme.AuroraSpacing
import com.openburnbar.ui.theme.AuroraType
import com.openburnbar.ui.theme.AuroraTypography

/**
 * Aurora-styled list of ranked settings matches. Tapping a row asks the
 * [SettingsRouter] to navigate to the underlying control.
 */
@Composable
fun SettingsSearchResultsScreen(router: SettingsRouter) {
    val results = SettingsSearchEngine.search(router.query, SettingsManifest.all)

    if (results.isEmpty()) {
        EmptyState(router = router)
        return
    }

    Column(modifier = Modifier.fillMaxSize()) {
        Text(
            "${results.size} result${if (results.size == 1) "" else "s"}",
            style = AuroraType.caption,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
            modifier = Modifier.padding(vertical = AuroraSpacing.xs.dp)
        )

        LazyColumn(
            verticalArrangement = Arrangement.spacedBy(AuroraSpacing.sm.dp),
            modifier = Modifier.fillMaxSize()
        ) {
            items(results) { item ->
                SettingsResultRow(
                    item = item,
                    onClick = { router.navigate(item) }
                )
            }
        }
    }
}

@Composable
private fun SettingsResultRow(
    item: SettingsItem,
    onClick: () -> Unit,
) {
    Surface(
        onClick = onClick,
        modifier = Modifier.fillMaxWidth(),
        shape = RoundedCornerShape(AuroraRadius.lg.dp),
        color = MaterialTheme.colorScheme.surface.copy(alpha = 0.6f)
    ) {
        Row(
            modifier = Modifier
                .fillMaxWidth()
                .padding(AuroraSpacing.md.dp),
            verticalAlignment = Alignment.CenterVertically
        ) {
            Column(modifier = Modifier.weight(1f)) {
                Text(
                    item.title,
                    fontSize = AuroraTypography.body.sp,
                    fontWeight = FontWeight.SemiBold,
                )
                if (!item.subtitle.isNullOrEmpty()) {
                    Text(
                        item.subtitle,
                        fontSize = AuroraTypography.caption.sp,
                        color = MaterialTheme.colorScheme.onSurfaceVariant,
                    )
                }
                Text(
                    breadcrumb(item),
                    fontSize = AuroraTypography.caption.sp,
                    color = MaterialTheme.colorScheme.onSurfaceVariant,
                )
            }
            Spacer(modifier = Modifier.width(AuroraSpacing.sm.dp))
            Icon(
                imageVector = Icons.AutoMirrored.Filled.NavigateNext,
                contentDescription = null,
                modifier = Modifier.size(20.dp),
                tint = MaterialTheme.colorScheme.onSurfaceVariant.copy(alpha = 0.5f),
            )
        }
    }
}

@Composable
private fun EmptyState(router: SettingsRouter) {
    Column(
        modifier = Modifier.fillMaxSize(),
        verticalArrangement = Arrangement.Center,
        horizontalAlignment = Alignment.CenterHorizontally,
    ) {
        Icon(
            imageVector = Icons.Filled.Search,
            contentDescription = null,
            modifier = Modifier.size(36.dp),
            tint = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.sm.dp))
        Text(
            "No settings match \u201C${router.query}\u201D",
            fontSize = AuroraTypography.body.sp,
            fontWeight = FontWeight.SemiBold,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.xs.dp))
        Text(
            "Try a broader term, or browse the list.",
            fontSize = AuroraTypography.caption.sp,
            color = MaterialTheme.colorScheme.onSurfaceVariant,
        )
        Spacer(modifier = Modifier.height(AuroraSpacing.md.dp))
        Button(onClick = { router.reset() }) {
            Text("Browse all")
        }
    }
}

private fun breadcrumb(item: SettingsItem): String {
    val sectionTitle = item.section.displayTitle
    val pageLabel = when (item.pageRoute) {
        SettingsPageRoute.ROOT -> ""
        SettingsPageRoute.SMART_DISPLAYS -> "Smart Displays"
        SettingsPageRoute.MENU_BAR_PREFS -> "Quick-Glance"
    }
    return if (pageLabel.isEmpty()) sectionTitle else "$sectionTitle › $pageLabel"
}
