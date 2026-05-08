import SwiftUI
import OpenBurnBarCore

// MARK: - StreamingBubble (iOS)
//
// Wraps an assistant message in a frame that:
//   - Re-measures via Pretext on every chunk while `isStreaming` is true.
//   - Animates `frame(height:)` between snapshots with an easeOut spring.
//   - On completion, runs `shrinkWrapWidth` and animates `frame(width:)`
//     down to the tightest comfortable width.
//
// We never block rendering on Pretext readiness: the inner `content` view
// keeps drawing, only the bubble's outer frame is animated. This is the
// "stable container" property — the user sees text materialize inside a
// bubble whose dimensions move smoothly, instead of the whole tree
// reflowing on every chunk.
//
// The `content` is parameterized so the same wrapper works for both the
// HermesTabView bubble and the ChatView bubble.

struct StreamingBubble<Content: View>: View {
    /// Source text — used as the measurement input. The wrapped `content`
    /// is what actually renders the text; the wrapper only sizes around it.
    let text: String
    /// `true` while the message is still streaming.
    let isStreaming: Bool
    /// `true` for error messages — disables shrink-wrap so error styling
    /// doesn't get squeezed.
    let isError: Bool
    /// Body font size in points — must match the wrapped content's font.
    let baseSize: CGFloat
    /// Line height — must match the wrapped content's line height.
    let lineHeight: CGFloat
    /// Target line count for shrink-wrap. Default `4` keeps short answers
    /// tight without forcing long answers into uncomfortable widths.
    let shrinkTargetLines: Int
    /// The actual content view (typically `HermesRichBubble` or a `Text`).
    @ViewBuilder var content: () -> Content

    init(
        text: String,
        isStreaming: Bool,
        isError: Bool,
        baseSize: CGFloat = 15,
        lineHeight: CGFloat = 21,
        shrinkTargetLines: Int = 4,
        @ViewBuilder content: @escaping () -> Content
    ) {
        self.text = text
        self.isStreaming = isStreaming
        self.isError = isError
        self.baseSize = baseSize
        self.lineHeight = lineHeight
        self.shrinkTargetLines = shrinkTargetLines
        self.content = content
    }

    @State private var measuredHeight: CGFloat? = nil
    @State private var measuredWidth: CGFloat? = nil
    @State private var lastMeasuredText: String = ""

    var body: some View {
        GeometryReader { proxy in
            content()
                .frame(maxWidth: measuredWidth ?? proxy.size.width, alignment: .leading)
                .task(id: measureTrigger(width: proxy.size.width)) {
                    await measure(at: proxy.size.width)
                }
        }
        // Animate the outer frame; `content()` itself stays unanimated to
        // avoid double-easing the in-flight text.
        .frame(height: measuredHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: measuredHeight)
        .animation(.spring(response: 0.32, dampingFraction: 0.86), value: measuredWidth)
    }

    // MARK: - Measurement

    /// Stable trigger so `task(id:)` re-fires on text growth, completion,
    /// or width changes. Strings hash cheaply; the measurement itself is
    /// what guards against redundant work via PretextEngine's prepared
    /// cache.
    private func measureTrigger(width: CGFloat) -> String {
        // Bucket the streaming-text trigger by 32-character chunks so
        // very-fast SSE bursts don't queue dozens of bridge calls. The
        // engine still runs once per bucket — typically every 6-8 lines.
        let bucket = isStreaming ? text.count / 32 : -1
        return "\(text.hashValue)|\(width)|\(isStreaming ? 1 : 0)|\(isError ? 1 : 0)|\(baseSize)|\(lineHeight)|\(bucket)"
    }

    private func measure(at width: CGFloat) async {
        guard width > 0, !text.isEmpty else { return }
        let canvasFont = "400 \(Int(baseSize))px -apple-system"
        do {
            let engine = PretextEngine.shared
            let prepared = try await engine.prepare(text: text, font: canvasFont)
            let layout = try await engine.layout(
                handle: prepared,
                maxWidth: width,
                lineHeight: lineHeight
            )
            await MainActor.run {
                self.measuredHeight = layout.height
                self.lastMeasuredText = text
            }

            // Shrink-wrap once streaming completes, on non-error messages.
            if !isStreaming && !isError {
                let preparedSegments = try await engine.prepareWithSegments(text: text, font: canvasFont)
                let tightest = try await engine.shrinkWrapWidth(
                    handle: preparedSegments,
                    upper: width,
                    targetLines: shrinkTargetLines
                )
                let finalLayout = try await engine.layoutWithLines(
                    handle: preparedSegments,
                    maxWidth: tightest,
                    lineHeight: lineHeight
                )
                await MainActor.run {
                    self.measuredWidth = tightest
                    self.measuredHeight = finalLayout.height
                }
            } else if isStreaming {
                // While streaming, never narrow the bubble — let it use the
                // full available width so the user sees the full chunk on
                // every frame.
                await MainActor.run {
                    self.measuredWidth = nil
                }
            }
        } catch {
            // Engine unavailable — let SwiftUI lay out content() naturally.
        }
    }
}
