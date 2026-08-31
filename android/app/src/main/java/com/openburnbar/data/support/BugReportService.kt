package com.openburnbar.data.support

import android.util.Log
import com.google.firebase.functions.FirebaseFunctions
import com.openburnbar.data.models.BugReportSubmission
import com.openburnbar.data.models.BugReportSubmissionResult
import kotlinx.coroutines.tasks.await

class BugReportService(
    private val functionsProvider: () -> FirebaseFunctions = {
        FirebaseFunctions.getInstance("us-central1")
    },
) {
    companion object {
        private const val TAG = "BugReportService"
    }

    suspend fun submit(submission: BugReportSubmission): Result<BugReportSubmissionResult> =
        runCatching {
            val payload =
                mutableMapOf<String, Any>(
                    "title" to submission.title,
                    "description" to submission.description,
                    "platform" to submission.platform,
                    "autoDispenseCLI" to submission.autoDispenseCLI,
                )

            submission.appVersion?.let { payload["appVersion"] = it }
            submission.osVersion?.let { payload["osVersion"] = it }
            submission.deviceModel?.let { payload["deviceModel"] = it }
            submission.diagnostics?.let { payload["diagnostics"] = it }
            submission.logsSnippet?.let { payload["logsSnippet"] = it }
            submission.requestedRuntime?.let { payload["requestedRuntime"] = it }
            submission.targetProject?.let { payload["targetProject"] = it }

            Log.i(TAG, "Submitting Android bug report: '${submission.title}'")

            val functions = functionsProvider()
            val result = functions.getHttpsCallable("submitBugReport").call(payload).await()
            val data = result.getData() as? Map<*, *> ?: error("Invalid response from server.")

            val reportId = data["reportId"] as? String ?: ""
            val missionId = data["missionId"] as? String
            val linear = data["linearIssue"] as? Map<*, *> ?: emptyMap<String, Any>()
            val identifier = linear["identifier"] as? String ?: "BB-ISSUE"
            val url = linear["url"] as? String ?: "https://linear.app"
            val isMock = linear["mock"] as? Boolean ?: false

            Log.i(TAG, "Bug report submitted successfully. Linear issue: $identifier")

            BugReportSubmissionResult(
                reportId = reportId,
                linearIdentifier = identifier,
                linearUrl = url,
                isMock = isMock,
                missionId = missionId,
            )
        }
}
