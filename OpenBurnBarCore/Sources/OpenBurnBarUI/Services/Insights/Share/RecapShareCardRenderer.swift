import ImageIO
import SwiftUI
import UniformTypeIdentifiers
import OpenBurnBarInsights
import OpenBurnBarRecap
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AppKit)
import AppKit
#endif

/// Turns one recap card into a standalone image.
///
/// "Standalone" is the whole point: the shared artefact is **re-composed** for
/// its frame, not a screenshot of the on-screen card. Someone who sees it in a
/// group chat has none of the surrounding app, so the image has to carry the
/// month, the claim, the number and the source by itself.
///
/// Extends `InsightShareCardRenderer` rather than replacing it — that type
/// already fixed the formats and the platform colour plumbing, but stopped at
/// layout constants and never grew a bitmap path. This is that path.
@MainActor
public struct RecapShareCardRenderer {

    public typealias Format = InsightShareCardRenderer.CardFormat

    private let layoutSource = InsightShareCardRenderer()

    public init() {}

    // MARK: - Rendering

    /// Renders `card` as PNG data, or nil if the renderer produced no image.
    ///
    /// The colour scheme is set explicitly rather than inherited: an export
    /// should not come out light because the window happened to be.
    public func png(
        card: RecapCard,
        window: RecapWindow,
        format: Format = .portrait1080x1350,
        colorScheme: ColorScheme = .dark,
        isPartial: Bool = false
    ) -> Data? {
        let layout = layoutSource.layout(for: format, isDark: colorScheme == .dark)
        return render(
            RecapShareCardView(
                card: card,
                window: window,
                width: layout.width,
                height: layout.height,
                isPartial: isPartial
            ),
            layout: layout,
            colorScheme: colorScheme
        )
    }

    /// Renders the closing summary as a shareable image.
    public func png(
        recap: MonthlyRecap,
        format: Format = .square1080x1080,
        colorScheme: ColorScheme = .dark
    ) -> Data? {
        let layout = layoutSource.layout(for: format, isDark: colorScheme == .dark)
        return render(
            RecapShareSummaryView(
                recap: recap,
                width: layout.width,
                height: layout.height,
                isPartial: recap.isPartial
            ),
            layout: layout,
            colorScheme: colorScheme
        )
    }

    /// A filename someone can find again later.
    ///
    /// Card ids embed their subject, which can include a project name, so every
    /// character that could redirect a write — separators, colons, dots — is
    /// folded to a dash rather than only the colon.
    public func suggestedFilename(for window: RecapWindow, cardID: String? = nil) -> String {
        let suffix = cardID.map { "-" + Self.sanitize($0) } ?? ""
        return "burnbar-recap-\(window.key)\(suffix).png"
    }

    static func sanitize(_ raw: String) -> String {
        let allowed = CharacterSet.alphanumerics.union(CharacterSet(charactersIn: "-_"))
        let folded = String(raw.unicodeScalars.map { allowed.contains($0) ? Character($0) : "-" })
        // Collapse runs and trim so "a//b" cannot become "a--b-".
        let collapsed = folded.split(separator: "-", omittingEmptySubsequences: true).joined(separator: "-")
        return String(collapsed.prefix(80))
    }

    // MARK: - Rendering

    /// The colour scheme is set explicitly rather than inherited: an export
    /// should not come out light because the window happened to be.
    private func render<Content: View>(
        _ view: Content,
        layout: InsightShareCardRenderer.CardLayout,
        colorScheme: ColorScheme
    ) -> Data? {
        let renderer = ImageRenderer(content: view.environment(\.colorScheme, colorScheme))
        renderer.proposedSize = ProposedViewSize(width: layout.width, height: layout.height)
        // The layout is already in export pixels, so scale 1 keeps 1080×1350
        // meaning 1080×1350 rather than silently tripling it.
        renderer.scale = 1
        renderer.isOpaque = true

        // Straight from the CGImage. Going via `nsImage.tiffRepresentation`
        // materializes an uncompressed ~5.8 MB buffer first, on the main thread,
        // for no benefit.
        guard let image = renderer.cgImage else { return nil }
        let data = NSMutableData()
        guard let destination = CGImageDestinationCreateWithData(
            data, "public.png" as CFString, 1, nil
        ) else { return nil }
        CGImageDestinationAddImage(destination, image, nil)
        guard CGImageDestinationFinalize(destination) else { return nil }
        return data as Data
    }
}
