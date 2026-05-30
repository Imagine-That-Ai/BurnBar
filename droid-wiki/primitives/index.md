# Primitives

Core domain objects that appear across three or more subsystems. Understanding these types makes the rest of the codebase navigable.

## AgentProvider

The Swift enum enumerating every supported AI provider. Powers all parsers, UI color assignments, routing decisions, and Firestore sync. Every parser returns an `AgentProvider` case; every chart slice maps to one.

→ [AgentProvider](agent-provider.md)

## TokenUsage

The fundamental data model representing one AI session's token consumption event. Created by parsers, aggregated by `UsageAggregator`, persisted by `UsageStore`, displayed in the popover dashboard, and optionally synced to Firestore as `UsageEventDoc`.

→ [TokenUsage](token-usage.md)

## Design system

Color tokens (Botanical Cream light / Warm Charcoal dark), typography scale (SF Pro Rounded), spacing (4px base unit), motion tokens, and Hermes mercury identity. All adaptive via `NSColor` dynamic provider.

→ [Design system](design-system.md)
