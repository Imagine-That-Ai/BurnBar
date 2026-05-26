import Foundation

public struct ModelCapabilitySourceRef: Codable, Hashable, Sendable {
    public var label: String
    public var url: URL?
    public var fetchedAt: Date?

    public init(label: String, url: URL? = nil, fetchedAt: Date? = nil) {
        self.label = label
        self.url = url
        self.fetchedAt = fetchedAt
    }
}

public struct ModelIOCapabilities: Codable, Hashable, Sendable {
    public var schemaVersion: Int
    public var inputModalities: [String]
    public var outputModalities: [String]
    public var supportedParameters: [String]
    public var contextWindowTokens: Int?
    public var maxOutputTokens: Int?
    public var acceptedInputMimeTypes: [String]
    public var imageMaxBytes: Int?
    public var audioMaxBytes: Int?
    public var videoMaxBytes: Int?
    public var sourceRefs: [ModelCapabilitySourceRef]

    public init(
        schemaVersion: Int = 1,
        inputModalities: [String] = ["text"],
        outputModalities: [String] = ["text"],
        supportedParameters: [String] = [],
        contextWindowTokens: Int? = nil,
        maxOutputTokens: Int? = nil,
        acceptedInputMimeTypes: [String] = [],
        imageMaxBytes: Int? = nil,
        audioMaxBytes: Int? = nil,
        videoMaxBytes: Int? = nil,
        sourceRefs: [ModelCapabilitySourceRef] = []
    ) {
        self.schemaVersion = max(1, schemaVersion)
        self.inputModalities = Self.normalizedList(inputModalities, fallback: ["text"])
        self.outputModalities = Self.normalizedList(outputModalities, fallback: ["text"])
        self.supportedParameters = Self.normalizedList(supportedParameters, fallback: [])
        self.contextWindowTokens = contextWindowTokens.flatMap { $0 > 0 ? $0 : nil }
        self.maxOutputTokens = maxOutputTokens.flatMap { $0 > 0 ? $0 : nil }
        self.acceptedInputMimeTypes = Self.normalizedMimeTypes(acceptedInputMimeTypes)
        self.imageMaxBytes = imageMaxBytes.flatMap { $0 > 0 ? $0 : nil }
        self.audioMaxBytes = audioMaxBytes.flatMap { $0 > 0 ? $0 : nil }
        self.videoMaxBytes = videoMaxBytes.flatMap { $0 > 0 ? $0 : nil }
        self.sourceRefs = sourceRefs
    }

    public var supportsImageInput: Bool {
        supportsInputModality("image")
    }

    public var supportsAudioInput: Bool {
        supportsInputModality("audio")
    }

    public var supportsVideoInput: Bool {
        supportsInputModality("video")
    }

    public var supportsPDFInput: Bool {
        supportsInputModality("pdf") || acceptsInputMimeType("application/pdf")
    }

    public func supportsInputModality(_ modality: String) -> Bool {
        let normalized = modality.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
        guard !normalized.isEmpty else { return false }
        return inputModalities.contains(normalized)
    }

    public func acceptsInputMimeType(_ mimeType: String?) -> Bool {
        guard let normalized = Self.normalizedMimeType(mimeType) else { return false }
        guard !acceptedInputMimeTypes.isEmpty else {
            if normalized.hasPrefix("image/") {
                return supportsImageInput
            }
            if normalized.hasPrefix("audio/") {
                return supportsAudioInput
            }
            if normalized.hasPrefix("video/") {
                return supportsVideoInput
            }
            return normalized == "application/pdf" && supportsPDFInput
        }
        return acceptedInputMimeTypes.contains { accepted in
            if accepted.hasSuffix("/*") {
                let prefix = String(accepted.dropLast(1))
                return normalized.hasPrefix(prefix)
            }
            return accepted == normalized
        }
    }

    public var asHermesBackendCapabilities: HermesBackendCapabilities {
        HermesBackendCapabilities(
            vision: supportsImageInput || supportsPDFInput,
            audio: supportsAudioInput,
            modelIO: self
        )
    }

    public static let textOnly = ModelIOCapabilities(
        inputModalities: ["text"],
        outputModalities: ["text"]
    )

    public static let openAICompatibleVision = ModelIOCapabilities(
        inputModalities: ["text", "image"],
        outputModalities: ["text"],
        acceptedInputMimeTypes: ["image/*"]
    )

    private static func normalizedList(_ values: [String], fallback: [String]) -> [String] {
        var seen: Set<String> = []
        let normalized = values.compactMap { value -> String? in
            let trimmed = value.trimmingCharacters(in: .whitespacesAndNewlines).lowercased()
            guard !trimmed.isEmpty, seen.insert(trimmed).inserted else { return nil }
            return trimmed
        }
        return normalized.isEmpty ? fallback : normalized
    }

    private static func normalizedMimeTypes(_ values: [String]) -> [String] {
        var seen: Set<String> = []
        return values.compactMap { value -> String? in
            guard let normalized = normalizedMimeType(value),
                  seen.insert(normalized).inserted else {
                return nil
            }
            return normalized
        }
    }

    private static func normalizedMimeType(_ value: String?) -> String? {
        guard let value else { return nil }
        let mimeType = value
            .split(separator: ";", maxSplits: 1, omittingEmptySubsequences: true)
            .first
            .map(String.init)?
            .trimmingCharacters(in: .whitespacesAndNewlines)
            .lowercased()
        return mimeType?.isEmpty == false ? mimeType : nil
    }
}
