package com.openburnbar.ui.support

import android.content.Intent
import android.net.Uri
import androidx.compose.foundation.layout.Arrangement
import androidx.compose.foundation.layout.Column
import androidx.compose.foundation.layout.Row
import androidx.compose.foundation.layout.Spacer
import androidx.compose.foundation.layout.fillMaxWidth
import androidx.compose.foundation.layout.height
import androidx.compose.foundation.layout.padding
import androidx.compose.foundation.layout.size
import androidx.compose.foundation.layout.width
import androidx.compose.foundation.rememberScrollState
import androidx.compose.foundation.shape.RoundedCornerShape
import androidx.compose.foundation.verticalScroll
import androidx.compose.material.icons.Icons
import androidx.compose.material.icons.filled.CheckCircle
import androidx.compose.material.icons.filled.Close
import androidx.compose.material.icons.filled.Warning
import androidx.compose.material3.Button
import androidx.compose.material3.CircularProgressIndicator
import androidx.compose.material3.ExperimentalMaterial3Api
import androidx.compose.material3.Icon
import androidx.compose.material3.IconButton
import androidx.compose.material3.MaterialTheme
import androidx.compose.material3.ModalBottomSheet
import androidx.compose.material3.OutlinedTextField
import androidx.compose.material3.RadioButton
import androidx.compose.material3.Surface
import androidx.compose.material3.Switch
import androidx.compose.material3.Text
import androidx.compose.material3.TextButton
import androidx.compose.material3.rememberModalBottomSheetState
import androidx.compose.runtime.Composable
import androidx.compose.runtime.getValue
import androidx.compose.runtime.mutableStateOf
import androidx.compose.runtime.remember
import androidx.compose.runtime.rememberCoroutineScope
import androidx.compose.runtime.setValue
import androidx.compose.ui.Alignment
import androidx.compose.ui.Modifier
import androidx.compose.ui.graphics.Color
import androidx.compose.ui.platform.LocalContext
import androidx.compose.ui.text.font.FontFamily
import androidx.compose.ui.text.font.FontWeight
import androidx.compose.ui.unit.dp
import androidx.compose.ui.unit.sp
import com.openburnbar.data.models.AndroidDiagnosticsSnapshot
import com.openburnbar.data.models.BugReportSubmission
import com.openburnbar.data.models.BugReportSubmissionResult
import com.openburnbar.data.support.BugReportService
import kotlinx.coroutines.launch

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BugReportBottomSheet(onDismiss: () -> Unit, service: BugReportService = remember { BugReportService() }) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()
    val context = LocalContext.current

    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("Bug / Crash") }
    var includeDiagnostics by remember { mutableStateOf(true) }
    var autoDispenseCLI by remember { mutableStateOf(true) }
    var selectedRuntime by remember { mutableStateOf("claude") }
    var isSubmitting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var successResult by remember { mutableStateOf<BugReportSubmissionResult?>(null) }

    val categories = listOf("Bug / Crash", "UI Issue", "Agent / CLI Issue", "Sync / Quotas", "Other")
    val runtimes =
        listOf(
            "claude" to "Claude Code",
            "codex" to "Codex",
            "antigravity" to "Antigravity",
            "droid" to "Droid",
            "auto" to "Auto",
        )

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        Column(
            modifier =
            Modifier
                .fillMaxWidth()
                .padding(horizontal = 24.dp, vertical = 8.dp)
                .verticalScroll(rememberScrollState()),
        ) {
            // Header
            Row(
                modifier = Modifier.fillMaxWidth(),
                horizontalArrangement = Arrangement.SpaceBetween,
                verticalAlignment = Alignment.CenterVertically,
            ) {
                Text(
                    text = "Report a Bug or Feedback",
                    style = MaterialTheme.typography.titleLarge,
                    fontWeight = FontWeight.Bold,
                )
                IconButton(onClick = onDismiss) {
                    Icon(Icons.Default.Close, contentDescription = "Close")
                }
            }

            Spacer(modifier = Modifier.height(12.dp))

            val success = successResult
            if (success != null) {
                // Success State
                Column(
                    modifier =
                    Modifier
                        .fillMaxWidth()
                        .padding(vertical = 24.dp),
                    horizontalAlignment = Alignment.CenterHorizontally,
                ) {
                    Icon(
                        Icons.Default.CheckCircle,
                        contentDescription = "Success",
                        tint = Color(0xFF4CAF50),
                        modifier = Modifier.size(56.dp),
                    )
                    Spacer(modifier = Modifier.height(12.dp))
                    Text(
                        text = "Bug Report Submitted!",
                        style = MaterialTheme.typography.titleMedium,
                        fontWeight = FontWeight.Bold,
                    )
                    Spacer(modifier = Modifier.height(6.dp))
                    Text(
                        text = "Issue created in Linear and tracked for resolution.",
                        style = MaterialTheme.typography.bodySmall,
                        color = Color.Gray,
                    )

                    Spacer(modifier = Modifier.height(16.dp))

                    Surface(
                        shape = RoundedCornerShape(8.dp),
                        color = MaterialTheme.colorScheme.primaryContainer,
                        modifier = Modifier.padding(horizontal = 16.dp),
                    ) {
                        Column(
                            modifier = Modifier.padding(12.dp),
                            horizontalAlignment = Alignment.CenterHorizontally,
                        ) {
                            Text(
                                text = success.linearIdentifier,
                                fontWeight = FontWeight.Bold,
                                fontFamily = FontFamily.Monospace,
                                fontSize = 16.sp,
                            )
                            if (success.linearUrl.isNotBlank()) {
                                TextButton(onClick = {
                                    val intent = Intent(Intent.ACTION_VIEW, Uri.parse(success.linearUrl))
                                    context.startActivity(intent)
                                }) {
                                    Text("Open in Linear")
                                }
                            }
                        }
                    }

                    if (success.missionId != null) {
                        Spacer(modifier = Modifier.height(8.dp))
                        Text(
                            text = "Mac CLI agent mission dispatched",
                            style = MaterialTheme.typography.bodySmall,
                            color = Color(0xFFFF9800),
                        )
                    }

                    Spacer(modifier = Modifier.height(24.dp))

                    Button(
                        onClick = onDismiss,
                        modifier = Modifier.fillMaxWidth(),
                    ) {
                        Text("Done")
                    }
                }
            } else {
                // Error banner
                errorMessage?.let { error ->
                    Surface(
                        color = MaterialTheme.colorScheme.errorContainer,
                        shape = RoundedCornerShape(8.dp),
                        modifier = Modifier.fillMaxWidth().padding(bottom = 12.dp),
                    ) {
                        Row(modifier = Modifier.padding(12.dp), verticalAlignment = Alignment.CenterVertically) {
                            Icon(Icons.Default.Warning, contentDescription = null, tint = MaterialTheme.colorScheme.error)
                            Spacer(modifier = Modifier.width(8.dp))
                            Text(error, style = MaterialTheme.typography.bodySmall, color = MaterialTheme.colorScheme.onErrorContainer)
                        }
                    }
                }

                // Category selection
                Text("Category", style = MaterialTheme.typography.labelMedium)
                Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
                    categories.take(3).forEach { cat ->
                        Row(verticalAlignment = Alignment.CenterVertically) {
                            RadioButton(selected = category == cat, onClick = { category = cat })
                            Text(cat, style = MaterialTheme.typography.bodySmall)
                        }
                    }
                }

                Spacer(modifier = Modifier.height(8.dp))

                // Title
                OutlinedTextField(
                    value = title,
                    onValueChange = { title = it },
                    label = { Text("Summary") },
                    placeholder = { Text("What went wrong?") },
                    modifier = Modifier.fillMaxWidth(),
                    singleLine = true,
                )

                Spacer(modifier = Modifier.height(12.dp))

                // Description
                OutlinedTextField(
                    value = description,
                    onValueChange = { description = it },
                    label = { Text("Details & Steps to Reproduce") },
                    modifier = Modifier.fillMaxWidth().height(120.dp),
                )

                Spacer(modifier = Modifier.height(12.dp))

                // Diagnostics toggle
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Include Device Diagnostics", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                        Text("OS version, device model, hardware specs.", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    }
                    Switch(checked = includeDiagnostics, onCheckedChange = { includeDiagnostics = it })
                }

                Spacer(modifier = Modifier.height(12.dp))

                // Auto dispense CLI agent toggle
                Row(
                    modifier = Modifier.fillMaxWidth(),
                    horizontalArrangement = Arrangement.SpaceBetween,
                    verticalAlignment = Alignment.CenterVertically,
                ) {
                    Column(modifier = Modifier.weight(1f)) {
                        Text("Auto-Dispense Mac CLI Agent", style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
                        Text("Immediately launches agent on your Mac to fix.", style = MaterialTheme.typography.bodySmall, color = Color.Gray)
                    }
                    Switch(checked = autoDispenseCLI, onCheckedChange = { autoDispenseCLI = it })
                }

                Spacer(modifier = Modifier.height(20.dp))

                // Submit button
                Button(
                    onClick = {
                        scope.launch {
                            isSubmitting = true
                            errorMessage = null
                            val diagnostics = if (includeDiagnostics) AndroidDiagnosticsSnapshot().toMap() else null
                            val submission =
                                BugReportSubmission(
                                    title = "[$category] ${title.trim()}",
                                    description = if (description.isBlank()) title else description,
                                    platform = "Android",
                                    diagnostics = diagnostics,
                                    autoDispenseCLI = autoDispenseCLI,
                                    requestedRuntime = selectedRuntime,
                                )

                            val result = service.submit(submission)
                            result.onSuccess { successResult = it }
                                .onFailure { errorMessage = it.message ?: "Failed to submit bug report." }
                            isSubmitting = false
                        }
                    },
                    modifier = Modifier.fillMaxWidth(),
                    enabled = title.isNotBlank() && !isSubmitting,
                ) {
                    if (isSubmitting) {
                        CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
                        Spacer(modifier = Modifier.width(8.dp))
                    }
                    Text(if (autoDispenseCLI) "Submit & Dispatch Mac Agent" else "Submit Bug Report")
                }

                Spacer(modifier = Modifier.height(16.dp))
            }
        }
    }
}
