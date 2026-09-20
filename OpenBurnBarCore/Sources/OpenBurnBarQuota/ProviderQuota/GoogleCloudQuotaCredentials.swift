import Foundation
import OpenBurnBarKernel

#if canImport(FoundationNetworking)
import FoundationNetworking
#endif

/// Google Cloud identity that can read project quota remaining.
///
/// Highest-confidence Phase-2 path: Application Default Credentials already
/// on the Mac, a pasted service-account / ADC JSON, or `gcloud`. BurnBar does
/// not invent an OAuth client ID. AI Studio `AIza…` keys and Firebase Google
/// sign-in are not remaining-quota credentials.
public struct GoogleCloudQuotaIdentity: Equatable, Sendable {
    public enum Source: String, Sendable {
        case injected
        case authorizedUserADC
        case serviceAccount
        case gcloudCLI
    }

    public let accessToken: String
    public let projectID: String
    public let source: Source

    public init(accessToken: String, projectID: String, source: Source) {
        self.accessToken = accessToken
        self.projectID = projectID
        self.source = source
    }
}

public enum GoogleCloudQuotaCredentialError: Error, Equatable, Sendable {
    case missing
    case aiStudioKeyRejected
    case missingProject
    case refreshFailed(String)
    case invalidJSON(String)

    public var statusMessage: String {
        switch self {
        case .missing:
            return "Remaining Gemini API / Vertex project quotas need Google Cloud ADC or a service account. An AI Studio key and Gemini app / Verizon login cannot read remaining."
        case .aiStudioKeyRejected:
            return "An AI Studio API key cannot read remaining RPD, RPM, or TPM. Connect Google Cloud ADC or a service account JSON instead."
        case .missingProject:
            return "Google Cloud credentials are present, but no project id was found. Set a quota project (`gcloud auth application-default set-quota-project PROJECT_ID`) or add GOOGLE_CLOUD_PROJECT."
        case .refreshFailed(let detail):
            return "Google Cloud credentials were rejected: \(detail)"
        case .invalidJSON(let detail):
            return "Google Cloud credential JSON was not usable: \(detail)"
        }
    }
}

public enum GoogleCloudQuotaCredentialResolver: Sendable {
    public static let serviceAccountAccount = "provider.google.serviceAccount"
    public static let tokenAccount = "provider.google.cloudAccessToken"
    public static let projectAccount = "provider.google.cloudProject"

    public static let generativeLanguageService = "generativelanguage.googleapis.com"
    public static let vertexService = "aiplatform.googleapis.com"
    public static let tokenURL = URL(string: "https://oauth2.googleapis.com/token")!
    public static let cloudPlatformScope = "https://www.googleapis.com/auth/cloud-platform"

    /// Resolve a Google Cloud identity without inventing OAuth clients.
    public static func resolve(
        context: ProviderQuotaAdapterContext,
        extraProjectIDs: [String] = []
    ) async -> Result<GoogleCloudQuotaIdentity, GoogleCloudQuotaCredentialError> {
        let projectHint = firstProjectID(
            extraProjectIDs
                + projectHints(from: context)
        )

        if let injected = injectedIdentity(context: context, projectHint: projectHint) {
            return injected
        }

        if let json = credentialJSON(from: context) {
            return await identity(fromJSON: json, context: context, projectHint: projectHint)
        }

        if let adcURL = adcFileURL(context: context),
           let data = try? Data(contentsOf: adcURL),
           let text = String(data: data, encoding: .utf8) {
            return await identity(fromJSON: text, context: context, projectHint: projectHint)
        }

        if let viaGcloud = gcloudIdentity(context: context, projectHint: projectHint) {
            return viaGcloud
        }

        return .failure(.missing)
    }

    static func looksLikeAIStudioKey(_ raw: String) -> Bool {
        raw.trimmingCharacters(in: .whitespacesAndNewlines).hasPrefix("AIza")
    }

    static func firstProjectID(_ candidates: [String]) -> String? {
        for candidate in candidates {
            if let value = quotaNonEmpty(candidate), isPlausibleProjectID(value) {
                return value
            }
        }
        return nil
    }

    static func isPlausibleProjectID(_ raw: String) -> Bool {
        let value = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard (6...30).contains(value.count) else { return false }
        if value.allSatisfy(\.isNumber) {
            return true
        }
        return value.range(of: "^[a-z][a-z0-9-]+$", options: .regularExpression) != nil
    }

    static func parseCredentialObject(_ raw: String) -> [String: Any]? {
        let trimmed = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        guard let data = trimmed.data(using: .utf8),
              let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any] else {
            return nil
        }
        return object
    }

    static func credentialType(of object: [String: Any]) -> String {
        (object["type"] as? String)?.trimmingCharacters(in: .whitespacesAndNewlines).lowercased() ?? ""
    }

    static func projectID(in object: [String: Any]) -> String? {
        firstProjectID([
            object["quota_project_id"] as? String ?? "",
            object["quotaProjectId"] as? String ?? "",
            object["project_id"] as? String ?? "",
            object["projectId"] as? String ?? ""
        ])
    }

    static func projectID(fromGeminiSettings object: [String: Any]) -> String? {
        var candidates: [String] = [
            object["googleCloudProject"] as? String ?? "",
            object["googleCloudProjectId"] as? String ?? "",
            object["gcpProject"] as? String ?? "",
            object["projectId"] as? String ?? "",
            object["project"] as? String ?? ""
        ]
        for nestKey in ["vertexai", "vertex", "cloud", "gcp", "security"] {
            if let nested = object[nestKey] as? [String: Any] {
                candidates.append(contentsOf: [
                    nested["project"] as? String ?? "",
                    nested["projectId"] as? String ?? "",
                    nested["googleCloudProject"] as? String ?? ""
                ])
                if let auth = nested["auth"] as? [String: Any] {
                    candidates.append(contentsOf: [
                        auth["project"] as? String ?? "",
                        auth["projectId"] as? String ?? ""
                    ])
                }
            }
        }
        return firstProjectID(candidates)
    }

    static func projectID(fromGCloudConfig text: String) -> String? {
        var inCore = false
        for rawLine in text.split(whereSeparator: \.isNewline) {
            let line = rawLine.trimmingCharacters(in: .whitespaces)
            if line.hasPrefix("[") && line.hasSuffix("]") {
                inCore = line.lowercased() == "[core]"
                continue
            }
            guard inCore else { continue }
            let parts = line.split(separator: "=", maxSplits: 1).map {
                $0.trimmingCharacters(in: .whitespaces)
            }
            if parts.count == 2, parts[0] == "project" {
                return firstProjectID([parts[1]])
            }
        }
        return nil
    }

    private static func injectedIdentity(
        context: ProviderQuotaAdapterContext,
        projectHint: String?
    ) -> Result<GoogleCloudQuotaIdentity, GoogleCloudQuotaCredentialError>? {
        guard let token = firstNonEmpty([
            context.resolvedAPIKeys["google_cloud_access_token"] ?? nil,
            context.resolvedAPIKeys["google-cloud-access-token"] ?? nil,
            context.cursorConnectorCredential(for: tokenAccount),
            context.environment["GOOGLE_CLOUD_ACCESS_TOKEN"],
            context.environment["CLOUDSDK_AUTH_ACCESS_TOKEN"]
        ]) else {
            return nil
        }
        if looksLikeAIStudioKey(token) {
            return .failure(.aiStudioKeyRejected)
        }
        guard let project = projectHint else {
            return .failure(.missingProject)
        }
        return .success(GoogleCloudQuotaIdentity(accessToken: token, projectID: project, source: .injected))
    }

    private static func credentialJSON(from context: ProviderQuotaAdapterContext) -> String? {
        firstNonEmpty([
            context.resolvedAPIKeys["google_cloud_service_account"] ?? nil,
            context.resolvedAPIKeys["google-cloud-service-account"] ?? nil,
            context.cursorConnectorCredential(for: serviceAccountAccount),
            environmentFileContents(context.environment["GOOGLE_APPLICATION_CREDENTIALS"])
        ])
    }

    private static func identity(
        fromJSON raw: String,
        context: ProviderQuotaAdapterContext,
        projectHint: String?
    ) async -> Result<GoogleCloudQuotaIdentity, GoogleCloudQuotaCredentialError> {
        if looksLikeAIStudioKey(raw) {
            return .failure(.aiStudioKeyRejected)
        }
        guard let object = parseCredentialObject(raw) else {
            return .failure(.invalidJSON("the payload is not a JSON object"))
        }

        let type = credentialType(of: object)
        let project = firstProjectID([projectHint ?? "", projectID(in: object) ?? ""])
        guard let project else {
            return .failure(.missingProject)
        }

        if type == "authorized_user" {
            return await refreshAuthorizedUser(object, projectID: project, context: context)
        }
        if type == "service_account" {
            return serviceAccountViaGCloud(json: raw, projectID: project, context: context)
        }
        return .failure(.invalidJSON("expected type service_account or authorized_user, got \(type.isEmpty ? "missing" : type)"))
    }

    private static func refreshAuthorizedUser(
        _ object: [String: Any],
        projectID: String,
        context: ProviderQuotaAdapterContext
    ) async -> Result<GoogleCloudQuotaIdentity, GoogleCloudQuotaCredentialError> {
        guard let refreshToken = quotaNonEmpty(object["refresh_token"] as? String),
              let clientID = quotaNonEmpty(object["client_id"] as? String),
              let clientSecret = quotaNonEmpty(object["client_secret"] as? String) else {
            return .failure(.invalidJSON("authorized_user ADC is missing refresh_token, client_id, or client_secret"))
        }

        var request = URLRequest(url: tokenURL)
        request.httpMethod = "POST"
        request.setValue("application/x-www-form-urlencoded", forHTTPHeaderField: "Content-Type")
        request.httpBody = formBody([
            "grant_type": "refresh_token",
            "refresh_token": refreshToken,
            "client_id": clientID,
            "client_secret": clientSecret
        ])

        do {
            let (data, response) = try await context.session.data(for: request)
            let status = (response as? HTTPURLResponse)?.statusCode ?? -1
            guard (200..<300).contains(status),
                  let payload = try JSONSerialization.jsonObject(with: data) as? [String: Any],
                  let accessToken = quotaNonEmpty(payload["access_token"] as? String) else {
                let detail = String(data: data, encoding: .utf8) ?? "HTTP \(status)"
                if let viaCLI = gcloudIdentity(context: context, projectHint: projectID) {
                    return viaCLI
                }
                return .failure(.refreshFailed(truncated(detail)))
            }
            return .success(
                GoogleCloudQuotaIdentity(
                    accessToken: accessToken,
                    projectID: projectID,
                    source: .authorizedUserADC
                )
            )
        } catch {
            if let viaCLI = gcloudIdentity(context: context, projectHint: projectID) {
                return viaCLI
            }
            return .failure(.refreshFailed(error.localizedDescription))
        }
    }

    private static func serviceAccountViaGCloud(
        json: String,
        projectID: String,
        context: ProviderQuotaAdapterContext
    ) -> Result<GoogleCloudQuotaIdentity, GoogleCloudQuotaCredentialError> {
        let directory = context.appPaths.applicationSupportRoot
            .appendingPathComponent("google-cloud-quota", isDirectory: true)
        do {
            try context.fileManager.createDirectory(at: directory, withIntermediateDirectories: true)
            let file = directory.appendingPathComponent("service-account.json")
            try Data(json.utf8).write(to: file, options: .atomic)
            return gcloudIdentity(
                context: context,
                projectHint: projectID,
                extraEnvironment: [
                    "GOOGLE_APPLICATION_CREDENTIALS": file.path,
                    "CLOUDSDK_AUTH_CREDENTIAL_FILE_OVERRIDE": file.path,
                    "CLOUDSDK_CORE_PROJECT": projectID
                ],
                source: .serviceAccount
            ) ?? .failure(.refreshFailed(
                "service account JSON is on file, but gcloud could not mint an access token. Install the Google Cloud SDK or run `gcloud auth application-default login`."
            ))
        } catch {
            return .failure(.refreshFailed(error.localizedDescription))
        }
    }

    private static func gcloudIdentity(
        context: ProviderQuotaAdapterContext,
        projectHint: String?,
        extraEnvironment: [String: String] = [:],
        source: GoogleCloudQuotaIdentity.Source = .gcloudCLI
    ) -> Result<GoogleCloudQuotaIdentity, GoogleCloudQuotaCredentialError>? {
        var environment = context.environment
        for (key, value) in extraEnvironment {
            environment[key] = value
        }
        let executables = gcloudExecutables(environment: environment)
        var lastError: String?
        for executable in executables {
            do {
                let tokenData = try context.cliExecutor.run(
                    executable: executable,
                    arguments: ["auth", "application-default", "print-access-token"],
                    environment: environment
                )
                let token = String(data: tokenData, encoding: .utf8)?
                    .trimmingCharacters(in: .whitespacesAndNewlines) ?? ""
                guard !token.isEmpty, !looksLikeAIStudioKey(token) else { continue }
                let project = projectHint
                    ?? gcloudConfigProject(context: context, executable: executable, environment: environment)
                guard let project else {
                    return .failure(.missingProject)
                }
                return .success(GoogleCloudQuotaIdentity(accessToken: token, projectID: project, source: source))
            } catch {
                lastError = error.localizedDescription
            }
        }
        if source == .serviceAccount, let lastError {
            return .failure(.refreshFailed(truncated(lastError)))
        }
        return nil
    }

    private static func gcloudConfigProject(
        context: ProviderQuotaAdapterContext,
        executable: String,
        environment: [String: String]
    ) -> String? {
        if let data = try? context.cliExecutor.run(
            executable: executable,
            arguments: ["config", "get-value", "project"],
            environment: environment
        ), let value = firstProjectID([String(data: data, encoding: .utf8) ?? ""]) {
            return value
        }
        return projectHints(from: context).first
    }

    private static func projectHints(from context: ProviderQuotaAdapterContext) -> [String] {
        var hints: [String] = [
            context.resolvedAPIKeys["google_cloud_project"] ?? nil,
            context.resolvedAPIKeys["google-cloud-project"] ?? nil,
            context.cursorConnectorCredential(for: projectAccount),
            context.environment["GOOGLE_CLOUD_PROJECT"],
            context.environment["GCLOUD_PROJECT"],
            context.environment["GOOGLE_CLOUD_QUOTA_PROJECT"]
        ].compactMap { quotaNonEmpty($0) }

        let geminiSettings = context.homeDirectoryURL
            .appendingPathComponent(".gemini/settings.json")
        if let data = try? Data(contentsOf: geminiSettings),
           let object = try? JSONSerialization.jsonObject(with: data) as? [String: Any],
           let project = projectID(fromGeminiSettings: object) {
            hints.append(project)
        }

        let configURL = gcloudConfigRoot(context: context)
            .appendingPathComponent("configurations/config_default")
        if let text = try? String(contentsOf: configURL, encoding: .utf8),
           let project = projectID(fromGCloudConfig: text) {
            hints.append(project)
        }
        return hints
    }

    private static func adcFileURL(context: ProviderQuotaAdapterContext) -> URL? {
        let override = quotaNonEmpty(context.environment["CLOUDSDK_CONFIG"])
        let root = override.map { URL(fileURLWithPath: $0, isDirectory: true) }
            ?? gcloudConfigRoot(context: context)
        let url = root.appendingPathComponent("application_default_credentials.json")
        return context.fileManager.fileExists(atPath: url.path) ? url : nil
    }

    private static func gcloudConfigRoot(context: ProviderQuotaAdapterContext) -> URL {
        if let override = quotaNonEmpty(context.environment["CLOUDSDK_CONFIG"]) {
            return URL(fileURLWithPath: override, isDirectory: true)
        }
        return context.homeDirectoryURL.appendingPathComponent(".config/gcloud", isDirectory: true)
    }

    private static func gcloudExecutables(environment: [String: String]) -> [String] {
        var paths = [
            "/opt/homebrew/bin/gcloud",
            "/usr/local/bin/gcloud",
            "/usr/bin/gcloud"
        ]
        if let path = environment["PATH"] {
            for directory in path.split(separator: ":") {
                paths.append("\(directory)/gcloud")
            }
        }
        paths.append("gcloud")
        var seen = Set<String>()
        return paths.filter { seen.insert($0).inserted }
    }

    private static func environmentFileContents(_ path: String?) -> String? {
        guard let path = quotaNonEmpty(path),
              let data = try? Data(contentsOf: URL(fileURLWithPath: path)),
              let text = String(data: data, encoding: .utf8) else {
            return nil
        }
        return quotaNonEmpty(text)
    }

    private static func firstNonEmpty(_ values: [String?]) -> String? {
        for value in values {
            if let trimmed = quotaNonEmpty(value) {
                return trimmed
            }
        }
        return nil
    }

    private static func formBody(_ fields: [String: String]) -> Data {
        let allowed = CharacterSet.urlQueryAllowed.subtracting(CharacterSet(charactersIn: "&+=?"))
        let pairs = fields.map { key, value in
            let encodedKey = key.addingPercentEncoding(withAllowedCharacters: allowed) ?? key
            let encodedValue = value.addingPercentEncoding(withAllowedCharacters: allowed) ?? value
            return "\(encodedKey)=\(encodedValue)"
        }
        return Data(pairs.joined(separator: "&").utf8)
    }

    private static func truncated(_ raw: String) -> String {
        let collapsed = raw
            .replacingOccurrences(of: "\n", with: " ")
            .trimmingCharacters(in: .whitespacesAndNewlines)
        if collapsed.count <= 180 {
            return collapsed
        }
        return String(collapsed.prefix(180)) + "…"
    }
}
