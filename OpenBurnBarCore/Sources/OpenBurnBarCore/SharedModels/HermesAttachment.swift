import Foundation

// MARK: - Hermes Attachment Model

/// Categorisation that drives wire-format encoding decisions. The same
/// classification is used on macOS, iOS and iPadOS so attachments roundtrip
/// identically across the OpenBurnBar surfaces.
public enum HermesAttachmentKind: String, Codable, Sendable, Hashable {
    /// Bitmap images (jpg/png/heic/gif/webp). Encoded as `image_url` data URLs
    /// for vision-capable backends.
    case image
    /// Plain-text-like documents (txt/md/log/csv/json/yaml/xml + source code).
    /// Inlined into the prompt as additional `text` parts when small enough.
    case textDocument
    /// PDFs. Rasterized to images for vision backends, or attached as a
    /// workspace path reference when vision is unavailable.
    case pdf
    /// Audio recordings (m4a/mp3/wav/aiff). Encoded as `input_audio` parts on
    /// backends that announce audio capability; otherwise sent as a workspace
    /// reference.
    case audio
    /// Video clips (mov/mp4). Always sent as a workspace path reference.
    case video
    /// Anything else — sent as a workspace path reference + name/byte size in
    /// the prompt.
    case generic
}

/// User-attached file metadata captured by the chat composer. Binary contents
/// live on disk in the chat workspace; the metadata is what the runtime hands
/// to the encoder and what gets persisted with the chat transcript.
public struct HermesAttachment: Identifiable, Codable, Sendable, Hashable {
    /// Stable UUID — also forms the filename stem inside the workspace folder.
    public var id: String
    public var kind: HermesAttachmentKind
    /// User-facing filename (e.g. `screenshot.png`).
    public var displayName: String
    public var mimeType: String
    /// Size of the underlying file on disk, in bytes.
    public var byteSize: Int
    /// Path relative to the per-thread workspace root (e.g.
    /// `attachments/<id>-screenshot.png`).
    public var workspaceRelativePath: String
    /// Optional 96×96 PNG thumbnail used by the chip + transcript renderer.
    public var thumbnailPNG: Data?
    /// First 4 KB of decoded text for `textDocument` / inline-friendly types,
    /// used both for chip preview and as a fallback when the encoder cannot
    /// load the full file at send-time.
    public var extractedTextPreview: String?

    public init(
        id: String = UUID().uuidString,
        kind: HermesAttachmentKind,
        displayName: String,
        mimeType: String,
        byteSize: Int,
        workspaceRelativePath: String,
        thumbnailPNG: Data? = nil,
        extractedTextPreview: String? = nil
    ) {
        self.id = id
        self.kind = kind
        self.displayName = displayName
        self.mimeType = mimeType
        self.byteSize = byteSize
        self.workspaceRelativePath = workspaceRelativePath
        self.thumbnailPNG = thumbnailPNG
        self.extractedTextPreview = extractedTextPreview
    }

    /// Approximate token cost when this attachment is included in a request.
    /// Used by the composer to surface a "spend hint" next to the chip.
    public var estimatedTokenCost: Int {
        switch kind {
        case .image:
            return 1500
        case .pdf:
            // Rough: ~1 image part per page, average 2 pages.
            return 3000
        case .audio:
            // Audio cost depends heavily on duration; flat conservative estimate.
            return 2000
        case .textDocument:
            if let preview = extractedTextPreview {
                return max(1, preview.count / 4)
            }
            return max(1, byteSize / 4)
        case .video, .generic:
            // Workspace ref only — costs roughly one path-string of tokens.
            return 32
        }
    }
}

// MARK: - Backend capabilities

/// Capability flags surfaced from `/v1/models` (when the backend exposes
/// them) or inferred from the chosen connection. The encoder degrades the
/// wire format when the active backend cannot accept multimodal content.
public struct HermesBackendCapabilities: Codable, Sendable, Hashable {
    public var vision: Bool
    public var audio: Bool

    public init(vision: Bool = true, audio: Bool = false) {
        self.vision = vision
        self.audio = audio
    }

    /// Conservative defaults used when probing fails or the backend doesn't
    /// announce capabilities. Vision is left on because most modern Hermes /
    /// OpenAI-compatible gateways now accept `image_url`; the encoder
    /// gracefully degrades on a 4xx response.
    public static let `default` = HermesBackendCapabilities(vision: true, audio: false)

    public static let textOnly = HermesBackendCapabilities(vision: false, audio: false)
}

// MARK: - Attachment caps

/// Per-attachment byte ceilings shared by the macOS and mobile composers so
/// the user-visible "too large" chip text stays in sync.
public enum HermesAttachmentLimits {
    public static let maxImageBytes = 20 * 1024 * 1024          // 20 MB
    public static let maxInlineTextBytes = 64 * 1024            // 64 KB inlined as `text` part
    public static let maxTextDocumentBytes = 2 * 1024 * 1024    // 2 MB total accepted
    public static let maxAudioBytes = 25 * 1024 * 1024          // 25 MB
    public static let maxGenericBytes = 200 * 1024 * 1024       // 200 MB workspace ref
    public static let textPreviewBytes = 4 * 1024               // 4 KB shown on chip
}
