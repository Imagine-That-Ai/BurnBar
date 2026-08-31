package com.openburnbar.data.models

import android.os.Build
import com.google.firebase.firestore.IgnoreExtraProperties
import kotlinx.serialization.Serializable

@IgnoreExtraProperties
@Serializable
data class BugReportSubmission(
    val title: String,
    val description: String,
    val platform: String = "Android",
    val appVersion: String? = null,
    val osVersion: String? = null,
    val deviceModel: String? = null,
    val diagnostics: Map<String, String>? = null,
    val logsSnippet: String? = null,
    val autoDispenseCLI: Boolean = true,
    val requestedRuntime: String? = null,
    val targetProject: String? = null,
)

@IgnoreExtraProperties
@Serializable
data class BugReportSubmissionResult(
    val reportId: String,
    val linearIdentifier: String,
    val linearUrl: String,
    val isMock: Boolean = false,
    val missionId: String? = null,
)

data class AndroidDiagnosticsSnapshot(
    val osVersion: String = "Android ${Build.VERSION.RELEASE} (API ${Build.VERSION.SDK_INT})",
    val deviceModel: String = "${Build.MANUFACTURER} ${Build.MODEL}",
    val appVersion: String = "1.0.0",
    val appBuild: String = "1",
    val board: String = Build.BOARD,
    val timestamp: String = System.currentTimeMillis().toString(),
) {
    fun toMap(): Map<String, String> =
        mapOf(
            "osVersion" to osVersion,
            "deviceModel" to deviceModel,
            "appVersion" to appVersion,
            "appBuild" to appBuild,
            "board" to board,
            "timestamp" to timestamp,
        )
}
