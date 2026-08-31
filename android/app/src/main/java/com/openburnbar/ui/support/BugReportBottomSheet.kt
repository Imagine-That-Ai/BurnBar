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

private val BUG_REPORT_CATEGORIES = listOf("Bug / Crash", "UI Issue", "Agent / CLI Issue", "Sync / Quotas", "Other")

private suspend fun submitAndroidBugReport(
    service: BugReportService,
    title: String,
    description: String,
    category: String,
    includeDiagnostics: Boolean,
    autoDispenseCLI: Boolean,
    selectedRuntime: String,
): Result<BugReportSubmissionResult> {
    val diagnostics = if (includeDiagnostics) AndroidDiagnosticsSnapshot().toMap() else null
    return service.submit(
        BugReportSubmission(
            title = "[$category] ${title.trim()}",
            description = if (description.isBlank()) title else description,
            platform = "Android",
            diagnostics = diagnostics,
            autoDispenseCLI = autoDispenseCLI,
            requestedRuntime = selectedRuntime,
        ),
    )
}

@OptIn(ExperimentalMaterial3Api::class)
@Composable
fun BugReportBottomSheet(onDismiss: () -> Unit, service: BugReportService = remember { BugReportService() }) {
    val sheetState = rememberModalBottomSheetState(skipPartiallyExpanded = true)
    val scope = rememberCoroutineScope()

    var title by remember { mutableStateOf("") }
    var description by remember { mutableStateOf("") }
    var category by remember { mutableStateOf("Bug / Crash") }
    var includeDiagnostics by remember { mutableStateOf(true) }
    var autoDispenseCLI by remember { mutableStateOf(true) }
    var selectedRuntime by remember { mutableStateOf("claude") }
    var isSubmitting by remember { mutableStateOf(false) }
    var errorMessage by remember { mutableStateOf<String?>(null) }
    var successResult by remember { mutableStateOf<BugReportSubmissionResult?>(null) }

    ModalBottomSheet(
        onDismissRequest = onDismiss,
        sheetState = sheetState,
    ) {
        BugReportSheetBody(
            title = title,
            onTitleChange = { title = it },
            description = description,
            onDescriptionChange = { description = it },
            category = category,
            onCategoryChange = { category = it },
            includeDiagnostics = includeDiagnostics,
            onIncludeDiagnosticsChange = { includeDiagnostics = it },
            autoDispenseCLI = autoDispenseCLI,
            onAutoDispenseCLIChange = { autoDispenseCLI = it },
            isSubmitting = isSubmitting,
            errorMessage = errorMessage,
            successResult = successResult,
            onDismiss = onDismiss,
            onSubmit = {
                scope.launch {
                    isSubmitting = true
                    errorMessage = null
                    val outcome = submitAndroidBugReport(
                        service = service,
                        title = title,
                        description = description,
                        category = category,
                        includeDiagnostics = includeDiagnostics,
                        autoDispenseCLI = autoDispenseCLI,
                        selectedRuntime = selectedRuntime,
                    )
                    outcome.onSuccess { successResult = it }
                        .onFailure { errorMessage = it.message ?: "Failed to submit bug report." }
                    isSubmitting = false
                }
            },
        )
    }
}

@Composable
private fun BugReportSheetBody(
    title: String,
    onTitleChange: (String) -> Unit,
    description: String,
    onDescriptionChange: (String) -> Unit,
    category: String,
    onCategoryChange: (String) -> Unit,
    includeDiagnostics: Boolean,
    onIncludeDiagnosticsChange: (Boolean) -> Unit,
    autoDispenseCLI: Boolean,
    onAutoDispenseCLIChange: (Boolean) -> Unit,
    isSubmitting: Boolean,
    errorMessage: String?,
    successResult: BugReportSubmissionResult?,
    onDismiss: () -> Unit,
    onSubmit: () -> Unit,
) {
    Column(
        modifier =
        Modifier
            .fillMaxWidth()
            .padding(horizontal = 24.dp, vertical = 8.dp)
            .verticalScroll(rememberScrollState()),
    ) {
        BugReportSheetHeader(onDismiss = onDismiss)
        Spacer(modifier = Modifier.height(12.dp))
        val success = successResult
        if (success != null) {
            BugReportSuccessContent(success = success, onDismiss = onDismiss)
        } else {
            BugReportFormContent(
                title = title,
                onTitleChange = onTitleChange,
                description = description,
                onDescriptionChange = onDescriptionChange,
                category = category,
                onCategoryChange = onCategoryChange,
                includeDiagnostics = includeDiagnostics,
                onIncludeDiagnosticsChange = onIncludeDiagnosticsChange,
                autoDispenseCLI = autoDispenseCLI,
                onAutoDispenseCLIChange = onAutoDispenseCLIChange,
                isSubmitting = isSubmitting,
                errorMessage = errorMessage,
                onSubmit = onSubmit,
            )
        }
    }
}

@Composable
private fun BugReportSheetHeader(onDismiss: () -> Unit) {
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
}

@Composable
private fun BugReportSuccessContent(success: BugReportSubmissionResult, onDismiss: () -> Unit) {
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
        BugReportLinearIssueCard(success = success)
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
}

@Composable
private fun BugReportLinearIssueCard(success: BugReportSubmissionResult) {
    val context = LocalContext.current
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
}

@Composable
private fun BugReportFormContent(
    title: String,
    onTitleChange: (String) -> Unit,
    description: String,
    onDescriptionChange: (String) -> Unit,
    category: String,
    onCategoryChange: (String) -> Unit,
    includeDiagnostics: Boolean,
    onIncludeDiagnosticsChange: (Boolean) -> Unit,
    autoDispenseCLI: Boolean,
    onAutoDispenseCLIChange: (Boolean) -> Unit,
    isSubmitting: Boolean,
    errorMessage: String?,
    onSubmit: () -> Unit,
) {
    BugReportErrorBanner(errorMessage)
    BugReportCategoryRow(category = category, onCategoryChange = onCategoryChange)
    Spacer(modifier = Modifier.height(8.dp))
    OutlinedTextField(
        value = title,
        onValueChange = onTitleChange,
        label = { Text("Summary") },
        placeholder = { Text("What went wrong?") },
        modifier = Modifier.fillMaxWidth(),
        singleLine = true,
    )
    Spacer(modifier = Modifier.height(12.dp))
    OutlinedTextField(
        value = description,
        onValueChange = onDescriptionChange,
        label = { Text("Details & Steps to Reproduce") },
        modifier = Modifier.fillMaxWidth().height(120.dp),
    )
    Spacer(modifier = Modifier.height(12.dp))
    BugReportToggleRow(
        title = "Include Device Diagnostics",
        subtitle = "OS version, device model, hardware specs.",
        checked = includeDiagnostics,
        onCheckedChange = onIncludeDiagnosticsChange,
    )
    Spacer(modifier = Modifier.height(12.dp))
    BugReportToggleRow(
        title = "Auto-Dispense Mac CLI Agent",
        subtitle = "Immediately launches agent on your Mac to fix.",
        checked = autoDispenseCLI,
        onCheckedChange = onAutoDispenseCLIChange,
    )
    Spacer(modifier = Modifier.height(20.dp))
    BugReportSubmitButton(
        title = title,
        isSubmitting = isSubmitting,
        autoDispenseCLI = autoDispenseCLI,
        onSubmit = onSubmit,
    )
    Spacer(modifier = Modifier.height(16.dp))
}

@Composable
private fun BugReportSubmitButton(
    title: String,
    isSubmitting: Boolean,
    autoDispenseCLI: Boolean,
    onSubmit: () -> Unit,
) {
    Button(
        onClick = onSubmit,
        modifier = Modifier.fillMaxWidth(),
        enabled = title.isNotBlank() && !isSubmitting,
    ) {
        if (isSubmitting) {
            CircularProgressIndicator(color = Color.White, modifier = Modifier.size(18.dp), strokeWidth = 2.dp)
            Spacer(modifier = Modifier.width(8.dp))
        }
        Text(if (autoDispenseCLI) "Submit & Dispatch Mac Agent" else "Submit Bug Report")
    }
}

@Composable
private fun BugReportErrorBanner(errorMessage: String?) {
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
}

@Composable
private fun BugReportCategoryRow(category: String, onCategoryChange: (String) -> Unit) {
    Text("Category", style = MaterialTheme.typography.labelMedium)
    Row(modifier = Modifier.fillMaxWidth(), horizontalArrangement = Arrangement.SpaceBetween) {
        BUG_REPORT_CATEGORIES.take(3).forEach { cat ->
            Row(verticalAlignment = Alignment.CenterVertically) {
                RadioButton(selected = category == cat, onClick = { onCategoryChange(cat) })
                Text(cat, style = MaterialTheme.typography.bodySmall)
            }
        }
    }
}

@Composable
private fun BugReportToggleRow(
    title: String,
    subtitle: String,
    checked: Boolean,
    onCheckedChange: (Boolean) -> Unit,
) {
    Row(
        modifier = Modifier.fillMaxWidth(),
        horizontalArrangement = Arrangement.SpaceBetween,
        verticalAlignment = Alignment.CenterVertically,
    ) {
        Column(modifier = Modifier.weight(1f)) {
            Text(title, style = MaterialTheme.typography.bodyMedium, fontWeight = FontWeight.SemiBold)
            Text(subtitle, style = MaterialTheme.typography.bodySmall, color = Color.Gray)
        }
        Switch(checked = checked, onCheckedChange = onCheckedChange)
    }
}
