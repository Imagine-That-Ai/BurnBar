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
      "It's the default routing mode in BurnBar. The router stretches capacity inside the provider family you selected — never across unrelated providers, and never to a different model.\n\nA Codex route stays with Codex accounts. A Claude route stays with Claude accounts. A Z.ai route stays with Z.ai accounts. Your exact selected account and model remain active while healthy; only quota, rate-limit, or availability state moves the request to a runner-up inside that family.\n\nIf no candidate survives, the gateway returns a structured 503 — your IDE sees a clean error, never a silent substitute."
  },
  {
    id: "router-exact-model-failover",
    question: "What is Exact Model Failover?",
    answer:
      "It's the opt-in wider failover mode. BurnBar may try another provider or account after a quota, rate-limit, or availability failure — but only when that destination proves it serves the same canonical model ID as the request.\n\nThat means a request for gpt-5.4 can fail over to another route that truly serves canonical gpt-5.4. It cannot become gpt-5.4-mini, gpt-5.4-pro, a broad gpt-5-family wrapper, or a generic openai:standard substitute.\n\nIf the router cannot prove the exact identity, it fails closed with a structured 503. The audit event records the attempted model, canonical model, original route, destination route, reason, and whether the exact-model invariant passed."
  },
  {
    id: "router-model-board",
    question: "What is the daily model board?",
    answer:
      "The daily model board is advisory research, not a failover mode. A board of language models researches the model landscape using Artificial Analysis, Terminal-Bench, Design Arena, and cached/manual fixtures, then BurnBar turns that into a deterministic public rundown at /router/daily.\n\nThose rankings can explain which models look strong for coding, terminal, design, analysis, or agent tasks. They do not prove exact model identity and they do not authorize silent substitution. Pins, auth, quota, safety, availability, provider-family mode, and Exact Model Failover's canonical-ID gate still win at runtime."
  },
  {
    id: "router-codex-to-claude",
    question: "Will BurnBar send my Codex task to Claude?",
    answer:
      "Not in Provider-Family Failover. The router refuses to cross the selected provider-family boundary. Your Codex route stays with Codex accounts. Your Claude route stays with Claude accounts. Your Z.ai route stays with Z.ai accounts.\n\nExact Model Failover can look wider only when the destination route proves the same canonical model ID. It still will not send a request to a merely similar model just because that provider has quota."
  },
  {
    id: "router-pin-model",
    question: "Can I still pin a model?",
    answer:
      "Yes. Pinning is the strongest signal in both modes.\n\nIn Provider-Family Failover, you pin an account that serves your chosen model. The pinned account wins as long as it's healthy; a runner-up inside that provider family is pre-selected for instant failover.\n\nIn Exact Model Failover, the pin still wins while healthy. Only recoverable failures open the door to another provider/account, and only after the destination proves the same canonical model ID."
  },
  {
    id: "router-benchmark-sources",
    question: "What benchmark sources does BurnBar use?",
    answer:
      "A curated set of recently refreshed, well-methodologized public sources: Artificial Analysis (intelligence + coding indices, plus TPS and pricing), Terminal-Bench via Hugging Face (shell-loop agents, verified-run flag), and Design Arena (pairwise Elo + win-rate by category). Manual cached fixtures cover gaps when a source's API is unavailable.\n\nEach score carries an age and a confidence label; older scores are weighted down, not silently dropped. The daily rundown at /router/daily shows the model-board verdict, the raw evidence score, the deterministic selection score, source logos, and freshness states.\n\nWe don't synthesize benchmarks. We cite, we don't fabricate. And no benchmark ever overrides your pin, beats live quota state, or counts as exact-model proof — they're advisory signals."
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
      "No account is needed for the core product. OpenBurnBar reads logs your agents already drop on disk and works fully offline.\n\nYou'll only sign in (Apple or Google, via Firebase Auth) if you want optional cloud sync, multi-device chat resume, BurnBar Cloud, or BurnBar Cloud Pro."
  },
  {
    id: "api-keys",
    question: "Does OpenBurnBar read my API keys?",
    answer:
      "Not by default. Local usage tracking reads usage logs, not credentials. If you choose to enable provider routing or quota polling, you may provide an API key for that specific provider — stored in the macOS Keychain with device-local accessibility.\n\nIf you enable hosted quota refresh through BurnBar Cloud, credential material you explicitly hand over is stored in Google Cloud Secret Manager; Firestore only holds a redacted label."
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
      "Exact today (counted from the vendor's own API or from local logs): Claude Code, Codex, OpenAI, Cursor, Cursor Agent, Factory, MiniMax, Xiaomi MiMo, Z.ai, Warp, Ollama, Kimi, OpenRouter, Aider, Antigravity, DeepSeek, OpenCode, Hermes, and Pi Agent.\n\nEstimated (counted, then priced from a public table): GitHub Copilot, Anthropic Console (daily lag), Forge, and xAI (Grok).\n\nDetection-only (the vendor exposes nothing, so we show only Installed / Not installed): Gemini CLI, Cline, Roo Code, Kilo Code, Augment, Windsurf, Goose, and OpenClaw.\n\nThe full matrix is on the Providers page."
  },
  {
    id: "burnbar-cloud",
    question: "What is BurnBar Cloud?",
    answer:
      "BurnBar Cloud is the first paid tier. It adds hosted quota refresh, encrypted conversation backup and resume, full session-log sync, cloud search, and synced agent memory to the free local product.\n\nIt costs $7.99/month or $79/year. Product IDs are com.openburnbar.pro.monthly and com.openburnbar.pro.annual. Purchases are verified server-side before hosted features turn on."
  },
  {
    id: "burnbar-cloud-pro",
    question: "What is BurnBar Cloud Pro?",
    answer:
      "BurnBar Cloud Pro is the second paid tier. It includes everything in BurnBar Cloud, plus Floo phone-to-Mac workflows and Agent Control under your grant.\n\nIt costs $24.99/month or $249/year. Product IDs are com.openburnbar.proMax.monthly and com.openburnbar.proMax.annual. Cloud Pro uses the burnbar_pro_max entitlement."
  },
  {
    id: "cloud-pro-allowance",
    question: "How do Cloud Pro allowances and top-ups work?",
    answer:
      "Cloud Pro includes 500 hosted Agent Control actions and 50 relay-accounting GB each month. Extra hosted usage is prepaid before use: $4.99 buys 100 hosted actions, and $4.99 buys 50 relay-accounting GB.\n\nMonthly caps still apply: 2,000 hosted actions and 300 relay-accounting GB. If allowance plus top-ups are exhausted, hosted Agent Control or Floo relay pauses instead of silently spending more. BYOK actions do not consume hosted action credits."
  },
  {
    id: "grandfathered-hosted-quota",
    question: "What happens to the old Hosted Quota Sync subscription?",
    answer:
      "Existing $4.99 Hosted Quota Sync subscribers are grandfathered for Group A cloud features. It is not sold as a new purchase tier, and it does not unlock Cloud Pro features such as Floo or Agent Control."
  },
  {
    id: "billing-cancellation-refunds",
    question: "How do cancellation and refunds work?",
    answer:
      "Cancel from the platform where you purchased: Apple App Store, Google Play, or Stripe. Access remains until the paid period expires unless the platform reports a refund, chargeback, or revocation.\n\nApple and Google refunds follow store policy. Stripe purchases can be handled through support. Consumed top-ups are non-refundable except where store policy or law requires it."
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
  },
  {
    id: "floo",
    question: "What is Floo?",
    answer:
      "Floo joins your phone and your Mac. From your iPhone or iPad you can see your Mac's screen, reach in and control it, send files either direction, start a voice or video call, share one clipboard across both, and even unlock your Mac with Face ID or Touch ID.\n\nIt only ever connects your own paired devices, and everything between them is end-to-end encrypted — no one in the middle can read it, and that includes us. Every connection asks first, and one tap ends it.\n\nFloo is built and rolling out now, included with OpenBurnBar. (For the curious: Floo stands for File & Live Object Overlay — or, if you prefer, Fast Link Over Owl.)"
  },
  {
    id: "agent-control",
    question: "Can an agent actually use my computer?",
    answer:
      "Only if you let it, and only as far as you allow. With Agent Control, an OpenBurnBar agent can click, type, and work your apps — drive a browser to fill a form or pull data, or use the Mac itself when you grant that reach.\n\nYou stay in charge the whole way: watch every move live, approve each step or set limits and let it move freely inside them, mark off-limits windows and sites it can never touch, and stop it instantly with a shortcut or a gesture on your phone. Every action is written to a tamper-proof record. Grants are per task and expire on their own.\n\nIt ships only in the direct download of OpenBurnBar and stays off until you turn it on. Prefer it never have this reach? The Mac App Store build ships without it entirely."
  }
];
