import Foundation
@preconcurrency import FirebaseFunctions
import OSLog

public struct MobileBugReportSubmission: Sendable {
    public let title: String
    public let description: String
    public let platform: String
    public let appVersion: String?
    public let osVersion: String?
    public let deviceModel: String?
    public let diagnostics: [String: Any]?
    public let logsSnippet: String?
    public let screenshotBase64: String?
    public let autoDispenseCLI: Bool
    public let requestedRuntime: String?
    public let targetProject: String?

    public init(
        title: String,
        description: String,
        platform: String = "iOS",
        appVersion: String? = nil,
        osVersion: String? = nil,
        deviceModel: String? = nil,
        diagnostics: [String: Any]? = nil,
        logsSnippet: String? = nil,
        screenshotBase64: String? = nil,
        autoDispenseCLI: Bool = true,
        requestedRuntime: String? = nil,
        targetProject: String? = nil
    ) {
        self.title = title
        self.description = description
        self.platform = platform
        self.appVersion = appVersion
        self.osVersion = osVersion
        self.deviceModel = deviceModel
        self.diagnostics = diagnostics
        self.logsSnippet = logsSnippet
        self.screenshotBase64 = screenshotBase64
        self.autoDispenseCLI = autoDispenseCLI
        self.requestedRuntime = requestedRuntime
        self.targetProject = targetProject
    }
}

public struct MobileBugReportSubmissionResult: Sendable, Equatable {
    public let reportId: String
    public let linearIdentifier: String
    public let linearUrl: String
    public let isMock: Bool
    public let missionId: String?

    public init(
        reportId: String,
        linearIdentifier: String,
        linearUrl: String,
        isMock: Bool = false,
        missionId: String? = nil
    ) {
        self.reportId = reportId
        self.linearIdentifier = linearIdentifier
        self.linearUrl = linearUrl
        self.isMock = isMock
        self.missionId = missionId
    }
}

public enum MobileBugReportService {
    private static let logger = Logger(subsystem: "com.openburnbar.mobile", category: "MobileBugReportService")

    public static func submit(
        _ submission: MobileBugReportSubmission,
        functions: Functions = Functions.functions(region: "us-central1")
    ) async throws -> MobileBugReportSubmissionResult {
        var payload: [String: Any] = [
            "title": submission.title,
            "description": submission.description,
            "platform": submission.platform,
            "autoDispenseCLI": submission.autoDispenseCLI,
        ]

        if let v = submission.appVersion { payload["appVersion"] = v }
        if let v = submission.osVersion { payload["osVersion"] = v }
        if let v = submission.deviceModel { payload["deviceModel"] = v }
        if let d = submission.diagnostics { payload["diagnostics"] = d }
        if let l = submission.logsSnippet { payload["logsSnippet"] = l }
        if let s = submission.screenshotBase64 { payload["screenshotBase64"] = s }
        if let r = submission.requestedRuntime { payload["requestedRuntime"] = r }
        if let t = submission.targetProject { payload["targetProject"] = t }

        logger.info("Submitting mobile bug report: '\(submission.title, privacy: .public)'")

        let result = try await functions.httpsCallable("submitBugReport").call(payload)
        guard let data = result.data as? [String: Any] else {
            throw NSError(
                domain: "MobileBugReportService",
                code: -1,
                userInfo: [NSLocalizedDescriptionKey: "Invalid response from server."]
            )
        }

        let reportId = data["reportId"] as? String ?? ""
        let missionId = data["missionId"] as? String
        let linear = data["linearIssue"] as? [String: Any] ?? [:]
        let identifier = linear["identifier"] as? String ?? "BB-ISSUE"
        let url = linear["url"] as? String ?? "https://linear.app"
        let isMock = linear["mock"] as? Bool ?? false

        logger.info("Mobile bug report submitted successfully. Linear issue: \(identifier, privacy: .public)")

        return MobileBugReportSubmissionResult(
            reportId: reportId,
            linearIdentifier: identifier,
            linearUrl: url,
            isMock: isMock,
            missionId: missionId
        )
    }
}
