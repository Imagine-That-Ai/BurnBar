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
    suspend fun submit(submission: BugReportSubmission): Result<BugReportSubmissionResult> = runCatching {
        val payload = callablePayload(submission)
        Log.i(TAG, "Submitting Android bug report: '${submission.title}'")

        val functions = functionsProvider()
        val result = functions.getHttpsCallable("submitBugReport").call(payload).await()
        val parsed = parseSubmissionResult(result.getData())
        if (parsed.linearIdentifier != null) {
            Log.i(TAG, "Bug report submitted successfully. Linear issue: ${parsed.linearIdentifier}")
        } else {
            Log.i(TAG, "Bug report submitted without a Linear issue (linearStatus: ${parsed.linearStatus}, reportId: ${parsed.reportId})")
        }
        parsed
    }

    companion object {
        private const val TAG = "BugReportService"

        internal fun callablePayload(submission: BugReportSubmission): Map<String, Any> {
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
            return payload
        }

        internal fun parseSubmissionResult(raw: Any?): BugReportSubmissionResult {
            val data = raw as? Map<*, *> ?: error("Invalid response from server.")
            val reportId = data["reportId"] as? String ?: ""
            val missionId = data["missionId"] as? String
            val linearStatus = data["linearStatus"] as? String ?: "created"
            // linearIssue is null when Linear is unconfigured or the create call
            // failed — the report is still filed and tracked by reportId.
            val linear = data["linearIssue"] as? Map<*, *>
            val identifier = linear?.get("identifier") as? String
            val url = linear?.get("url") as? String
            return BugReportSubmissionResult(
                reportId = reportId,
                linearIdentifier = identifier,
                linearUrl = url,
                linearStatus = linearStatus,
                missionId = missionId,
            )
        }
    }
}
