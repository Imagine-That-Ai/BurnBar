# Hermes TPS UI Handoff

## Goal

Add an opt-in Hermes chat metric that shows generation speed at the bottom of assistant messages:

`12.4 tok/s`

The backend contract is already in `OpenBurnBarMobile/Services/HermesService.swift`. The UI should only render the provided message metadata; it should not parse usage events, estimate tokens, or calculate timing itself.

## Backend Contract

`HermesChatMessage` now exposes:

- `tokensPerSecond: Double?`
- `tokensPerSecondDisplayText: String?`
- `isTokensPerSecondEstimated: Bool`
- `generationDurationSeconds: TimeInterval?`
- `generationDurationSource: HermesGenerationDurationSource?`
- `totalResponseDurationSeconds: TimeInterval?`
- `outputTokenCount: Int?`
- `totalTokenCount: Int?`
- `tokenCountSource: HermesTokenCountSource?`
- `serverConfirmedModel: Bool`
- `serverRoutedToDifferentModel: Bool`

Exact token counts use provider usage payloads such as `completion_tokens`, `output_tokens`, or Ollama-style `eval_count`. Exact TPS requires a provider generation duration such as Ollama `eval_duration`; otherwise the backend marks the displayed rate as approximate with `~` because relay/proxy buffering can make wall-clock stream timing lie. If usage is missing entirely, the service estimates output tokens from final assistant text.

Streaming timing is handled centrally:

- `responseStartedAt`: assistant request start.
- `firstResponseChunkAt`: first streamed content or tool-call chunk.
- `responseCompletedAt`: final stream completion.

TPS is output tokens divided by generation duration, so first-token latency does not make the generation-rate number look slower than the model actually streamed. The backend asks OpenAI-compatible servers for final usage chunks with `stream_options.include_usage = true`, parses Ollama top-level metrics, and suppresses TPS entirely when the only timing source is an implausibly short buffered wall-clock burst.

## UI Scope

Recommended preference key:

```swift
@AppStorage("hermesShowMessageTPS") private var showMessageTPS = false
```

Recommended touch points:

- `OpenBurnBarMobile/Views/Hermes/HermesTabView.swift`
  - Add the `@AppStorage` flag to `HermesChatView`.
  - Pass `showMessageTPS` into `HermesMessageBubble`.
  - Add a toolbar/menu toggle named `Show tokens/sec`.
  - Render `message.tokensPerSecondDisplayText` at the bottom of assistant bubbles only.
- `OpenBurnBarMobile/Views/Hermes/HermesSettingsView.swift`
  - Add the same toggle under a compact display/debug section.
- `OpenBurnBarMobile/Views/ChatView.swift`
  - Mirror the bubble rendering if this legacy/simple chat surface is still user reachable.

## Rendering Rules

- Only show TPS when `showMessageTPS == true`.
- Only render for assistant messages.
- Only render when `message.tokensPerSecondDisplayText != nil`.
- Use the provided `tokensPerSecondDisplayText` verbatim.
- If `message.isTokensPerSecondEstimated == true`, include a subtle "estimated" affordance, not a scary warning. Estimated means either token count was locally estimated or the duration came from wall-clock stream timing instead of provider eval duration.
- Keep it visually subordinate to the answer: small caption text, low-contrast chip, or one-line footer.
- Do not show TPS for error bubbles.
- Do not recalculate tokens or durations in SwiftUI.
- If `message.serverRoutedToDifferentModel == true`, consider a secondary "ran <model>" detail in the same footer, but keep it lower priority than the answer text.

## Suggested Bubble Treatment

Use a small bottom footer row:

- `speedometer` SF Symbol or equivalent existing icon.
- `message.tokensPerSecondDisplayText`.
- Optional `estimated` text only when estimated.

The footer should not shift bubble width while streaming. Give the row a stable minimum height and keep dynamic content on one line.

## Acceptance Checks

- Toggle off by default.
- Toggle persists across app restarts.
- Existing chat bubbles look unchanged when the toggle is off.
- Assistant bubbles with provider usage plus provider generation duration show exact TPS with no prefix.
- Assistant bubbles with provider token usage but only wall-clock timing show approximate TPS with the `~` prefix when the wall-clock stream is trustworthy.
- Assistant bubbles with buffered streams and no provider duration hide TPS instead of showing a misleading number.
- Assistant bubbles without provider usage show approximate TPS only when the final text estimate has a trustworthy duration.
- Error bubbles and user bubbles never show TPS.
- Long messages, tool-call-only messages, and streaming messages do not overlap or resize awkwardly.
- iPhone and iPad layouts remain readable in portrait and landscape.

## Backend Tests

The backend contract is covered in `OpenBurnBarMobileTests/HermesServiceTests.swift`:

- Exact provider-usage TPS.
- Provider eval-duration TPS.
- Buffered-stream suppression.
- Estimated fallback TPS.
- Error suppression.
- Relay streaming usage metadata.
- Duplicate usage-event de-duping.
- `stream_options.include_usage` request payload coverage.
