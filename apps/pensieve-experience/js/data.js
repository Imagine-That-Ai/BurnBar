/* ============================================================================
   Pensieve — data model
   Mock state, but every structural fact is the real, shipped truth:
   - the 12 data domains + their honest encryption tiers come from
     apps/console/lib/domains.generated.ts (generated from the registry).
   - the cloak posture (cosine preserved, basis hidden, cross-tenant cos ~0.77,
     sourceKind + byteCount the only plaintext facets) comes from
     docs/pensieve-leakage-analysis.md.
   - the engine facts (bge-small-en-v1.5, 384-dim, COSINE, on-device embed,
     server-side findNearest) come from docs/PENSIEVE.md.
   The content of the memories is illustrative; the machinery around it is not.
   ========================================================================== */
(function () {
  "use strict";

  /* ---- inline icon set (stroke-based, no emoji) ------------------------- */
  const ICONS = {
    basin: 'M3 9c2.5 2 6.5 2 9 0s6.5-2 9 0M3 14c2.5 2 6.5 2 9 0s6.5-2 9 0M5 5.5C5 4 8 3 12 3s7 1 7 2.5',
    recall: 'M11 19a8 8 0 1 0 0-16 8 8 0 0 0 0 16ZM21 21l-4.3-4.3',
    library: 'M4 5h6v14H4zM14 5h6v14h-6M4 9h6M14 9h6M4 13h6M14 13h6',
    remember: 'M12 5v14M5 12h14',
    quill: 'M20 4 8.5 15.5M20 4c-7 1-11 5-13 13l3-3M4 20l2.5-2.5',
    cloak: 'M2 12s3.5-7 10-7 10 7 10 7M2 12s3.5 7 10 7 10-7 10-7M3 3l18 18M9.9 9.9a3 3 0 0 0 4.2 4.2',
    shield: 'M12 3 5 6v5c0 4 3 7 7 8 4-1 7-4 7-8V6l-7-3ZM9.5 12l2 2 3.5-4',
    audit: 'M5 4h11l3 3v13H5zM9 9h6M9 13h6M9 17h3',
    vault: 'M5 11V8a7 7 0 0 1 14 0v3M4 11h16v9H4zM12 15v2',
    engine: 'M3 12c3-4 6-4 9 0s6 4 9 0M3 7c3-4 6-4 9 0M12 17c3 4 6 4 9 0',
    constellation: 'M5 6l6 3 8-4M5 6l3 9 3-6 8 1M8 15l5 4 6-9',
    teams: 'M9 11a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM3 20c0-3 3-5 6-5s6 2 6 5M17 7a3 3 0 0 1 0 5M18 20c0-2-1-3.5-3-4.5',
    analytics: 'M4 19V5M4 19h16M8 16v-5M12 16V8M16 16v-8M20 16v-3',
    settings: 'M12 9a3 3 0 1 0 0 6 3 3 0 0 0 0-6ZM19 12a7 7 0 0 0-.1-1l2-1.5-2-3.4-2.3 1a7 7 0 0 0-1.7-1l-.3-2.6h-4l-.3 2.6a7 7 0 0 0-1.7 1l-2.3-1-2 3.4 2 1.5a7 7 0 0 0 0 2l-2 1.5 2 3.4 2.3-1a7 7 0 0 0 1.7 1l.3 2.6h4l.3-2.6a7 7 0 0 0 1.7-1l2.3 1 2-3.4-2-1.5c.1-.3.1-.7.1-1Z',
    brain: 'M9 4a3 3 0 0 0-3 3 3 3 0 0 0-2 5 3 3 0 0 0 2 5 3 3 0 0 0 6 0V5a3 3 0 0 0-3-1ZM15 4a3 3 0 0 1 3 3 3 3 0 0 1 2 5 3 3 0 0 1-2 5 3 3 0 0 1-6 0',
    git: 'M6 3v12M6 21a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM6 6a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM18 9a3 3 0 1 0 0-6 3 3 0 0 0 0 6ZM18 6c0 5-4 6-8 6',
    note: 'M6 3h9l5 5v13H6zM15 3v5h5M9 13h7M9 17h5',
    chat: 'M4 5h16v11H9l-4 4V5Z',
    file: 'M6 3h8l4 4v14H6zM14 3v4h4M9 12h6M9 16h6',
    key: 'M15 7a4 4 0 1 1-3.5 6L4 20.5 6.5 18M8.5 15.5 11 13',
    device: 'M4 5h12v9H4zM2 18h16M20 8h2v10h-6v-2',
    export: 'M12 3v11M12 3 8 7M12 3l4 4M5 14v6h14v-6',
    trash: 'M4 7h16M9 7V4h6v3M6 7l1 14h10l1-14M10 11v6M14 11v6',
    check: 'M5 12l4.5 4.5L19 7',
    anchor: 'M12 7a2 2 0 1 0 0-4 2 2 0 0 0 0 4ZM12 7v14M5 13a7 7 0 0 0 14 0M5 13H3m18 0h-2',
    link: 'M9 13a4 4 0 0 0 5.7.3l3-3a4 4 0 0 0-5.7-5.7l-1 1M15 11a4 4 0 0 0-5.7-.3l-3 3a4 4 0 0 0 5.7 5.7l1-1',
    refresh: 'M3 12a9 9 0 0 1 15-6.7L21 8M21 3v5h-5M21 12a9 9 0 0 1-15 6.7L3 16M3 21v-5h5',
    arrow: 'M5 12h14M13 6l6 6-6 6',
    sparkle: 'M12 3l1.8 5.2L19 10l-5.2 1.8L12 17l-1.8-5.2L5 10l5.2-1.8L12 3ZM19 16l.8 2.2L22 19l-2.2.8L19 22l-.8-2.2L16 19l2.2-.8L19 16Z',
    lock: 'M6 11V8a6 6 0 0 1 12 0v3M5 11h14v9H5zM12 15v2',
    unlock: 'M6 11V8a6 6 0 0 1 11-3M5 11h14v9H5zM12 15v2',
    alert: 'M12 3 2 20h20L12 3ZM12 9v5M12 17h.01',
    dedup: 'M8 8h11v11H8zM8 8V5h11v3M5 11V5h3M5 16H3v3h3',
    info: 'M12 21a9 9 0 1 0 0-18 9 9 0 0 0 0 18ZM12 11v5M12 8h.01',
    x: 'M6 6l12 12M18 6 6 18',
    chevron: 'M9 6l6 6-6 6',
    eye: 'M2 12s3.5-7 10-7 10 7 10 7-3.5 7-10 7S2 12 2 12ZM12 15a3 3 0 1 0 0-6 3 3 0 0 0 0 6Z',
    seal: 'M12 3l2.5 1.5L17 4l.5 2.8L20 8l-1 2.7 1 2.7-2.5 1.2L17 17.5 14.5 17 12 18.5 9.5 17 7 17.5 6.5 14.6 4 13.4l1-2.7L4 8l2.5-1.2L7 4l2.5.5L12 3ZM9 12l2 2 4-4',
    waves: 'M2 8c2-2 4-2 6 0s4 2 6 0 4-2 6 0M2 13c2-2 4-2 6 0s4 2 6 0 4-2 6 0M2 18c2-2 4-2 6 0s4 2 6 0 4-2 6 0',
    spend: 'M4 19V5M4 19h16M7 15l3-4 3 2 4-6',
    mcp: 'M7 8a4 4 0 0 1 8 0v8a4 4 0 0 1-8 0M11 4v16',
    cursor: 'M5 3l14 7-6 1.5L10 18 5 3Z',
    media: 'M4 5h16v14H4zM4 9h16M9 13l3 2-3 2v-4Z',
    card: 'M3 6h18v12H3zM3 10h18M7 15h4',
    person: 'M12 12a4 4 0 1 0 0-8 4 4 0 0 0 0 8ZM5 20c0-3.5 3-6 7-6s7 2.5 7 6',
  };

  function icon(name, cls) {
    const d = ICONS[name] || ICONS.info;
    return (
      '<svg viewBox="0 0 24 24" fill="none" stroke="currentColor" stroke-width="1.6" ' +
      'stroke-linecap="round" stroke-linejoin="round"' +
      (cls ? ' class="' + cls + '"' : "") +
      ' aria-hidden="true">' +
      d.split("M").filter(Boolean).map((seg) => '<path d="M' + seg.trim() + '"/>').join("") +
      "</svg>"
    );
  }

  /* ---- tier helpers ----------------------------------------------------- */
  const TIERS = {
    end_to_end: {
      id: "end_to_end",
      label: "End-to-end",
      cls: "tier--end-to-end",
      color: "var(--color-tier-end-to-end)",
      blurb: "Sealed on-device with your vault key. BurnBar never sees plaintext or the key. Deletion is genuine ciphertext deletion.",
    },
    zero_access: {
      id: "zero_access",
      label: "Zero-access",
      cls: "tier--zero-access",
      color: "var(--color-tier-zero-access)",
      blurb: "Encrypted at rest; BurnBar can't read the content but holds the wrapped-key escrow path under your device trust.",
    },
    server_readable: {
      id: "server_readable",
      label: "Server-readable",
      cls: "tier--server-readable",
      color: "var(--color-tier-server-readable)",
      blurb: "Stored as plaintext BurnBar's servers can read — operational metadata, telemetry, the cross-device mirror.",
    },
  };

  /* ---- the 12 data domains (verbatim tiers from the registry) ----------- */
  const DOMAINS = [
    {
      id: "pensieve", title: "Pensieve Knowledge", icon: "brain", tier: "end_to_end",
      summary: "Your private semantic memory: repo docs, notes, and chat-derived memories your agents recall. Cloaked vectors + sealed text; the server runs ANN search over neither.",
      serverSees: ["cloaked 384-dim vectors", "sourceKind", "chunk + byte counts", "timestamps"],
      deviceOnly: ["chunk text", "source paths", "section/category metadata"],
      retention: "Until you delete it · 30-day tombstone", count: "1,284 chunks", bytes: "2.9 MB",
      actions: ["view", "export", "delete", "configure", "sync"], gate: "Ultra",
    },
    {
      id: "device_trust_keys", title: "Device Trust & Vault Keys", icon: "vault", tier: "end_to_end",
      summary: "Which devices are trusted to decrypt your data, and the wrapped vault keys that make zero-knowledge possible. The crux of the whole E2EE model.",
      serverSees: ["device trust state", "public-key fingerprints", "wrapped (ciphertext) key blobs"],
      deviceOnly: ["the vault key itself — Keychain / 0600 file, never uploaded"],
      retention: "Until revoked", count: "3 devices", bytes: "—",
      actions: ["view", "approve", "revoke", "recover"], gate: null,
    },
    {
      id: "session_logs", title: "Searchable Session Logs", icon: "library", tier: "end_to_end",
      summary: "Full conversation bodies + the encrypted search index + project memory. Sealed on-device; the server holds only ciphertext + plaintext cockpit facets.",
      serverSees: ["provider", "model", "project", "cost", "token counts", "bodyHash", "opaque token/semantic hashes"],
      deviceOnly: ["title", "snippet", "body preview", "full transcript body"],
      retention: "Until deleted", count: "612 documents", bytes: "44 MB",
      actions: ["view", "export", "delete"], gate: "Pro",
    },
    {
      id: "computer_use", title: "Agent Control & Escrow", icon: "cursor", tier: "zero_access",
      summary: "Computer-use (Agent Control) sessions and their tamper-evident escrow audit trail.",
      serverSees: ["session metadata", "action counts", "quota usage"],
      deviceOnly: ["sealed escrow envelopes"],
      retention: "Rolling", count: "18 sessions", bytes: "—",
      actions: ["view", "delete"], gate: "Ultra",
    },
    {
      id: "media", title: "Media", icon: "media", tier: "zero_access",
      summary: "Files, screen, and video relayed between your Mac and phones (Floo media).",
      serverSees: ["session events", "quota usage", "attachment manifests"],
      deviceOnly: ["media payload contents — relayed / sealed"],
      retention: "Rolling", count: "27 sessions", bytes: "—",
      actions: ["view", "delete"], gate: "Ultra",
    },
    {
      id: "conversations_chat", title: "Conversations & Chat", icon: "chat", tier: "server_readable",
      summary: "Assistant chats, CLI transcripts, and snippets mirrored across your devices. The cross-device mirror stores text the server can read — labeled server-readable for honesty. Sealing it at rest is tracked hardening.",
      serverSees: ["assistant + CLI conversation text (mirror)", "thread metadata", "timestamps", "device"],
      deviceOnly: ["chat_threads bodies when encrypted cloud backup is on"],
      retention: "Until deleted", count: "340 threads", bytes: "—",
      actions: ["view", "export", "delete"], gate: "Pro",
    },
    {
      id: "usage_spend", title: "Usage & Spend", icon: "spend", tier: "server_readable",
      summary: "Per-session token counts, cost estimates, and provider/model/project telemetry.",
      serverSees: ["provider", "model", "project", "device", "token counts", "cost estimates", "timestamps"],
      deviceOnly: [],
      retention: "Rolling", count: "—", bytes: "—",
      actions: ["view", "export", "delete"], gate: null,
    },
    {
      id: "provider_accounts", title: "Provider Accounts", icon: "key", tier: "server_readable",
      summary: "Connected AI provider accounts. Labels + status only — the credentials live in Google Cloud Secret Manager, never in your data tree.",
      serverSees: ["provider id", "redacted label", "status", "refresh metadata"],
      deviceOnly: ["secret material (Secret Manager, not the user tree)"],
      retention: "Until disconnected", count: "5 accounts", bytes: "—",
      actions: ["view", "revoke"], gate: null,
    },
    {
      id: "connected_devices", title: "Connected Devices & Pairings", icon: "device", tier: "server_readable",
      summary: "Your paired Macs, phones, and relays (Hermes, Pi agent, iroh) and which can talk to your account.",
      serverSees: ["device ids", "pairing metadata", "last seen", "relay routing"],
      deviceOnly: ["relayed payload contents (sealed per their own domains)"],
      retention: "Until revoked", count: "3 devices", bytes: "—",
      actions: ["view", "revoke"], gate: null,
    },
    {
      id: "external_mcp", title: "External Agent Access (MCP)", icon: "mcp", tier: "server_readable",
      summary: "Coding agents you've granted hosted-MCP access to, the scopes they hold, and their access audit trail.",
      serverSees: ["client id", "display name", "granted scopes", "grant mode", "access timestamps"],
      deviceOnly: ["decrypted search/recall results (decrypted only in the local shim)"],
      retention: "Until revoked", count: "4 clients", bytes: "—",
      actions: ["view", "revoke"], gate: "Pro",
    },
    {
      id: "entitlements_billing", title: "Plan & Billing", icon: "card", tier: "server_readable",
      summary: "Your subscription entitlements (Cloud Pro, Ultra) and their change history.",
      serverSees: ["entitlement ids", "product ids", "active state", "expiry", "purchase source"],
      deviceOnly: [],
      retention: "Permanent", count: "—", bytes: "—",
      actions: ["view"], gate: null,
    },
    {
      id: "audit_timeline", title: "Access Audit Timeline", icon: "audit", tier: "server_readable",
      summary: "A unified, tamper-evident log of who/what accessed your data, when — across every device, agent, and grant.",
      serverSees: ["actor", "action", "domain", "timestamp", "hash-chain links"],
      deviceOnly: [],
      retention: "Append-only", count: "9,402 events", bytes: "—",
      actions: ["view", "verify", "export"], gate: null,
    },
  ];

  /* ---- memories --------------------------------------------------------- */
  // sourceKind ∈ repo_docs | notes | chat_memory  (the 3 plaintext lanes)
  const SOURCES = {
    "burnbar/AGENTS.md": { kind: "repo_docs", label: "AGENTS.md", repo: "burnbar" },
    "burnbar/docs/PENSIEVE.md": { kind: "repo_docs", label: "docs/PENSIEVE.md", repo: "burnbar" },
    "burnbar/docs/leakage": { kind: "repo_docs", label: "pensieve-leakage-analysis.md", repo: "burnbar" },
    "burnbar/project.yml": { kind: "repo_docs", label: "project.yml", repo: "burnbar" },
    "notes/architecture": { kind: "notes", label: "Architecture notes", repo: null },
    "notes/launch": { kind: "notes", label: "Launch notes — burnbar.ai", repo: null },
    "notes/media": { kind: "notes", label: "Mercury media plan", repo: null },
    "chat/hermes": { kind: "chat_memory", label: "Hermes assistant", repo: null },
    "chat/cli": { kind: "chat_memory", label: "CLI agent session", repo: null },
  };

  function mem(o) {
    o.embedDim = 384;
    o.cloakVersion = 1;
    o.dedupHashVersion = 1;
    o.byteCount = o.body.length;
    o.sourceKind = SOURCES[o.source].kind;
    return o;
  }

  const MEMORIES = [
    mem({
      id: "m-cloak-geometry", source: "burnbar/docs/leakage",
      title: "The cloak preserves cosine exactly",
      body: "Each member's vault key derives an orthonormal matrix Q (24 Householder reflections). Every embedding is stored as Qx. Because Q is orthonormal it is inner-product preserving, so cos(Qx,Qy)=cos(x,y) exactly. That single identity is both the feature — the server can run findNearest COSINE over cloaked vectors and get the same ranking — and the leak: anything derivable from pairwise cosines is derivable from the cloaked vectors alone, with no key.",
      committedAt: "2026-06-02T18:30:00Z", lastRecalledAt: "2026-06-02T19:08:00Z",
      recallCount: 41, dedup: "unique", agents: ["Hermes", "Claude (MCP)", "Codex"],
    }),
    mem({
      id: "m-crosstenant", source: "burnbar/docs/leakage",
      title: "Cross-tenant linkage is only partial at 24 reflections",
      body: "Different members' cloaks produce byte-distinct stored vectors (relative L2 ~0.74), so a naive exact-match join across tenants finds nothing. But 24 Householder reflections in 384-dim are far from a Haar-random rotation, so cos(Q_A x, Q_B x) ~ 0.77. A curious server can still correlate the same plaintext across two tenants by cosine. We claim basis-hiding and per-user distinct bytes — not full cross-tenant unlinkability. Raising k toward the dimension is a versioned re-cloak migration.",
      committedAt: "2026-06-02T18:31:00Z", lastRecalledAt: "2026-06-02T18:55:00Z",
      recallCount: 12, dedup: "unique", agents: ["Claude (MCP)"],
    }),
    mem({
      id: "m-facets", source: "burnbar/docs/leakage",
      title: "Only sourceKind and byteCount are plaintext per vector",
      body: "After B-SEC-2 the per-vector cleartext side channels are gone: no stored contentHash, no real sourcePath, no cleartext sourceSlug. Dedup uses dedupHash, a vault-keyed HMAC of the plaintext; the source filter uses slugHmac. The only two cleartext per-vector columns are sourceKind (one of repo_docs / notes / chat_memory, a findNearest pre-filter) and byteCount (the chunk's plaintext length, the input to the per-tier cap aggregates). Both are load-bearing and low-sensitivity, so accepted.",
      committedAt: "2026-06-02T18:32:00Z", lastRecalledAt: "2026-06-01T10:00:00Z",
      recallCount: 7, dedup: "unique", agents: ["Hermes"],
    }),
    mem({
      id: "m-engine", source: "burnbar/docs/PENSIEVE.md",
      title: "Embedding: bge-small-en-v1.5, 384-dim, on-device",
      body: "Chunks are embedded on-device with bge-small-en-v1.5 (384-dim), cloaked with the vault-key orthonormal transform, then sealed with AES-256-GCM. Recall sends a cloaked 384-dim query vector to burnbar_search_knowledge; the server runs findNearest + FieldValue.vector COSINE and returns sealed payloads the device decrypts. Per-member COGS stays at cents/month because the server-side findNearest path is free of the key.",
      committedAt: "2026-05-28T09:00:00Z", lastRecalledAt: "2026-06-02T19:09:00Z",
      recallCount: 58, dedup: "unique", agents: ["Hermes", "Codex", "Claude (MCP)"],
    }),
    mem({
      id: "m-xcodegen", source: "burnbar/AGENTS.md",
      title: "The Xcode project is XcodeGen-generated",
      body: "Never hand-edit the pbxproj and never 'drag a file into Xcode'. Edit project.yml and run xcodegen generate. New source files are picked up by the glob; new targets/build settings go in project.yml. Hand edits get clobbered on the next regenerate.",
      committedAt: "2026-05-20T12:00:00Z", lastRecalledAt: "2026-06-02T17:40:00Z",
      recallCount: 33, dedup: "unique", agents: ["Codex", "Claude (MCP)"],
    }),
    mem({
      id: "m-completionbar", source: "burnbar/AGENTS.md",
      title: "The completion bar — boil the ocean",
      body: "The marginal cost of completeness is near zero with AI. Do the whole thing, do it right, with tests and documentation. Never offer to table it for later when the permanent solve is in reach. Search before building, test before shipping, ship the complete thing. The standard isn't 'good enough' — it's 'holy shit, that's done.'",
      committedAt: "2026-05-18T08:00:00Z", lastRecalledAt: "2026-06-02T19:01:00Z",
      recallCount: 64, dedup: "unique", agents: ["Claude (MCP)", "Codex", "Hermes"],
    }),
    mem({
      id: "m-tiers", source: "burnbar/docs/PENSIEVE.md",
      title: "Three encryption tiers, color-coded",
      body: "Every data domain carries an honest tier: end-to-end (teal) is sealed on-device with the vault key — the hero tier; zero-access (slate) is encrypted at rest with the wrapped key under device trust; server-readable (amber) is plaintext the server can read, like usage telemetry and the cross-device chat mirror. Chat is server-readable and must never be labeled end-to-end.",
      committedAt: "2026-05-30T11:00:00Z", lastRecalledAt: "2026-06-02T15:20:00Z",
      recallCount: 22, dedup: "unique", agents: ["Hermes", "Claude (MCP)"],
    }),
    mem({
      id: "m-domain", source: "notes/launch",
      title: "Launch domain is burnbar.ai on Firebase Hosting",
      body: "The launch website lives at website/ (Astro static site, copy in src/data/*.ts) and deploys to Firebase Hosting project 'burnbar' via firebase deploy --only hosting:marketing. Domain burnbar.ai is registered at Namecheap. Build with Node 22; firebase-deploy with Node 24.",
      committedAt: "2026-05-25T14:00:00Z", lastRecalledAt: "2026-05-31T09:00:00Z",
      recallCount: 9, dedup: "unique", agents: ["Codex"],
    }),
    mem({
      id: "m-floo", source: "notes/launch",
      title: "Public name for phone⇄Mac is 'Floo'",
      body: "The phone-to-Mac feature is publicly named Floo (File & Live Object Overlay). Computer Use is publicly 'Agent Control'. Names are centralized in website/src/data/capabilities.ts. Copy is benefit-first and safety-forward; never expose internal codenames or transport/protocol/codec jargon.",
      committedAt: "2026-05-25T14:05:00Z", lastRecalledAt: "2026-05-29T16:30:00Z",
      recallCount: 5, dedup: "near-dup of m-domain source", agents: ["Hermes"],
    }),
    mem({
      id: "m-media", source: "notes/media",
      title: "Mercury media moves over iroh, not the cloud",
      body: "Mac ⇄ iPhone/iPad media (file / screen / video) is relayed over iroh. The server sees session events, quota, and attachment manifests — never the payload. Media is zero-access: encrypted at rest, key under device trust. Real-world activation gates live in docs/runbooks/media-rollout-status.md.",
      committedAt: "2026-05-15T10:00:00Z", lastRecalledAt: "2026-05-30T08:00:00Z",
      recallCount: 8, dedup: "unique", agents: ["Hermes", "Codex"],
    }),
    mem({
      id: "m-architecture", source: "notes/architecture",
      title: "Why not Postgres / pgvector",
      body: "BurnBar already owns auth, Firestore, and storage; it is local-first, E2EE, and serverless. Recall runs on Firestore vector search (findNearest + FieldValue.vector, 384-dim COSINE) — not Cloud SQL or pgvector. Add a heavier datastore only when a concrete trigger fires; until then the cheap server-side findNearest keeps per-member cost in cents.",
      committedAt: "2026-05-22T13:00:00Z", lastRecalledAt: "2026-06-01T11:00:00Z",
      recallCount: 15, dedup: "unique", agents: ["Claude (MCP)", "Codex"],
    }),
    mem({
      id: "m-recovery", source: "chat/hermes",
      title: "Recovery is escrow-based, not a password reset",
      body: "Losing every trusted device does not mean losing the vault. Recovery uses an escrow grant: a recovery method (passphrase-wrapped or a trusted contact) can re-wrap the vault key onto a freshly registered device after approval. There is no server-side plaintext key to reset — recovery re-wraps, it never reveals.",
      committedAt: "2026-05-27T19:00:00Z", lastRecalledAt: "2026-06-02T12:00:00Z",
      recallCount: 11, dedup: "unique", agents: ["Hermes"],
    }),
    mem({
      id: "m-audit", source: "chat/hermes",
      title: "Audit log is a SHA-256 hash chain with daily anchors",
      body: "Every privacy action appends to a unified, append-only audit log. Each entry hashes the previous entry's hash, so truncation or edits break the chain and 'verify' fails visibly. Once a day the chain head is anchored with OpenTimestamps so even BurnBar can't quietly rewrite history.",
      committedAt: "2026-05-29T20:00:00Z", lastRecalledAt: "2026-06-02T14:00:00Z",
      recallCount: 6, dedup: "unique", agents: ["Hermes", "Claude (MCP)"],
    }),
    mem({
      id: "m-redaction", source: "chat/cli",
      title: "Secrets are scrubbed before anything is embedded",
      body: "The on-device pipeline runs a secret-redaction pass before embedding: API keys, tokens, private keys, and high-entropy strings are stripped so they never reach the embedder, the cloak, or the seal. A confidence filter drops low-value chunks. What survives is embedded, cloaked, sealed, then committed.",
      committedAt: "2026-05-31T07:30:00Z", lastRecalledAt: "2026-06-02T16:10:00Z",
      recallCount: 19, dedup: "unique", agents: ["Codex", "Hermes"],
    }),
    mem({
      id: "m-tombstone", source: "burnbar/docs/PENSIEVE.md",
      title: "Deletes leave a 30-day tombstone",
      body: "Forgetting a memory writes a tombstone and removes the ciphertext + cloaked vector from the active set immediately. The tombstone persists 30 days so every trusted device converges on the deletion, then it is garbage-collected. Because the content was only ever ciphertext to the server, deletion is genuine — there is no plaintext copy to leave behind.",
      committedAt: "2026-05-26T09:00:00Z", lastRecalledAt: "2026-05-30T10:00:00Z",
      recallCount: 4, dedup: "unique", agents: ["Hermes"],
    }),
    mem({
      id: "m-mem0", source: "burnbar/AGENTS.md",
      title: "Query mem0 before reading the wiki",
      body: "The canonical Droid wiki is mirrored verbatim into the BurnBar mem0 project (user_id=burnbar, 228 chunks) and refreshed on every commit. Agents should search mem0 first and load only the chunks a query returns; each result's metadata.source_path names the full droid-wiki page to open when the whole thing is needed.",
      committedAt: "2026-05-24T10:00:00Z", lastRecalledAt: "2026-06-02T13:30:00Z",
      recallCount: 27, dedup: "unique", agents: ["Claude (MCP)", "Codex"],
    }),
  ];

  /* ---- reflection-count table (measured; the honesty centerpiece) ------- */
  const REFLECTIONS = [
    { k: 24, cos: 0.77, shipped: true },
    { k: 48, cos: 0.59, shipped: false },
    { k: 96, cos: 0.35, shipped: false },
    { k: 192, cos: 0.12, shipped: false },
    { k: 384, cos: 0.04, shipped: false },
  ];

  /* ---- recall feed (live agent recalls) --------------------------------- */
  const RECALL_FEED = [
    { agent: "Claude (MCP)", what: "the cloak preserves cosine exactly", when: "just now", memId: "m-cloak-geometry" },
    { agent: "Hermes", what: "embedding: bge-small-en-v1.5, 384-dim", when: "9s ago", memId: "m-engine" },
    { agent: "Codex", what: "the Xcode project is XcodeGen-generated", when: "1m ago", memId: "m-xcodegen" },
    { agent: "Claude (MCP)", what: "the completion bar — boil the ocean", when: "2m ago", memId: "m-completionbar" },
    { agent: "Hermes", what: "secrets are scrubbed before embedding", when: "4m ago", memId: "m-redaction" },
  ];

  /* ---- device trust set ------------------------------------------------- */
  const DEVICES = [
    { id: "mac-studio", name: "Mac Studio", kind: "Mac · this device", trusted: true, canDecrypt: true, lastSeen: "now", fp: "9F2A · 41C0 · D7E8 · 5B13", current: true },
    { id: "iphone-15", name: "iPhone 15 Pro", kind: "iPhone", trusted: true, canDecrypt: true, lastSeen: "3m ago", fp: "2C71 · A0FF · 19B4 · E6A2", current: false },
    { id: "ipad-air", name: 'iPad Air', kind: "iPad", trusted: true, canDecrypt: true, lastSeen: "yesterday", fp: "B45D · 7E22 · 0C9A · 88F1", current: false },
    { id: "macbook-air", name: "MacBook Air", kind: "Mac · awaiting approval", trusted: false, canDecrypt: false, lastSeen: "12m ago", fp: "E1A9 · 33B7 · 5F02 · 4D6C", current: false },
  ];

  const RECOVERY = [
    { id: "passphrase", name: "Recovery passphrase", status: "healthy", detail: "24-word phrase, last verified 4 days ago", ok: true },
    { id: "icloud", name: "iCloud Keychain escrow", status: "healthy", detail: "Wrapped key synced to 3 trusted devices", ok: true },
    { id: "contact", name: "Trusted contact", status: "not set up", detail: "No recovery contact — add one to survive total device loss", ok: false },
  ];

  /* ---- engine facts ----------------------------------------------------- */
  const ENGINE = {
    model: "bge-small-en-v1.5",
    dim: 384,
    metric: "COSINE",
    where: "on-device",
    index: "Firestore findNearest + FieldValue.vector",
    cloak: "24 Householder reflections · per-member orthonormal Q",
    seal: "AES-256-GCM under the vault key",
    parity: "semantic memory maturing — index/query parity tracked behind embeddingModelVersion",
  };

  /* ---- tier limits (illustrative) --------------------------------------- */
  const LIMITS = { sources: { used: 4, max: 12 }, chunks: { used: 1284, max: 50000 }, bytes: { used: 3041280, max: 524288000 } };

  /* ---- recall analytics ------------------------------------------------- */
  const ANALYTICS = {
    mostRecalled: [
      { id: "m-completionbar", n: 64 },
      { id: "m-engine", n: 58 },
      { id: "m-cloak-geometry", n: 41 },
      { id: "m-xcodegen", n: 33 },
      { id: "m-mem0", n: 27 },
    ],
    neverUsed: ["m-tombstone", "m-floo"],
    sourceMix: [
      { kind: "repo_docs", n: 7, color: "var(--color-tier-end-to-end)" },
      { kind: "notes", n: 3, color: "var(--color-mercury-bright)" },
      { kind: "chat_memory", n: 5, color: "var(--color-tier-server-readable)" },
    ],
  };

  /* ---- exposed namespace ------------------------------------------------ */
  function fmtBytes(n) {
    if (n == null) return "—";
    if (n < 1024) return n + " B";
    if (n < 1048576) return (n / 1024).toFixed(1) + " KB";
    return (n / 1048576).toFixed(1) + " MB";
  }
  function fmtCount(n) { return n == null ? "—" : n.toLocaleString("en-US"); }
  function memById(id) { return MEMORIES.find((m) => m.id === id); }
  function domainById(id) { return DOMAINS.find((d) => d.id === id); }

  window.PENSIEVE = {
    icon, ICONS, TIERS, DOMAINS, MEMORIES, SOURCES, REFLECTIONS, RECALL_FEED,
    DEVICES, RECOVERY, ENGINE, LIMITS, ANALYTICS,
    fmtBytes, fmtCount, memById, domainById,
    KIND_LABEL: { repo_docs: "Repo docs", notes: "Notes", chat_memory: "Chat-derived" },
    LEAKAGE_DOC: "../../docs/pensieve-leakage-analysis.md",
    PENSIEVE_DOC: "../../docs/PENSIEVE.md",
  };
})();
