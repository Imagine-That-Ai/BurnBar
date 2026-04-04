# Third-Party Notices

OpenBurnBar includes or references a small amount of third-party material.

## Runtime-fetched provider logos

- `AgentLens/Models/AgentProvider.swift` — ~10 coding tool logos (Claude Code, Copilot, Cursor, Codex, Z.ai, MiniMax, Kimi, Cline, Gemini, Augment)
- `AgentLens/Theme/LLMModelBrand.swift` — ~13 LLM vendor logos (Anthropic, OpenAI, Gemini, DeepSeek, Kimi, MiniMax, Meta, Mistral, Qwen, Grok, Cohere, Perplexity, Apple)

These files reference brand logos hosted by the [Lobehub icon set](https://github.com/lobehub/lobe-icons) on GitHub's raw content CDN (`raw.githubusercontent.com/lobehub/lobe-icons/...`). The logos are fetched at runtime via SwiftUI `AsyncImage` and are not distributed as part of the repository's tracked assets or extension tarball.

**Offline behavior:** If the CDN is unreachable, `AsyncImage` falls back to the SF Symbol placeholder defined in each provider's `iconName`. The app remains fully functional without the remote logos.

**Privacy note:** Fetching these images sends an HTTP request to GitHub's CDN, which logs standard request metadata (IP address, user agent). No OpenBurnBar-specific identifiers are sent.

Provider names, logos, and service marks remain the property of their respective owners and are used here only for descriptive identification.

## Generated SVG assets

- `AgentLens/Resources/Assets.xcassets/AppLogo.imageset/AppLogo.svg`
- `docs/favicon.svg`

These SVGs include embedded comments noting they were created with Arrow by QuiverAI. Keep those attribution comments intact unless the assets are replaced.

## Dependencies

OpenBurnBar depends on third-party packages through Swift Package Manager and npm. Their licenses and notices remain with their upstream projects.
