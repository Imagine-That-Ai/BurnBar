export interface FAQItem {
  id: string;
  question: string;
  answer: string; // markdown-light: plain text + simple paragraphs
}

export const FAQ: FAQItem[] = [
  {
    id: "router-family-failover",
    question: "What is Provider-Family Failover?",
    answer:
      "It's the default routing mode in BurnBar. The router stretches capacity for the model you asked for across multiple accounts inside the same wire-format family — never across families, and never to a different model.\n\nIf your pinned Z.ai key throttles, any other account in your library that ALSO carries that exact model picks up — never a substitute. Claude Code works the same way inside the Anthropic family: your Pro plan as primary, your Console admin key as runner-up, both serving the identical model id.\n\nFilter rule #F in ProviderRoutingPolicy.decide drops every candidate account whose catalog doesn't list the requested model. If no candidate survives, the gateway returns a structured 503 — your IDE sees a clean error, never a silent substitute."
  },
  {
    id: "router-intelligent-mode",
    question: "What is the Intelligent Model Router?",
    answer:
      "It's the opt-in routing mode. You tell BurnBar what the task is (or let your client surface it), and a daily board of language models runs research and analysis tasks over the model landscape.\n\nBurnBar keeps the result deterministic: the public rundown preserves the raw evidence score, then applies a stable favorite policy so GPT-5.5 xhigh, Claude Opus 4.7, and GLM 5.1 are not dethroned by one noisy refresh. A challenger has to clear freshness, routability, evidence, and benchmark margins across consecutive rundowns.\n\nThe winner serves the request and a runner-up is held in reserve so failover is instant. Benchmarks are advisory — they help break ties and weigh recency, but they never override your pin or the live quota state. User choice, auth, quota, and availability always win."
  },
  {
    id: "router-codex-to-claude",
    question: "Will BurnBar send my Codex task to Claude?",
    answer:
      "Not in failover mode. The router refuses to cross the family boundary. Your Codex task stays on OpenAI-family accounts (Z.ai, MiniMax, Kimi, OpenAI, Ollama). Your Claude Code task stays on Anthropic-family accounts.\n\nIf every OpenAI-family account is rate-limited, you get a structured 503, not a stealth swap into Claude.\n\nIn Intelligent mode you can opt into cross-family routing per surface — but the surface (and you) have to ask for it explicitly. We never silently swap providers on a request that asked for a specific one."
  },
  {
    id: "router-pin-model",
    question: "Can I still pin a model?",
    answer:
      "Yes. Pinning is the strongest signal in both modes.\n\nIn Provider-Family Failover, you pin an account that serves your chosen model. The pinned account wins as long as it's healthy; a runner-up account (one that also carries the same model) is pre-selected for instant failover.\n\nIn Intelligent Mode, you pin a model identity, a family, or a tier (e.g. \"always opus-class for the autopilot surface\"). The router still scores candidates and holds a runner-up, but it will not pick something else when your pin is healthy. A healthy pin always wins."
  },
  {
    id: "router-benchmark-sources",
    question: "What benchmark sources does BurnBar use?",
    answer:
      "A curated set of recently refreshed, well-methodologized public sources: Artificial Analysis (intelligence + coding indices, plus TPS and pricing), Terminal-Bench via Hugging Face (shell-loop agents, verified-run flag), and Design Arena (pairwise Elo + win-rate by category). Manual cached fixtures cover gaps when a source's API is unavailable.\n\nEach score carries an age and a confidence label; older scores are weighted down, not silently dropped. The daily rundown at /router/daily shows the model-board verdict, the raw evidence score, the deterministic selection score, source logos, and freshness states.\n\nWe don't synthesize benchmarks. We cite, we don't fabricate. And no benchmark ever overrides your pin or beats live quota state — they're advisory signals."
  },
  {
    id: "router-logs-safe",
    question: "Are routing logs safe?",
    answer:
      "Yes. The local ProviderRoutingDecisionEvent stream records the chosen account ID, the skipped account IDs, the reason each one was skipped, and the final ranking signals.\n\nIt never logs the API key. Never the OAuth bearer. Never the request body. Never the response body. Keys live in the macOS Keychain with device-local accessibility.\n\nLogs stay in the local SQLite store and never leave the device unless you explicitly enable an opt-in mirror."
  },
  {
    id: "data-anywhere",
    question: "Does OpenBurnBar send my data anywhere?",
    answer:
      "By default, no. Local usage tracking runs entirely on your Mac and writes to a local SQLite database. No telemetry, no analytics, no crash reports leave the device unless you explicitly enable an opt-in feature.\n\nThe opt-in features are: Firebase sync (metadata only by default), iCloud session-log mirroring (separate from Firebase, uses your Apple ID), Sentry crash diagnostics (off by default), and hosted quota sync (paid). Each one is a separate toggle, each one is described in the Privacy & Trust page."
  },
  {
    id: "account",
    question: "Do I need an account?",
    answer:
      "No account is needed for the core product. OpenBurnBar reads logs your agents already drop on disk and works fully offline.\n\nYou'll only sign in (Apple or Google, via Firebase Auth) if you want optional cloud sync, multi-device chat resume, or the paid Hosted Quota Sync subscription."
  },
  {
    id: "api-keys",
    question: "Does OpenBurnBar read my API keys?",
    answer:
      "Not by default. Local usage tracking reads usage logs, not credentials. If you choose to enable provider routing or quota polling, you may provide an API key for that specific provider — stored in the macOS Keychain with device-local accessibility.\n\nIf you enable Hosted Quota Sync, credential material you explicitly hand over is stored in Google Cloud Secret Manager; Firestore only holds a redacted label."
  },
  {
    id: "cost-accuracy",
    question: "How accurate are the costs?",
    answer:
      "Every provider row is tagged with one of three confidence labels:\n\nExact — the vendor's own API or local logs return token counts and we apply current public pricing.\n\nEstimated — token counts come from an on-disk approximation (e.g. Copilot uses an 85/15 input/output heuristic).\n\nUnavailable — the vendor doesn't expose data. We mark it instead of pretending.\n\nOnly OpenRouter returns dollar costs directly. For everyone else we compute from a pricing table — accurate for trends, not for tax audits."
  },
  {
    id: "providers-exact",
    question: "Which providers are exact vs estimated?",
    answer:
      "Exact today: Claude Code, Codex, Cursor, Factory, MiniMax, Z.ai, Warp, Kimi, OpenRouter, Ollama (local), Aider.\n\nEstimated: OpenAI (cost computed), Anthropic Console (cost computed, daily lag), GitHub Copilot (token volume heuristic).\n\nDetection-only (no usage data exposed by vendor): Gemini CLI, Cline, Roo Code, Kilo Code, Augment, Windsurf, Goose, OpenClaw.\n\nThe full matrix is on the Providers page."
  },
  {
    id: "hosted-quota",
    question: "What is Hosted Quota Sync?",
    answer:
      "Hosted Quota Sync is the paid tier. It adds four capabilities to the free local product:\n\n1. Hosted Codex quota refresh from any signed-in device, with OpenBurnBar running the runner. Rate-limited to 30/day and 300/month per account.\n\n2. Conversation backup and resume — chat titles, previews, and message bodies, encrypted in transit, restored across iPhone, iPad, and Mac.\n\n3. Full session-log sync — complete agent runs mirrored to cloud and searchable across devices.\n\n4. Hermes Remote Relay — reach the Mac's local Hermes from anywhere over a verified WebSocket, with App Check attestation and Apple JWS end-to-end.\n\nProduct id com.openburnbar.hostedQuotaSync.cloud.monthly. Intended price $4.99/month via the App Store. Apple handles billing."
  },
  {
    id: "claude-code-self-hosted",
    question: "Why is Claude Code self-hosted only?",
    answer:
      "Two reasons. First, Claude Code's real data sources live in your local filesystem — the statusline hook in ~/.claude/settings.json and the per-session JSONL files in ~/.claude/projects/. A cloud function has no lawful way to read those without an agent running on your Mac.\n\nSecond, Anthropic's current Claude Code policy disallows third-party developers from offering Claude.ai login or routing Free, Pro, or Max credentials on behalf of users. We agree with that boundary. Claude Code always stays on your machine."
  },
  {
    id: "delete-data",
    question: "Can I delete my data?",
    answer:
      "Yes — at any time, from several angles.\n\nLocal: delete the app and its support files at ~/Library/Application Support/OpenBurnBar/.\n\nCloud: sign out and choose Delete my data in Settings → Account.\n\nHosted credentials: remove the provider account from OpenBurnBar.\n\niCloud mirror: delete files from the iCloud.com.openburnbar.app container in your iCloud Drive."
  },
  {
    id: "offline",
    question: "What happens offline?",
    answer:
      "The whole product works offline. Dashboard, menu bar, log parsing, session viewing, settings, Hermes (with local backends), CLI, editor extension, controller workbench — none of them require a network.\n\nCloud sync simply pauses and resumes when you come back online. Disabling sync entirely does not affect local data."
  },
  {
    id: "team-or-solo",
    question: "Is this for teams or solo developers?",
    answer:
      "Both — but the product is sharpest for solo developers and small teams who run multiple agents in parallel and are tired of finding out about the bill on the first of the month.\n\nFor solo: zero accounts, all local, on your Mac. For small teams: optional Firebase sync lets each developer see their own burn while a shared workspace surface stays consistent. There is no admin console or seat-billing today — that's roadmap, not present."
  },
  {
    id: "cursor-vscode",
    question: "How does the Cursor / VS Code extension work?",
    answer:
      "The extension is an activity-bar panel that talks to OpenBurnBar's local daemon over the same UNIX socket the menu bar app uses. It shows the burn for your active workspace, the quota state for your active agent, and exposes the routed-provider gateway when you have it on.\n\nIt's source-only today — no public marketplace listing, no signed VSIX. Build from extensions/openburnbar and load unpacked. Marketplace publication is on the roadmap."
  }
];
