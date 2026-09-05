/* ============================================================
   Memory MCP — the single source of truth for /memory and for the
   MCP setup surfaces that point at it.

   HOUSE RULE (website/CLAIMS.md): every value in this file traces to a
   file on `main`. Each block carries its `source` string, and the page
   renders that string next to the claim. If the product changes, edit
   here — the page and the claims ledger re-render from this file.

   Primary sources:
     tools/openburnbar-mcp/README.md            — setup, tools, engine, security
     tools/openburnbar-mcp/server.py            — MEMORY_TOOLSET (the tool count)
     tools/openburnbar-mcp/memory_engine/constants.py — kinds, weights, half-lives, fusion
     tools/openburnbar-mcp/eval_memory.py       — the measurements
     tools/openburnbar-mcp/tests/…              — what pins the measurements
     docs/PRIVACY.md                            — what leaves the device
     docs/superpowers/2026-09-02-memory-mcp-v2-design.md — design intent
   ============================================================ */

/** The repo checkout path used in every snippet. One constant so the
 *  copy buttons, the prose, and the verification steps can never drift. */
export const CHECKOUT = "/absolute/path/to/BurnBar";

/** Where the memory store lives on disk (macOS default). */
export const MEMORY_STORE_PATH =
  "~/Library/Application Support/OpenBurnBar/openburnbar-memory.sqlite";

/** MEMORY_TOOLSET in tools/openburnbar-mcp/server.py — the tools a client
 *  gets with BURNBAR_MCP_TOOLSET=memory. Counted, not guessed. */
export const MEMORY_TOOL_COUNT = 37;

/* The whole server, for the sections that speak about it rather than about
   the memory toolset. Parsed out of server.py by the copy gate, so they
   cannot drift — and declared here, above the first block that quotes one,
   because a count referenced before it is defined is a blank page. */

/** Every `burnbar_*` tool the server registers — memory, code intelligence,
 *  sessions, spend and the rest of the product surface. */
export const BURNBAR_TOOL_COUNT = 68;

/** `ministry_*` + `castle_*` + `bench_*`: agent fan-out and benchmarking
 *  tooling. Real, registered, and listed in the atlas under their own three
 *  headings — they orchestrate and grade coding agents rather than serve
 *  your memory, which is worth a reader knowing, not worth hiding. */
export const ORCHESTRATION_TOOL_COUNT = 26;

/** Every tool the server registers, full stop — `burnbar_*` and
 *  orchestration tooling combined. The number the hero and the atlas heading
 *  print, because "all" and "in total" both have to mean all. Gate-checked
 *  against every `@mcp.tool()` definition in server.py. */
export const TOTAL_TOOL_COUNT = BURNBAR_TOOL_COUNT + ORCHESTRATION_TOOL_COUNT;

/* ------------------------------------------------------------------
   1 · The write pipeline. Seven stages, in the order the engine runs
   them. Source: docs/superpowers/2026-09-02-memory-mcp-v2-design.md §4.1
   and tools/openburnbar-mcp/README.md § Local memory engine.
------------------------------------------------------------------- */
export type PipelineStage = {
  n: string;
  name: string;
  /** One sentence. What the stage actually does. */
  what: string;
  /** The detail a skeptic wants. */
  detail: string;
  /** "gate" stages are the ones that can refuse or rewrite. */
  role: "in" | "gate" | "resolve" | "store" | "out";
};

export const WRITE_PIPELINE: PipelineStage[] = [
  {
    n: "01",
    name: "Ingest",
    what: "A transcript, a block of text, or facts the agent already extracted.",
    detail:
      "The whole input is hashed first. Replaying the same session — a --resume, a re-run hook, two hooks racing — reports already_ingested and writes nothing.",
    role: "in"
  },
  {
    n: "02",
    name: "Extract",
    what: "Durable statements come out; chatter, questions and tool noise do not.",
    detail:
      "Facts supplied by the calling agent are used as-is (free, highest quality). Otherwise the default is a deterministic offline heuristic that scores durability cues and classifies kind, scope and confidence. Cloud and Ollama extractors are opt-in.",
    role: "in"
  },
  {
    n: "03",
    name: "Secret gate",
    what: "Credentials are removed before anything is stored.",
    detail:
      "A shared Swift/Python secret corpus plus an entropy branch, applied to the body and to tags, entities, metadata and the source path. Default policy redacts the secret and keeps the fact. Base64- and hex-encoded secrets are decoded and redacted at their span.",
    role: "gate"
  },
  {
    n: "04",
    name: "Injection screen",
    what: "Text that tries to steer a future agent is quarantined, not trusted.",
    detail:
      "Sentinels — “ignore previous instructions”, SYSTEM: headers, pack markers, shell-pipe-to-sh — in any field mark the row quarantined. Quarantined rows are excluded from recall until you approve them.",
    role: "gate"
  },
  {
    n: "05",
    name: "Reconcile",
    what: "ADD, UPDATE, NONE or DELETE against what you already know.",
    detail:
      "Near-duplicates reinforce the existing memory instead of adding a second one. A changed value on the same subject retires the old row and keeps its history. A negation retires the fact and stores nothing.",
    role: "resolve"
  },
  {
    n: "06",
    name: "Store",
    what: "Encrypted body, vector, entities, relations, history and audit — one transaction.",
    detail:
      "Bodies and history bodies are AES-256-GCM sealed with a key the engine owns at mode 0600. The database and its WAL/SHM sidecars are 0600. Every write appends a label-only event to a hash chain.",
    role: "store"
  },
  {
    n: "07",
    name: "Recall",
    what: "Hybrid retrieval, salience rerank, and an untrusted-content wrapper.",
    detail:
      "BM25 and vector search each produce a ranking; reciprocal-rank fusion combines them, so a memory found by one signal alone still surfaces. Every returned body is wrapped as untrusted data.",
    role: "out"
  }
];

/* ------------------------------------------------------------------
   2 · Retrieval mechanics — the numbers that decide what comes back.
   Source: tools/openburnbar-mcp/memory_engine/constants.py
------------------------------------------------------------------- */
export const FUSION = {
  source: "memory_engine/constants.py",
  rrfK: 60,
  lexicalWeight: 0.6,
  semanticWeight: 1.0,
  note: "Paraphrased questions are where memory earns its keep, so the semantic list carries more weight. Lexical still wins on exact identifiers — paths, symbols, ticket ids.",
  dedupCosine: 0.92,
  dedupJaccard: 0.75,
  halfLifeShortDays: 30,
  halfLifeLongDays: 365,
  accessBoostCap: 1.5
} as const;

/** The twelve kinds a memory can be, with the salience weight each carries
 *  into the rerank. KIND_WEIGHTS + SHORT_HALF_LIFE_KINDS + PERSONAL_KINDS. */
export type MemoryKind = {
  kind: string;
  weight: number;
  /** Personal-scope kinds follow you across projects. */
  personal: boolean;
  /** Short half-life kinds decay in 30 days rather than 365. */
  decaysFast: boolean;
  example: string;
};

export const MEMORY_KINDS: MemoryKind[] = [
  {
    kind: "decision",
    weight: 1.0,
    personal: false,
    decaysFast: false,
    example: "We went with a UNIX socket over the HTTP gateway for daemon RPC."
  },
  {
    kind: "gotcha",
    weight: 1.0,
    personal: false,
    decaysFast: false,
    example: "The Signal FFI build phase breaks on checkout paths containing spaces."
  },
  {
    kind: "architecture",
    weight: 0.95,
    personal: false,
    decaysFast: false,
    example: "The Xcode project is generated by xcodegen — never hand-register a file."
  },
  {
    kind: "preference",
    weight: 0.95,
    personal: true,
    decaysFast: false,
    example: "Prefer table-driven tests over one test function per case."
  },
  {
    kind: "profile",
    weight: 0.9,
    personal: true,
    decaysFast: false,
    example: "Works in Pacific time; ships on Fridays only behind a flag."
  },
  {
    kind: "procedure",
    weight: 0.85,
    personal: false,
    decaysFast: false,
    example: "Release runbook: bump VERSION, regenerate the appcast, then notarize."
  },
  {
    kind: "fact",
    weight: 0.85,
    personal: false,
    decaysFast: false,
    example: "The staging bucket is openburnbar-downloads-staging."
  },
  {
    kind: "relationship",
    weight: 0.8,
    personal: true,
    decaysFast: false,
    example: "The daemon team owns the socket contract; the app team owns the schema."
  },
  {
    kind: "todo",
    weight: 0.7,
    personal: false,
    decaysFast: true,
    example: "Re-run the provenance check once the branded host is live."
  },
  {
    kind: "event",
    weight: 0.6,
    personal: false,
    decaysFast: true,
    example: "Cut the 1.0.40 release candidate on the 30th."
  },
  {
    kind: "note",
    weight: 0.6,
    personal: false,
    decaysFast: false,
    example: "Raw text stored verbatim when extraction is turned off."
  },
  {
    kind: "other",
    weight: 0.5,
    personal: false,
    decaysFast: false,
    example: "Anything the classifier could not place."
  }
];

/* ------------------------------------------------------------------
   3 · The secret gate. Three policies, one corpus, three consumers.
   Source: tools/openburnbar-mcp/README.md § Secrets and PII,
           tools/openburnbar-mcp/eval_memory.py SECRET_SHAPES,
           tools/openburnbar-mcp/tests/test_gate_adversarial.py
------------------------------------------------------------------- */
export const GATE_POLICIES = [
  {
    id: "redact",
    label: "redact",
    status: "default" as const,
    headline: "Keep the fact. Lose the secret.",
    body: "The credential is replaced with a labelled REDACTED marker and the sentence survives as a memory. If a secret cannot be redacted in place — it only appears once line continuations are joined — the write is refused rather than stored in a reconstructable form."
  },
  {
    id: "reject",
    label: "reject",
    status: "opt-in" as const,
    headline: "Refuse the whole write.",
    body: "Any corpus hit refuses the memory with SECRET_DETECTED and no row lands. The strictest setting, and the right one for a shared machine."
  },
  {
    id: "retain",
    label: "retain",
    status: "experimental" as const,
    headline: "Vault it, hide it, and never sync it.",
    body: "Stores the verbatim text in an encrypted vault table, keeps a redacted searchable body in the main store, and hides the memory from default recall. It needs its own capability flag that the operator profile never grants, and reading it back needs sensitive_read plus include_secrets. Retained memories are never mirrored and never exported by default; the one path that returns the verbatim text is an export you ask for by name, with sensitive read granted and include_secrets set."
  }
];

/** The eight caller-controlled places test_gate_adversarial.py plants every
 *  credential shape. Rendered as the gate's coverage map. */
export const GATE_PLACEMENTS = [
  "prose (middle)",
  "prose (end)",
  "key/value line",
  "fenced code block",
  "tag",
  "entity",
  "metadata value",
  "source ref"
];

export const GATE_SHAPES = {
  total: 25,
  source: "tools/openburnbar-mcp/eval_memory.py — SECRET_SHAPES",
  /** Named honestly. The README lists these as the encoded gaps as of 2026-09-02. */
  encodingGaps: [
    "an AWS access key id, base64- or hex-encoded",
    "a postgres://user:pass@host URI, URL-encoded",
    "a password=… assignment, URL-encoded",
    "a 64-character hex signing key, hex-encoded again"
  ]
} as const;

/* ------------------------------------------------------------------
   4 · Proof. Only figures a committed run or a committed test produces.
   `pin` names the assertion that keeps the figure from sliding; a null
   pin is reported as measured-not-pinned, on the page and in CLAIMS.md.
------------------------------------------------------------------- */
export type Measurement = {
  id: string;
  figure: string;
  unit?: string;
  label: string;
  /** How it was measured — the command you can run yourself. */
  command: string;
  /** What the number is over. */
  corpus: string;
  /** The committed assertion that keeps it honest, or null. */
  pin: string | null;
  /** Extra honesty: what the number does not say. */
  caveat?: string;
};

export const MEASUREMENTS: Measurement[] = [
  {
    id: "extraction-recall",
    figure: "0.667",
    label: "Extraction recall — durable facts the offline extractor finds",
    command: "eval_memory.py --extraction --provider none",
    corpus: "36 developer conversations, 30 expected facts, 7 with nothing to remember",
    pin: "tests/test_eval_extraction.py — RECALL_FLOOR = 0.65, and it only moves up",
    caveat:
      "The ten misses are architecture and constraint statements phrased without a cue word. They are logged verbatim by --verbose."
  },
  {
    id: "extraction-precision",
    figure: "1.0",
    label: "Extraction precision — nothing invented from what it did find",
    command: "eval_memory.py --extraction --provider none",
    corpus: "same run",
    pin: null,
    caveat:
      "Precision saturates because the extractor is conservative — it fires on about one sentence per conversation, or none. Recall and the empty-case count are the informative halves."
  },
  {
    id: "empty-cases",
    figure: "1",
    unit: "of 7",
    label: "Facts invented across the seven conversations that had nothing durable",
    command: "eval_memory.py --extraction --provider none",
    corpus: "greetings, a traceback, tool output, an ephemeral test run",
    pin: "tests/test_eval_extraction.py — emptyCaseFacts <= 2"
  },
  {
    id: "leaks",
    figure: "0",
    label: "Credential strings that reached an extracted fact",
    command: "eval_memory.py --extraction --provider none",
    corpus: "three of the gold conversations paste a live-shaped credential",
    pin: "tests/test_eval_extraction.py — leaks == 0"
  },
  {
    id: "gate-raw",
    figure: "25",
    unit: "of 25",
    label: "Credential shapes detected in raw form",
    command: "eval_memory.py --gate",
    corpus: "GitHub, AWS, Slack, OpenAI, Anthropic, Stripe, JWT, PEM, Postgres, Twilio, …",
    pin: "tests/test_eval_extraction.py — len(matrix) == 25, and every row's raw column must be true",
    caveat: "Four encoding gaps remain and are named on this page rather than rounded away."
  },
  {
    id: "hybrid-recall",
    figure: "0.90",
    label: "Hybrid recall@5 — the right memory in the top five",
    command: "eval_memory.py --provider auto",
    corpus: "40 memories, 30 paraphrased queries, nomic-embed-text on local Ollama",
    pin: null,
    caveat:
      "Not pinned by CI: it needs a local embedding model, so the number depends on the model you run. Reproduce it on your own machine."
  },
  {
    id: "hybrid-mrr",
    figure: "0.678",
    label: "Hybrid mean reciprocal rank",
    command: "eval_memory.py --provider auto",
    corpus: "same run",
    pin: null,
    caveat: "Same caveat: measured against a local model, not pinned by CI."
  },
  {
    id: "judge-rules",
    figure: "0.42",
    label: "Reconciliation agreement, rules only",
    command: "eval_memory.py --judge",
    corpus: "64 labelled cases — 16 scenarios × ADD / UPDATE / NONE / DELETE",
    pin: "tests/test_eval_extraction.py — the recorded baseline stays inside 0.35–1.0",
    caveat:
      "This is a low number and it is deliberate. Without a strong cue the rules ADD rather than overwrite something you might still need. A Pro judge model raises it; the target is recorded, not claimed."
  }
];

/* ------------------------------------------------------------------
   5 · The device boundary. Three lanes, each with its source.
   Source: docs/PRIVACY.md §§ Optional Cloud Models for Memory,
           Optional Memory Backup and Device Sync;
           tools/openburnbar-mcp/README.md § Privacy.
------------------------------------------------------------------- */
export type BoundaryLane = {
  id: string;
  title: string;
  status: "always" | "opt-in" | "not-shipped";
  statusLabel: string;
  summary: string;
  rows: { item: string; note: string }[];
  source: string;
};

export const BOUNDARY: BoundaryLane[] = [
  {
    id: "stays",
    title: "Stays on your Mac",
    status: "always",
    statusLabel: "Always",
    summary:
      "This is the whole product with nothing turned on. No account, no network, no BurnBar server in the path.",
    rows: [
      {
        item: "Every memory body",
        note: "AES-256-GCM sealed at rest with a key the engine owns, mode 0600, alongside its WAL and SHM sidecars."
      },
      {
        item: "The transcripts memories are extracted from",
        note: "Read locally, written locally, never uploaded — including by the session hook."
      },
      {
        item: "Retained secrets",
        note: "The encrypted vault never leaves the device, is never mirrored, and is not exported by default."
      },
      {
        item: "Memories awaiting your review",
        note: "Quarantined and unreviewed rows are excluded from recall and from every off-device lane."
      },
      {
        item: "Repository knowledge",
        note: "Project Code Memory is local-only by default and is never replicated."
      },
      {
        item: "Your embeddings",
        note: "Vectors are computed locally by default and stay in the local store."
      }
    ],
    source: "tools/openburnbar-mcp/README.md § Local memory engine; docs/PRIVACY.md"
  },
  {
    id: "leaves",
    title: "Leaves only if you turn it on",
    status: "opt-in",
    statusLabel: "Off by default · paid entitlement",
    summary:
      "Two separate features, each off by default, each requiring its own consent in Settings → Privacy, each fail-closed: no entitlement, no consent, no daemon → zero network calls and unchanged local behaviour.",
    rows: [
      {
        item: "Cloud models for memory",
        note: "Redacted memory facts and your questions go from your Mac directly to the provider you picked, on your own key or your own CLI subscription. No BurnBar server is in that path; BurnBar receives nothing. Raw transcripts, anything the secret filter caught, and the sealed vault are never sent."
      },
      {
        item: "Encrypted backup of approved memories",
        note: "Approved, non-secret memories replicate to your own namespace end-to-end encrypted. The stored document holds a sealed blob, an opaque keyed-hash id, keyed source hashes, the kind, the review status and three timestamps — and the server's own rules forbid the rest: no text, no citations, no vectors, no tags, no entities, no metadata, no project names or paths."
      }
    ],
    source: "docs/PRIVACY.md:83-93"
  },
  {
    id: "not-yet",
    title: "Not shipped",
    status: "not-shipped",
    statusLabel: "In review",
    summary:
      "Named here so the section above can be read as complete. We would rather show you the gap than let you infer a feature.",
    rows: [
      {
        item: "Cross-device sync — the pull and merge half",
        note: "Backup is on main today: an encrypted copy off the device that BurnBar cannot read. Pulling those memories down onto a second Mac and merging them into its engine is written and in review. It is not shipped, so do not plan around it."
      }
    ],
    source: "docs/superpowers/plans/2026-09-03-memory-blind-sync.md § Shipping shape"
  }
];

/* ------------------------------------------------------------------
   6 · Setup. One server, five clients, exact paths.
   Source: tools/openburnbar-mcp/README.md §§ Setup / Cursor / Codex CLI /
           Hermes Agent / Claude Desktop; the repo's own .mcp.json;
           docs/CODEX_AGENT_ONBOARDING.md § Option C (the env table).
------------------------------------------------------------------- */
export type ClientSetup = {
  id: string;
  label: string;
  /** Where the config lives, verbatim. */
  where: string;
  /** Language for the snippet, used for the caption only. */
  lang: "json" | "toml" | "yaml" | "bash";
  lines: string[];
  /** One honest sentence about this client's quirk, if it has one. */
  note?: string;
};

const LAUNCHER = `${CHECKOUT}/tools/openburnbar-mcp/launch-memory.sh`;

export const CLIENTS: ClientSetup[] = [
  {
    id: "claude-code",
    label: "Claude Code",
    where: ".mcp.json in the project root (or your user config)",
    lang: "json",
    lines: [
      "{",
      '  "mcpServers": {',
      '    "openburnbar": {',
      '      "type": "stdio",',
      `      "command": "${LAUNCHER}",`,
      '      "args": [],',
      '      "env": { "BURNBAR_MCP_TOOLSET": "memory" }',
      "    }",
      "  }",
      "}"
    ],
    note: "This mirrors the entry the BurnBar checkout already ships, with the relative command path made absolute so you can copy it into any other project and give that project's sessions the same memory."
  },
  {
    id: "cursor",
    label: "Cursor",
    where: "Cursor Settings → MCP (or ~/.cursor/mcp.json)",
    lang: "json",
    lines: [
      "{",
      '  "mcpServers": {',
      '    "openburnbar": {',
      `      "command": "${LAUNCHER}",`,
      '      "args": [],',
      '      "env": { "BURNBAR_MCP_TOOLSET": "memory" }',
      "    }",
      "  }",
      "}"
    ],
    note: "Restart Cursor, then enable openburnbar for the chat that should use it."
  },
  {
    id: "codex",
    label: "Codex CLI",
    where: "~/.codex/config.toml",
    lang: "toml",
    lines: [
      "[mcp_servers.openburnbar]",
      `command = "${LAUNCHER}"`,
      "args = []",
      "startup_timeout_sec = 15",
      "tool_timeout_sec = 60",
      "",
      "[mcp_servers.openburnbar.env]",
      'BURNBAR_MCP_TOOLSET = "memory"'
    ],
    note: "Confirm with /mcp inside the Codex TUI. A trusted project's .codex/config.toml takes the same block."
  },
  {
    id: "claude-desktop",
    label: "Claude Desktop",
    where: "~/Library/Application Support/Claude/claude_desktop_config.json",
    lang: "json",
    lines: [
      "{",
      '  "mcpServers": {',
      '    "openburnbar": {',
      `      "command": "${LAUNCHER}",`,
      '      "args": [],',
      '      "env": { "BURNBAR_MCP_TOOLSET": "memory" }',
      "    }",
      "  }",
      "}"
    ],
    note: "Restart Claude Desktop after saving."
  },
  {
    id: "hermes",
    label: "Hermes",
    where: "~/.hermes/config.yaml",
    lang: "yaml",
    lines: [
      "mcp_servers:",
      "  openburnbar_local:",
      `    command: "${CHECKOUT}/tools/openburnbar-mcp/.venv/bin/python"`,
      `    args: ["${CHECKOUT}/tools/openburnbar-mcp/server.py"]`,
      "    timeout: 30",
      "    connect_timeout: 20"
    ],
    note: "Hermes' documented block runs the full server, so run ./setup.sh first rather than the memory bootstrap. Exporting BURNBAR_MCP_TOOLSET=memory in the shell that launches Hermes narrows it to the memory tools."
  }
];

/** The one command that has to run before any of the blocks above. */
export const BOOTSTRAP_LINES = [
  "$ git clone https://github.com/Imagine-That-Ai/BurnBar",
  "$ cd BurnBar",
  "$ ./tools/openburnbar-mcp/bootstrap-memory.sh",
  "→ creates .venv and installs requirements.txt only —",
  "  no Rust toolchain, no Cargo, no static parser."
];

/** Optional, and the page says so: semantic recall needs a local model. */
export const EMBEDDING_LINES = [
  "$ ollama pull nomic-embed-text",
  "# without a provider, recall is lexical only",
  "# and burnbar_memory_doctor says so."
];

/** Automatic collection. User-level settings, absolute path — the README is
 *  emphatic that $CLAUDE_PROJECT_DIR is wrong here, and says why. */
export const SESSION_HOOK_LINES = [
  "{",
  '  "hooks": {',
  '    "SessionEnd": [',
  "      {",
  '        "matcher": "",',
  '        "hooks": [',
  "          {",
  '            "type": "command",',
  `            "command": "\\"${CHECKOUT}/tools/openburnbar-mcp/hooks/claude-code-session-end.sh\\"",`,
  '            "timeout": 30',
  "          }",
  "        ]",
  "      }",
  "    ]",
  "  }",
  "}"
];

/** The statuses the hook prints. A receipt, never content. */
export const HOOK_STATUSES = [
  { id: "memorized", note: "at least one memory was written or reinforced" },
  { id: "already_ingested", note: "this transcript was seen before; nothing written" },
  { id: "skipped_no_facts", note: "nothing durable was extracted" },
  { id: "rejected", note: "facts were considered and every one refused" },
  { id: "skipped_disabled", note: "OPENBURNBAR_MEMORY_SESSION_HOOK=off" },
  { id: "skipped_missing_transcript", note: "no transcript at the given path" },
  { id: "skipped_empty", note: "the transcript held no user or assistant prose" },
  { id: "timeout", note: "the 20-second budget ran out — typical on the very first run" },
  { id: "error", note: "something failed; session end still succeeded" }
];

/* ------------------------------------------------------------------
   7 · Verification. The four checks that prove the install, in order.
------------------------------------------------------------------- */
export type VerifyStep = {
  id: string;
  title: string;
  how: string;
  expect: string;
  ifNot: string;
};

export const VERIFY_STEPS: VerifyStep[] = [
  {
    id: "listed",
    title: "The server is listed",
    how: `Ask your client for its MCP servers — /mcp in Claude Code and Codex, Settings → MCP in Cursor.`,
    expect: `openburnbar appears and reports ${MEMORY_TOOL_COUNT} tools — or all ${TOTAL_TOOL_COUNT} if you followed the Hermes block, which runs the full server until you narrow it with BURNBAR_MCP_TOOLSET=memory.`,
    ifNot:
      "The command path is the usual culprit: it must be absolute, and launch-memory.sh must be executable. Run it once in a terminal — it prints its bootstrap to stderr and then waits for JSON-RPC on stdin."
  },
  {
    id: "doctor",
    title: "The engine is healthy",
    how: "Ask the agent to run burnbar_memory_doctor.",
    expect:
      "Schema version, write mode, embedding provider and index health come back. It will tell you plainly if recall is lexical-only.",
    ifNot:
      "A signed OpenBurnBar install rejects this process as a daemon peer by design. That is expected and is a status, never an error — the engine is the authority for the local MCP and works without the daemon."
  },
  {
    id: "write",
    title: "It remembers",
    how: 'Ask the agent to remember something specific: "remember that this project generates its Xcode project with xcodegen".',
    expect: "burnbar_remember returns ADD with a memory id, a kind, and a mirror status.",
    ifNot:
      "Memory writes are on by default under the memory toolset. If the tool refuses, OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE has been set to false somewhere in the environment."
  },
  {
    id: "recall",
    title: "It recalls",
    how: "Open a brand-new session in a different client and ask the same question in different words.",
    expect:
      "burnbar_recall returns the memory with a score and a why block naming what matched it — lexical, semantic, or both.",
    ifNot:
      "If only exact wording works, no embedding provider is configured. Pull a local model, then run burnbar_memory_reindex once."
  }
];

/* ------------------------------------------------------------------
   8 · The limits, stated by us before anyone else states them.
------------------------------------------------------------------- */
export const LIMITS: { title: string; body: string; source: string }[] = [
  {
    title: "Semantic recall needs a local model",
    body: "Without an embedding provider, recall is lexical only. That still works — BM25 with a code-aware tokenizer is a real retrieval system — but paraphrases will miss. One ollama pull fixes it, and burnbar_memory_doctor tells you which mode you are in rather than pretending.",
    source: "tools/openburnbar-mcp/README.md § Embeddings"
  },
  {
    title: "The offline extractor is conservative",
    body: "It finds two thirds of the durable facts in our gold set and invents almost nothing. The third it misses are architecture and constraint statements phrased without a cue word. Agents that pass their own facts to burnbar_memorize skip the extractor entirely and do better.",
    source: "tools/openburnbar-mcp/eval_memory.py --extraction"
  },
  {
    title: "Rules-only reconciliation prefers to add",
    body: "Agreement with the labelled judge set is 0.42 on rules alone: without a strong cue the engine adds a new memory rather than overwriting one you might still need. Duplicates are cheap; a silently overwritten fact is not.",
    source: "tools/openburnbar-mcp/eval_memory.py --judge"
  },
  {
    title: "Four encoded credential shapes still slip the gate",
    body: "Raw detection is complete across all 25 shapes in the corpus. Four encoded forms are not yet caught, they are named on this page, and the adversarial suite is what will tell us when that changes.",
    source: "tools/openburnbar-mcp/README.md § Gate coverage"
  },
  {
    title: "Vectors and metadata are plaintext on disk",
    body: "Bodies and history bodies are encrypted. Vectors and the metadata column are not — the same posture as the app's on-disk vector indexes. The file mode is 0600; the threat model here is another user on the same machine, not a stolen disk.",
    source: "tools/openburnbar-mcp/README.md § Encrypted at rest"
  },
  {
    title: "macOS today, and only macOS",
    body: "The store defaults to the macOS Application Support directory and OPENBURNBAR_MEMORY_DB_PATH moves it; the engine itself is plain Python 3.11 or newer with no native build. That is a description of the code, not a support claim. Windows and Linux are not supported and not tested. There is a Linux port plan in the repository; a plan is not a platform.",
    source: "tools/openburnbar-mcp/README.md § Setup; § Support level"
  },
  {
    title: "Part of the server assumes the OpenBurnBar app is there",
    body: "The memory engine owns its own store and needs nothing else — no daemon, no app, no network. The session index, the spend tools, the inbox and Project Memory snapshots read what the macOS app and its daemon produce, and on a signed install that database is SQLCipher-encrypted, so those tools go through the daemon socket or report that they cannot. burnbar_resolve_db_path tells you which of those you are in, because existence is not health.",
    source:
      "tools/openburnbar-mcp/README.md § Local memory engine — Works without the daemon; server.py burnbar_resolve_db_path"
  },
  {
    title: "Adjacent tooling, best-effort support",
    body: "OpenBurnBar treats the local MCP as adjacent tooling: public, useful, and not required to build or run the macOS app, daemon, CLI or extension. It gets best-effort support compared with the core surfaces.",
    source: "tools/openburnbar-mcp/README.md § Support level"
  }
];

/* ------------------------------------------------------------------
   9 · Pro models. Opt-in, on the member's own quotas and keys.
   Source: tools/openburnbar-mcp/README.md § Pro models (opt-in);
           docs/PRIVACY.md § Optional Cloud Models for Memory.
------------------------------------------------------------------- */
export const PRO_PURPOSES = [
  {
    purpose: "memory-extract",
    what: "A frontier model reads the already-gated transcript and returns facts."
  },
  {
    purpose: "memory-judge",
    what: "ADD / UPDATE / NONE / DELETE on the ambiguous band, over candidates it was shown."
  },
  {
    purpose: "memory-embed",
    what: "Vectors through the gateway; the version id is part of the vector key, so spaces never mix."
  },
  {
    purpose: "memory-rerank",
    what: "Re-orders the top fusion hits; injection-labelled rows are never sent."
  },
  {
    purpose: "memory-answer",
    what: "An answer built only from cited memories, or an explicit refusal."
  }
];

export const PRO_INVARIANTS = [
  "The engine never holds a key. It asks a signed courier what it may use and receives a 15-minute bearer scoped to memory-* purposes.",
  "The gateway enforces the entitlement, per-provider consent, no-retention and the daily cap before it routes anything.",
  "Subscription quota is used only through the official CLIs, behind the existing CLI consent.",
  "Every cloud path degrades to the local behaviour and reports why in the tool's trustSignal.",
  "BurnBar receives nothing: the traffic goes from your Mac to the provider you chose."
];

/* ==================================================================
   COVERAGE ROUND — everything below this line exists because the first
   pass named six of the server's tools and left whole product surfaces
   unmentioned. Same house rule: every value traces to a file on `main`,
   and scripts/test-memory-copy.mjs reads BOTH sides and refuses to let
   them disagree.
   ================================================================== */

/* ------------------------------------------------------------------
   10 · Capability switches. Source: tools/openburnbar-mcp/README.md
   (the export block at the top) and server.py LOCAL_MCP_CAPABILITY_ENV.
------------------------------------------------------------------- */
export type Capability = {
  id: string;
  env: string;
  label: string;
  what: string;
  /** Honest default state on a fresh install. */
  byDefault: string;
};

export const CAPABILITIES: Capability[] = [
  {
    id: "memory_write",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_WRITE",
    label: "memory write",
    what: "Create, patch, review, import, re-embed or delete a memory in the engine store.",
    byDefault:
      "On under the memory toolset — the one capability that is, because a memory server that cannot write is furniture. Set it to false to force it off."
  },
  {
    id: "sensitive_read",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_SENSITIVE_READ",
    label: "sensitive read",
    what: "Full plaintext: a whole conversation, in-app chat rows, an inbox body, a resume briefing, an export, retained secrets.",
    byDefault: "Off. Enable it for the one shell session that needs it."
  },
  {
    id: "local_write",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_LOCAL_WRITE",
    label: "local write",
    what: "Usage-ledger rows, budget rules, and the daemon-scoped code index.",
    byDefault: "Off. Code-index writes are fail-closed: no daemon, no write, no SQLite fallback."
  },
  {
    id: "cloud_decrypt",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_DECRYPT",
    label: "cloud decrypt",
    what: "Hosted encrypted session search, and on-device decryption of the envelopes it returns.",
    byDefault: "Off, and opt-in twice — it also needs credentials you configure yourself."
  },
  {
    id: "cloud_sync",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_CLOUD_SYNC",
    label: "cloud sync",
    what: "Upload or hard-delete a sealed Project Memory snapshot.",
    byDefault: "Off."
  },
  {
    id: "spawn_process",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_SPAWN",
    label: "spawn",
    what: "Launch a detached local process — a resumed session, or the Claude CLI as an extractor.",
    byDefault: "Off. Nothing here spawns anything until you turn this on."
  },
  {
    id: "memory_llm_read",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_READ",
    label: "model read",
    what: "Let a model answer from your memories, or re-rank recall hits.",
    byDefault: "Off, and additionally needs Pro and a consented provider."
  },
  {
    id: "memory_llm_extract",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_MEMORY_LLM_EXTRACT",
    label: "model extract",
    what: "Let the caller choose a model extractor through the tool argument rather than the operator's environment.",
    byDefault: "Off. A gated transcript is all a model ever sees either way."
  },
  {
    id: "memory_secret_retain",
    env: "OPENBURNBAR_LOCAL_MCP_ENABLE_SECRET_RETAIN",
    label: "secret retain",
    what: "The experimental vault mode: verbatim secret text in an encrypted side table.",
    byDefault: "Off, and never granted by the operator profile. You have to mean it."
  }
];

/* ------------------------------------------------------------------
   11 · The tool atlas. Every `burnbar_*` tool, grouped by the surface
   it belongs to, with the capability that gates it.

   `caps` is not editorial. It is the set of capabilities named at a
   `_capability_denial("<tool>", "<cap>")` site — or a daemon
   `_local_memory_write_authority("<tool>", …)` site — inside that tool
   in tools/openburnbar-mcp/server.py. The copy gate re-parses those
   sites and fails if this list disagrees, in either direction.

   Descriptions: tools/openburnbar-mcp/README.md § Tools where a row
   exists, the tool's own docstring otherwise.
------------------------------------------------------------------- */
export type AtlasGroup = {
  id: string;
  label: string;
  /** One sentence: what this cluster of tools is for. */
  blurb: string;
  /** The section on this page that tells the story, when there is one. */
  section?: string;
};

export const ATLAS_GROUPS: AtlasGroup[] = [
  {
    id: "memory",
    label: "Memory",
    blurb: "Write it, read it, patch it, page through it, take it with you.",
    section: "pipeline"
  },
  {
    id: "lifecycle",
    label: "Review, audit and delete",
    blurb: "The half of a memory system that decides what it is allowed to keep.",
    section: "forget"
  },
  {
    id: "code",
    label: "Code intelligence",
    blurb:
      "The same server indexes the repository and answers symbol, reference and call-graph questions locally.",
    section: "code"
  },
  {
    id: "sessions",
    label: "Sessions across harnesses",
    blurb:
      "Search every past session from every client, then resume one in the harness you prefer.",
    section: "sessions"
  },
  {
    id: "cloud",
    label: "Encrypted cloud",
    blurb: "Opt in twice. Opaque hashes go up; decryption happens on your Mac.",
    section: "boundary"
  },
  {
    id: "project",
    label: "Project Memory snapshots",
    blurb: "The repository briefs the app maintains, readable from any client.",
    section: "server"
  },
  {
    id: "inbox",
    label: "Inbox and plans",
    blurb: "The proactive brief, and the commitments you accepted from it.",
    section: "review"
  },
  {
    id: "spend",
    label: "Spend guardrails",
    blurb: "What the run cost, what the budget says, and what the gate did about it.",
    section: "server"
  },
  {
    id: "plumbing",
    label: "Plumbing",
    blurb: "One tool that answers which file you are actually talking to.",
    section: "setup"
  },
  {
    id: "ministry",
    label: "Ministry",
    blurb:
      "Wand-policy model selection and droid worker commands, with a landed-commit probe when you ask for proof. Not in the memory toolset.",
    section: "server"
  },
  {
    id: "castle",
    label: "Castle",
    blurb:
      "Ministry's selector generalized from one model to runtime-stamped (runtime, model) pairs across CLI Houses. Not in the memory toolset.",
    section: "server"
  },
  {
    id: "bench",
    label: "Bench",
    blurb:
      "Harness and model comparison off recorded stack results — recommendations, frontier, and head-to-head. Not in the memory toolset.",
    section: "server"
  }
];

export type AtlasTool = {
  name: string;
  group: string;
  /** One line. README row where one exists, docstring otherwise. */
  desc: string;
  /** Capabilities named at a denial site inside this tool. Gate-checked. */
  caps: string[];
  /** For a capability whose denial site sits behind a guard, the condition
   *  that reaches it — rendered as a suffix on the chip so the atlas never
   *  publishes a conditional gate as an unconditional requirement.
   *  Gate-checked in both directions: a guarded denial site must carry a
   *  note, and a note must correspond to a guarded denial site. */
  capsWhen?: Record<string, string>;
  /** In MEMORY_TOOLSET — served with BURNBAR_MCP_TOOLSET=memory. Gate-checked. */
  memory: boolean;
};

export const TOOL_ATLAS: AtlasTool[] = [
  /* ── memory ─────────────────────────────────────────────────── */
  {
    name: "burnbar_remember",
    group: "memory",
    desc: "Store one durable memory with kind, scope, tags, entities, metadata, supersedes, expiry and an immutable flag. Secrets redacted, PII kept by default.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_memorize",
    group: "memory",
    desc: "Turn a conversation, a block of text, or facts you already extracted into memories — extraction, gate, injection screen, then ADD / UPDATE / NONE / DELETE. Idempotent per input.",
    caps: ["memory_llm_extract", "memory_write", "spawn_process"],
    capsWhen: {
      memory_llm_extract: "when an LLM extractor is named",
      spawn_process: "when an LLM extractor is named"
    },
    memory: true
  },
  {
    name: "burnbar_memory_extract",
    group: "memory",
    desc: "The same extraction as burnbar_memorize, run by a Pro model on your own quota and keys instead of the local heuristic. Refuses rather than quietly falling back, and stamps every row with what extracted it.",
    caps: ["memory_llm_extract", "memory_write", "spawn_process"],
    capsWhen: { spawn_process: "when the model policy can route to a local CLI" },
    memory: true
  },
  {
    name: "burnbar_recall",
    group: "memory",
    desc: "Hybrid BM25 and vector recall, fused and reranked by salience, with kind, tag, entity, metadata and date filters. Every body comes back wrapped as untrusted data. A recall that returns results appends one label-only audit row naming the ids it served, which is what the timeline reads for \"last helped\".",
    caps: ["sensitive_read"],
    capsWhen: { sensitive_read: "with include_secrets" },
    memory: true
  },
  {
    name: "burnbar_recall_pack",
    group: "memory",
    desc: "A token-budgeted, prompt-ready block of the most relevant memories — one line each, pack sentinels neutralised, only what fits gets reinforced.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_session_briefing",
    group: "memory",
    desc: "An opt-in, token-budgeted briefing for the repo and branch you are starting in. Off unless you turn it on, and it drops whole facts rather than truncating one.",
    caps: ["sensitive_read"],
    memory: true
  },
  {
    name: "burnbar_memory_ask",
    group: "memory",
    desc: "An answer built only from cited memories, or an explicit refusal. Every claim cites a memory id; unknown citations are dropped.",
    caps: ["memory_llm_read"],
    memory: true
  },
  {
    name: "burnbar_memory_get",
    group: "memory",
    desc: "Read one memory by id, optionally with its wrapped history.",
    caps: ["sensitive_read"],
    capsWhen: { sensitive_read: "with include_secrets" },
    memory: true
  },
  {
    name: "burnbar_memory_list",
    group: "memory",
    desc: "Page through memories with filters and ordering — updated, created, salience or access. Quarantined rows stay hidden unless you ask for them.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_update",
    group: "memory",
    desc: "Patch a memory in place. The id stays stable, the change lands in history, and the row is re-embedded.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_memory_history",
    group: "memory",
    desc: "Every change to one memory, with before and after bodies wrapped as untrusted retrieved data.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_timeline",
    group: "memory",
    desc: "One memory's revisions in order, with the device that wrote each one and when the memory last helped a recall. Project-scoped: a foreign id is refused, body and all.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_entities",
    group: "memory",
    desc: "The identifiers, paths, names and handles your memories mention, with counts and example ids.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_relations",
    group: "memory",
    desc: "Heuristic (subject, predicate, object) relations drawn from active memories, optionally filtered by entity.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_export",
    group: "memory",
    desc: "JSON export of your memories. Retained secrets stay behind unless you explicitly ask for them.",
    caps: ["sensitive_read"],
    memory: true
  },
  {
    name: "burnbar_memory_import",
    group: "memory",
    desc: "Import an export, or a plain list of facts. Every value passes the normal gate again on the way in.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_memory_reindex",
    group: "memory",
    desc: "Embed every active memory missing a vector for the current model version, and purge vectors from old versions.",
    caps: ["memory_write"],
    memory: true
  },

  /* ── review, audit and delete ───────────────────────────────── */
  {
    name: "burnbar_memory_review",
    group: "lifecycle",
    desc: "Approve, quarantine or reject. The row is locked for the decision, and a decision made against a stale read is refused rather than applied.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_forget",
    group: "lifecycle",
    desc: "Hard-delete one memory — body, vectors, history, relations and vault — and append a label-only audit event. The daemon copy is forgotten too.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_forget_all",
    group: "lifecycle",
    desc: "Bulk delete for a project, in two steps: a preview that returns a selection token, then a confirmation that is refused if the selection moved underneath you.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_audit_trail",
    group: "lifecycle",
    desc: "The label-only audit hash chain, with chain verification. Labels and hashes, never bodies.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_analytics",
    group: "lifecycle",
    desc: "Counts by kind, scope, sensitivity and review status, plus embedding coverage, vault entries and the active policy.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_memory_doctor",
    group: "lifecycle",
    desc: "Health of the store, encryption, embeddings, policy, audit chain, daemon mirror and code index — including a resumable sweep for secrets sitting in auxiliary fields. Report-only unless you pass apply, which prunes aged orphan bodies and aged parked supersedes and nothing else.",
    caps: ["memory_write"],
    capsWhen: { memory_write: "with apply" },
    memory: true
  },

  {
    name: "burnbar_memory_sync_pull",
    group: "lifecycle",
    desc: "Drain the daemon's inbox of memories your other devices sealed, merge them under last-writer-wins, and acknowledge what landed. Rows whose references have not arrived stay parked for the next pull.",
    caps: ["memory_write"],
    memory: true
  },
  {
    name: "burnbar_project_adopt",
    group: "lifecycle",
    desc: "Join this folder to an existing project id. A .burnbar/project-id file only proposes one — nothing is applied until you confirm, so cloning a repository can never re-scope its memories. The refusal shows both sides: the memories adopting would join, and the ones this folder keeps under its current id and stops seeing.",
    caps: ["memory_write"],
    memory: true
  },

  /* ── code intelligence ──────────────────────────────────────── */
  {
    name: "burnbar_index_project",
    group: "code",
    desc: "Index source files into a local-only, project-partitioned code memory. Gitignore-aware, blob-SHA stamped, and it refuses secret-bearing files before they persist.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "burnbar_watch_project",
    group: "code",
    desc: "Hand reindexing to the daemon: index once, then poll source and git-ref signatures and re-index transactionally when they move.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "burnbar_index_status",
    group: "code",
    desc: "What is indexed for this project, and how much storage it is using.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_search_code",
    group: "code",
    desc: "Lexical and path search over the local index. It reports semanticAvailable=false rather than pretending, until a real local embedding provider is configured.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_context_pack",
    group: "code",
    desc: "A token-budgeted code context pack built from the local index.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_code_context_pack",
    group: "code",
    desc: "The same pack under the name code.* parity clients expect — kept explicit rather than aliased silently.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_get_symbol",
    group: "code",
    desc: "Find a symbol, with the tier that answered — exact LSP, static tree-sitter, or lexical fallback — and blob-staleness evidence attached.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_find_references",
    group: "code",
    desc: "Where a symbol is used across the project, using an exact language server when one is configured and answering.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_call_graph",
    group: "code",
    desc: "Lexical-tier call edges touching one symbol — who calls it, and what it calls.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_diagnostics",
    group: "code",
    desc: "Cached diagnostics for a project. A cached-file tier, and it says so rather than implying a live language server.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_explore",
    group: "code",
    desc: "Index if needed, search, and return a context pack — the one-call version for an agent that has just opened an unfamiliar repository.",
    caps: ["local_write"],
    memory: false
  },

  /* ── sessions across harnesses ──────────────────────────────── */
  {
    name: "burnbar_list_providers",
    group: "sessions",
    desc: "Which harnesses have sessions in the index — Codex, Claude Code, and whatever else you run.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_search_conversations",
    group: "sessions",
    desc: "Full-text search over session titles and transcripts, the same family of queries the app runs.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_semantic_search_conversations",
    group: "sessions",
    desc: "Local deterministic semantic search over indexed session chunks. Returns a structured unavailable rather than empty results when the substrate or a compatible embedding is missing.",
    caps: ["sensitive_read"],
    memory: true
  },
  {
    name: "burnbar_get_conversation",
    group: "sessions",
    desc: "One session in full, including its text, truncated at a limit you set.",
    caps: ["sensitive_read"],
    memory: true
  },
  {
    name: "burnbar_chat_messages",
    group: "sessions",
    desc: "The tail of the in-app assistant conversation, role and content.",
    caps: ["sensitive_read"],
    memory: false
  },
  {
    name: "burnbar_list_resumable_conversations",
    group: "sessions",
    desc: "Recent sessions eligible for resume, with the stable id, the raw provider session id, and whether a native resume is possible at all.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_resume_conversation",
    group: "sessions",
    desc: "A native command hint, or a deterministic briefing that ports the session to a different harness. Print-only by default; the briefing file is written mode 0600.",
    caps: ["sensitive_read"],
    memory: true
  },
  {
    name: "burnbar_spawn_resume",
    group: "sessions",
    desc: "Actually launch that resume as a detached process. Deliberately a second, separate tool call so nothing spawns by accident.",
    caps: ["spawn_process"],
    memory: false
  },

  /* ── encrypted cloud ────────────────────────────────────────── */
  {
    name: "burnbar_cloud_semantic_search_conversations",
    group: "cloud",
    desc: "Hosted encrypted search over your own session-log index. Query trapdoors are derived on your Mac, only opaque hashes are sent, and snippets are decrypted locally.",
    caps: ["cloud_decrypt"],
    memory: false
  },
  {
    name: "burnbar_cloud_get_conversation_body",
    group: "cloud",
    desc: "Download and decrypt one hosted session body that search returned.",
    caps: ["cloud_decrypt"],
    memory: false
  },
  {
    name: "burnbar_cloud_sync_project_memory",
    group: "cloud",
    desc: "Encrypt one Project Memory snapshot and upload it under a vault-derived opaque document id.",
    caps: ["cloud_sync"],
    memory: false
  },
  {
    name: "burnbar_cloud_delete_project_memory",
    group: "cloud",
    desc: "Hard-delete that hosted sealed snapshot and return the backend's content-free tombstone receipt. Local project memory stays authoritative and untouched.",
    caps: ["cloud_sync"],
    memory: false
  },

  /* ── project memory snapshots ───────────────────────────────── */
  {
    name: "burnbar_list_project_memory",
    group: "project",
    desc: "Locally cached repository briefs — slug, freshness, section count, hash. Metadata only.",
    caps: [],
    memory: true
  },
  {
    name: "burnbar_get_project_memory",
    group: "project",
    desc: "One repository brief by slug: local first, hosted as a fallback, decrypted on this machine.",
    caps: ["cloud_decrypt", "sensitive_read"],
    memory: true
  },

  /* ── inbox and plans ────────────────────────────────────────── */
  {
    name: "burnbar_inbox_list",
    group: "inbox",
    desc: "The proactive brief assembled from recent agent sessions, workspace git state and GitHub. Open items by default; ask for resolved ones to read history.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_inbox_get",
    group: "inbox",
    desc: "One inbox item in full: the summary, the evidence behind it, any proposed memories, and the suggested next actions.",
    caps: ["sensitive_read"],
    memory: false
  },
  {
    name: "burnbar_inbox_status",
    group: "inbox",
    desc: "Whether the background analyst actually ran — tick telemetry, skips, and today's spend against its daily budget.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_inbox_plans_list",
    group: "inbox",
    desc: "Founder Plans: the commitments you accepted from inbox suggestions, with lifecycle status and a rolling grade.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_inbox_plans_get",
    group: "inbox",
    desc: "One plan in full — steps with status and grades, linked mission and follow-up ids, audit pointers.",
    caps: ["sensitive_read"],
    memory: false
  },

  /* ── spend guardrails ───────────────────────────────────────── */
  {
    name: "burnbar_recent_usage",
    group: "spend",
    desc: "Recent usage rows: cost, model, provider, session, times.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_project_summary",
    group: "spend",
    desc: "Cost and session totals per project over a rolling window, ranked by spend.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_query_spend",
    group: "spend",
    desc: "Ranked spend by credential, project, model, provider or day, over a day, a week, a month, or all time.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_budget_status",
    group: "spend",
    desc: "Every active budget rule with its current spend, projected period end, and remaining headroom.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_spend_forecast",
    group: "spend",
    desc: "A linear projection over the next horizon from the trailing seven-day average. Reported as an average and a projection, not a prophecy.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_budget_audit",
    group: "spend",
    desc: "What the gate actually did: warnings, blocks, overrides and rule mutations.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_org_spend",
    group: "spend",
    desc: "Cross-seat rollup for an organisation, read from the local copy of the usage table each seat already syncs.",
    caps: [],
    memory: false
  },
  {
    name: "burnbar_set_budget_limit",
    group: "spend",
    desc: "Create or update a budget rule, scoped to a credential, a project, everything, or an organisation.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "burnbar_pause_budget_gate",
    group: "spend",
    desc: "Pause one rule until a timestamp you name. The gate short-circuits to paused for matching requests until then.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "burnbar_resume_budget_gate",
    group: "spend",
    desc: "Cancel a pause and put the rule back into enforcement immediately.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "burnbar_record_hermes_usage",
    group: "spend",
    desc: "Append one usage row to the ledger so a run through your own gateway shows up in the app. Idempotent: the same key never double-counts.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "burnbar_resolve_usage_ledger_path",
    group: "spend",
    desc: "Which ledger file the writer will use. For when the row went somewhere you did not expect.",
    caps: [],
    memory: false
  },

  /* ── plumbing ───────────────────────────────────────────────── */
  {
    name: "burnbar_resolve_db_path",
    group: "plumbing",
    desc: "Which database file is in play, and how it is readable — directly, through the daemon socket, or not at all. Existence is not health, and this says which.",
    caps: [],
    memory: true
  },

  /* ── ministry ───────────────────────────────────────────────── */
  {
    name: "ministry_list_wands",
    group: "ministry",
    desc: "List Headmaster/Pareto wands, or the sanitized local wand store when one exists.",
    caps: [],
    memory: false
  },
  {
    name: "ministry_validate_wands",
    group: "ministry",
    desc: "Validate the local Ministry wand store and show the sanitized would-be result, without writing anything.",
    caps: [],
    memory: false
  },
  {
    name: "ministry_save_wands",
    group: "ministry",
    desc: "Persist a sanitized Ministry wand store. Disabled unless local writes are enabled.",
    caps: ["local_write"],
    memory: false
  },
  {
    name: "ministry_list_launchable",
    group: "ministry",
    desc: "List droid launch candidates from Factory's customModels plus the built-in allowlist.",
    caps: [],
    memory: false
  },
  {
    name: "ministry_provider_quota",
    group: "ministry",
    desc: "Read authenticated local-gateway model quota state through the co-located Factory token.",
    caps: [],
    memory: false
  },
  {
    name: "ministry_select_model_for_wand",
    group: "ministry",
    desc: "Select a model for a Ministry wand by policy; optionally prove it first with a headless landed-commit probe.",
    caps: ["spawn_process"],
    capsWhen: { spawn_process: "with prove_headless" },
    memory: false
  },
  {
    name: "ministry_select_models_for_wand",
    group: "ministry",
    desc: "Select several models for a wand at once, with optional provider diversity and the same headless proof.",
    caps: ["spawn_process"],
    capsWhen: { spawn_process: "with prove_headless" },
    memory: false
  },
  {
    name: "ministry_smoke_probe",
    group: "ministry",
    desc: "Spawn a disposable droid exec probe and prove whether the model can land a commit.",
    caps: ["spawn_process"],
    memory: false
  },
  {
    name: "ministry_build_droid_command",
    group: "ministry",
    desc: "Build a droid exec shell command with namespaced disabled tools and a done marker for the caller to launch.",
    caps: ["spawn_process"],
    capsWhen: { spawn_process: "with prove_headless" },
    memory: false
  },
  {
    name: "ministry_collect_result",
    group: "ministry",
    desc: "Classify a worker's result from its done marker, JSON output, and whether HEAD moved past base.",
    caps: [],
    memory: false
  },
  {
    name: "ministry_cleanup_plan",
    group: "ministry",
    desc: "Return the cleanup commands for a Ministry worker's worktree, branch and scratch files once its result is captured.",
    caps: [],
    memory: false
  },

  /* ── castle ─────────────────────────────────────────────────── */
  {
    name: "castle_list_runtimes",
    group: "castle",
    desc: "List Castle runtime Houses with their install and auth preconditions.",
    caps: [],
    memory: false
  },
  {
    name: "castle_list_launchable",
    group: "castle",
    desc: "List runtime-stamped (runtime, model) launch candidates across the supported CLI Houses.",
    caps: [],
    memory: false
  },
  {
    name: "castle_select_models_for_wand",
    group: "castle",
    desc: "Select Castle (runtime, model) workers for a wand, optionally proving each with a disposable landed-commit probe.",
    caps: ["spawn_process"],
    capsWhen: { spawn_process: "with prove_headless" },
    memory: false
  },
  {
    name: "castle_smoke_probe",
    group: "castle",
    desc: "Run a disposable Castle runtime probe and prove whether it lands a scoped commit.",
    caps: ["spawn_process"],
    memory: false
  },
  {
    name: "castle_build_command",
    group: "castle",
    desc: "Build a wrapped Castle worker command with prompt, result, done, stderr and status sentinels.",
    caps: [],
    memory: false
  },
  {
    name: "castle_collect_result",
    group: "castle",
    desc: "Classify a Castle worker from its done marker, parsed completion and HEAD-vs-base; writes a Swift-readable status record.",
    caps: [],
    memory: false
  },
  {
    name: "castle_status_snapshot",
    group: "castle",
    desc: "Read Castle status records from disk for dashboard and debug surfaces.",
    caps: [],
    memory: false
  },
  {
    name: "castle_seed_worktree_isolation",
    group: "castle",
    desc: "Seed .git/info/exclude with known agent scratch paths before a worker launches into the worktree.",
    caps: [],
    memory: false
  },

  /* ── bench ──────────────────────────────────────────────────── */
  {
    name: "bench_status",
    group: "bench",
    desc: "Report bench.json freshness, stack and cell counts, and arena vote totals.",
    caps: [],
    memory: false
  },
  {
    name: "bench_recommend_stack",
    group: "bench",
    desc: "Recommend harness-and-model stacks for an intent under optional cost, time and confidence constraints; low-sample stacks are disclosed and never ranked first.",
    caps: [],
    memory: false
  },
  {
    name: "bench_compare_stacks",
    group: "bench",
    desc: "Compare two stacks on solution rate, cost and wall time, with confidence-interval overlap.",
    caps: [],
    memory: false
  },
  {
    name: "bench_model_profile",
    group: "bench",
    desc: "Aggregate every recorded stack result for one model across harnesses.",
    caps: [],
    memory: false
  },
  {
    name: "bench_harness_profile",
    group: "bench",
    desc: "Aggregate every recorded stack result for one harness across models.",
    caps: [],
    memory: false
  },
  {
    name: "bench_frontier",
    group: "bench",
    desc: "Return the cost-versus-performance frontier, optionally narrowed by scope.",
    caps: [],
    memory: false
  },
  {
    name: "bench_explain",
    group: "bench",
    desc: "Explain one harness-and-model stack: its rank, confidence interval, sample-size disclosure, and frontier standing.",
    caps: [],
    memory: false
  }
];

/* ------------------------------------------------------------------
   12 · Time. A memory is not a row you overwrite — it is a statement
   with a beginning and, eventually, an end.
   Source: memory_engine/_write.py (valid_from / valid_to /
   superseded_by / supersedes_json / _reinforce),
   tools/openburnbar-mcp/README.md § Structured refusals,
   § Cross-store lifecycle.
------------------------------------------------------------------- */
export type LifecycleEvent = {
  /** What you did. */
  trigger: string;
  /** The engine's decision word, as returned. */
  verdict: string;
  /** What actually happens to the rows. */
  effect: string;
};

export const LIFECYCLE_EVENTS: LifecycleEvent[] = [
  {
    trigger: "You state the same fact again.",
    verdict: "NONE",
    effect:
      "The existing memory is reinforced — access count up, salience up, a reinforcement row in its history. No second copy, and the history records that you said it twice."
  },
  {
    trigger: "The value changes. Same subject, new answer.",
    verdict: "UPDATE",
    effect:
      "The old row gets a valid_to and a superseded_by pointing at the new one. It stops surfacing in recall and stays readable in history for as long as you keep it."
  },
  {
    trigger: "You say it is no longer true.",
    verdict: "DELETE",
    effect:
      "The fact is retired and nothing new is stored. A negation is not a memory, and storing one would put the false statement back into recall."
  },
  {
    trigger: "You revert: A, then B, then A again.",
    verdict: "UPDATE",
    effect:
      "The original row comes back under its original id rather than becoming a third memory. The id an agent cited last month still resolves."
  },
  {
    trigger: "An expired memory turns out to be true again.",
    verdict: "UPDATE · reactivated",
    effect: "The expired row is reactivated rather than duplicated, and says so in the response."
  },
  {
    trigger: "You re-state something you rejected in review.",
    verdict: "NONE · PREVIOUSLY_REJECTED",
    effect:
      "Refused with the reason, not silently re-added. Re-approve it deliberately if you changed your mind."
  },
  {
    trigger: "You edit a memory's text into another memory's text.",
    verdict: "DUPLICATE_BODY",
    effect: "Refused. Two active rows with identical bodies is a bug, not a state."
  }
];

export const TIME_FACTS = [
  {
    label: "valid_from · valid_to",
    body: "Every memory records when it started being true. A retired one records when it stopped, and which memory replaced it. Nothing is overwritten in place — the row that was right last quarter is still there, marked as no longer current."
  },
  {
    label: "Queryable history",
    body: "burnbar_memory_history returns every change to one memory with the before and after bodies, both wrapped as untrusted data, plus who decided — decidedBy is rules or judge:<provider>/<model> — and a short rationale."
  },
  {
    label: "Recency, weighted",
    body: `An event or a todo halves in salience every ${FUSION.halfLifeShortDays} days; everything else takes ${FUSION.halfLifeLongDays}. Memories you actually use get a reinforcement boost, capped at ${FUSION.accessBoostCap}× so a popular memory cannot bury a precise one.`
  },
  {
    label: "Expiry, and immutability",
    body: "A memory can carry an expires_at, and an invalid one is rejected rather than quietly becoming immortal. A memory can also be marked immutable, and then no reconciliation — rules or model — is allowed to retire it."
  }
];

export const TIME_LIMIT =
  "Supersession needs a cue. Without one the engine adds rather than overwrites — which is why the rules-only agreement below is 0.42 and not 0.9. You get two memories and a ranking, not a lost fact. That is the trade we chose, and it is the reason the history and the forget path have to be good.";

/* ------------------------------------------------------------------
   13 · Forget. Source: memory_engine/_read.py forget / forget_all /
   _purge; server.py burnbar_forget / burnbar_forget_all;
   tools/openburnbar-mcp/README.md § Works without the daemon,
   § Cross-store lifecycle; docs/PRIVACY.md:87-93.
------------------------------------------------------------------- */

/** The five tables one burnbar_forget empties, as the tool reports them. */
export const FORGET_PURGED = [
  { id: "memory", note: "the encrypted body and every column of the row itself" },
  { id: "vector", note: "the embedding, for every model version it was ever embedded under" },
  { id: "history", note: "every before/after revision, which also held encrypted bodies" },
  { id: "relations", note: "the extracted subject-predicate-object edges that pointed at it" },
  { id: "vault", note: "the encrypted secret entry, if this memory ever retained one" }
];

export const FORGET_STEPS: { title: string; body: string }[] = [
  {
    title: "It is a delete, not a flag",
    body: "burnbar_forget issues five DELETEs and drops the row, in one transaction. It also deletes the replay receipt that pointed at the memory — a receipt claiming a memory still exists after you deleted it is a lie the engine will not tell — and clears the superseded_by pointer on any row that was waiting behind it."
  },
  {
    title: "The audit event carries labels, never text",
    body: "One event is appended to the hash chain: local hard delete · vault purged · history purged · vectors purged. It proves the deletion happened. It cannot reconstruct what was deleted, because there is nothing in it to reconstruct from."
  },
  {
    title: "The daemon copy goes too",
    body: "A mirrored memory is forgotten by the daemon's own content-derived id, through the signed courier. A memory that was never mirrored reports skipped rather than sending an id the daemon never had. If the daemon is unreachable, a metadata-only tombstone keeps the id and the original project path so the forget can be retried, and it clears only once the daemon confirms the row is gone."
  },
  {
    title: "Bulk delete asks twice, and can refuse",
    body: "burnbar_forget_all runs a preview first: it returns how many rows match and a selection token. The confirmation needs both the literal string DELETE and that token, and is refused with SELECTION_CHANGED if the matching rows moved in between. You cannot delete a set you did not see."
  },
  {
    title: "The lifecycle forgets too",
    body: "Supersession, a negation, a quarantine decision and a confirmed bulk delete each forget the corresponding daemon mirror. A failed daemon delete keeps only the id tombstone and stays retryable after the local row is already gone."
  },
  {
    title: "The hosted copy has its own delete",
    body: "burnbar_cloud_delete_project_memory hard-deletes one sealed Project Memory snapshot from cloud storage by its vault-derived opaque id, and returns the backend's content-free tombstone receipt. Local project memory stays authoritative and unchanged. In the app's encrypted backup lane, deleting a memory writes a forget receipt that carries only opaque hashes and a coarse reason."
  }
];

export const FORGET_LIMIT =
  "A forget reaches the engine store, the daemon mirror and — for a Project Memory snapshot — the sealed hosted copy. It cannot reach a JSON export you already took, a transcript on disk that the memory was extracted from, or a copy an agent pasted into a file. Deleting the memory is not deleting the source, and the page would rather say so than let you assume otherwise.";

/* ------------------------------------------------------------------
   14 · Review, analytics, audit. What oversight actually looks like.
   Source: server.py burnbar_memory_review / burnbar_memory_list /
   burnbar_memory_analytics / burnbar_audit_trail /
   burnbar_memory_doctor / burnbar_inbox_*;
   tools/openburnbar-mcp/README.md § Untrusted recall boundary.
------------------------------------------------------------------- */
export const REVIEW_SURFACES: { tool: string; title: string; body: string }[] = [
  {
    tool: "burnbar_memory_list",
    title: "The quarantine queue is just a filter",
    body: 'Pass review_status="quarantined" and you get the rows the injection screen held back, with every free-form value wrapped as untrusted data — including the metadata keys, because a key can carry an instruction as easily as a value. There is no separate inbox to learn: it is the same paging tool with one argument.'
  },
  {
    tool: "burnbar_memory_review",
    title: "Deciding is locked and versioned",
    body: "Approve, quarantine or reject. The row is locked for the duration of the decision, and if you pass the updatedAt you read, a memory that changed underneath you refuses the decision instead of applying it to something you did not look at."
  },
  {
    tool: "burnbar_memory_analytics",
    title: "The shape of what you have",
    body: "Counts by kind, scope, sensitivity and review status; how many rows have a vector for the current model version; how many vault entries exist; and the secret and PII policy actually in force. This is the tool that tells you the store drifted before recall does."
  },
  {
    tool: "burnbar_audit_trail",
    title: "A hash chain you can verify",
    body: "Every write, review and delete appended one label-only event. This returns the chain with its verification result. Labels and hashes — a tamper check that is not itself a second copy of your memories."
  },
  {
    tool: "burnbar_memory_doctor",
    title: "Health, plus a sweep for what slipped through",
    body: "Store, encryption, embeddings, policy, audit chain, daemon mirror and code index in one call — and a resumable scan of auxiliary fields for secret shapes, so a credential that landed in a tag before the gate covered tags is something you can find rather than something you assume never happened."
  },
  {
    tool: "burnbar_inbox_list · burnbar_inbox_plans_list",
    title: "And the brief the app writes for you",
    body: "If you run the OpenBurnBar app, its proactive brief and the Founder Plans you accepted from it are readable from the same server: the item, its evidence, the memories it proposes, and what it suggests you do. Bodies need the sensitive-read capability; the listing does not."
  }
];

export const REVIEW_LIMIT =
  "Nothing auto-approves. A quarantined memory stays out of recall until a human decides, which is the correct default and also means an ignored queue is a queue that never surfaces. burnbar_memory_analytics counts it for you; it will not decide for you.";

/* ------------------------------------------------------------------
   15 · Code intelligence. Source: tools/openburnbar-mcp/README.md
   § Local memory engine (the Project Code Memory paragraphs) and the
   docstrings on the eleven code tools in server.py.
------------------------------------------------------------------- */
export const CODE_TIERS = [
  {
    id: "exact_lsp",
    label: "exact_lsp",
    status: "opt-in" as const,
    body: "A real language server answers. Configure OPENBURNBAR_CODE_LSP_COMMANDS with a map of language to command — pyright-langserver, sourcekit-lsp — and symbol and reference lookups use it when it answers for the current buffer."
  },
  {
    id: "static_tree_sitter",
    label: "static_tree_sitter",
    status: "built" as const,
    body: "A Rust helper parses Swift, TypeScript/TSX and Python into a static tier. It is built by ./setup.sh, not by the memory-only bootstrap, so a memory-first install starts one tier down."
  },
  {
    id: "lexical_fallback",
    label: "lexical_fallback",
    status: "always" as const,
    body: "Code-aware lexical matching over the index. Always available, always labelled as itself. Every answer names the tier that produced it, so you never have to guess whether you are reading a compiler's opinion or a regular expression's."
  }
];

export const CODE_FACTS: { title: string; body: string }[] = [
  {
    title: "It indexes your repository, locally, and refuses files with secrets in them",
    body: "burnbar_index_project walks the project with Git's own exclude-standard ignore semantics when it is a worktree, stamps each file with its blob and commit SHA, and runs the same Swift/Python secret-scanner corpus the memory gate uses — a file that carries a credential is rejected before it is persisted, not redacted afterwards."
  },
  {
    title: "Re-indexing is a delta, and moving the checkout does not orphan it",
    body: "A manifest tracks what is unchanged and what is gone, so a second index is cheap. Project identity is a Git fingerprint with path aliases, so a repository you moved or re-cloned keeps its index rather than starting again."
  },
  {
    title: "Writes are fail-closed and daemon-owned",
    body: "burnbar_index_project, burnbar_watch_project and burnbar_explore need the daemon socket and the local-write capability. If the daemon is not there they refuse — there is deliberately no direct-SQLite fallback for a write path that owns a shared index."
  },
  {
    title: "Ask a question, get a budgeted pack",
    body: "burnbar_explore indexes if it has to, searches, and returns a token-budgeted context pack in one call. burnbar_context_pack and burnbar_code_context_pack build the same pack when you already know what you want. Returned source text is wrapped as untrusted content, exactly like a memory body."
  }
];

export const CODE_LIMIT =
  "Semantic code search is off until a real local embedding provider is configured — burnbar_search_code reports semanticAvailable=false rather than returning lexical hits dressed as semantic ones. Call graphs are lexical-tier. References and symbols reach the exact tier only for languages you gave a language server. This is a strong local index, not a compiler.";

/* ------------------------------------------------------------------
   16 · Sessions across harnesses. Source: server.py
   burnbar_search_conversations / burnbar_semantic_search_conversations /
   burnbar_list_resumable_conversations / burnbar_resume_conversation /
   burnbar_spawn_resume; README § Local memory engine (the resume
   paragraph) and § Tools.
------------------------------------------------------------------- */
export const SESSION_FACTS: { title: string; body: string }[] = [
  {
    title: "One index, every harness",
    body: "burnbar_search_conversations runs full-text search over the titles and transcripts of the sessions OpenBurnBar has indexed — Codex, Claude Code, and whatever else you run — from whichever client you happen to be in. burnbar_list_providers tells you which harnesses are actually in there."
  },
  {
    title: "Semantic search that admits when it cannot",
    body: 'burnbar_semantic_search_conversations searches indexed session chunks deterministically and locally. When the semantic tables or a compatible embedding version are missing it returns a structured unavailable — a named condition you can act on, not an empty result set you would read as "no matches".'
  },
  {
    title: "Resume it in a different harness",
    body: "burnbar_list_resumable_conversations marks which sessions the source provider can resume natively. burnbar_resume_conversation returns one of three stable shapes: a native command hint, a deterministic cross-harness briefing that ports the session somewhere else, or a structured error. The briefing file is written mode 0600."
  },
  {
    title: "Nothing launches itself",
    body: "burnbar_resume_conversation is print-only by default and keeps plaintext on the device. Actually starting the process is burnbar_spawn_resume — a separate tool, gated by the spawn capability, which is off unless you turn it on. An agent has to decide to spawn, out loud, in a second call."
  }
];

export const SESSION_LIMIT =
  "This reads the index OpenBurnBar builds, so a harness has to be one the app parses. Full session plaintext, in-app chat rows and a ported briefing all need the sensitive-read capability, which is off by default. And a ported resume is a briefing, not a state transfer — the new harness gets a faithful account of the old session, not its internals.";

/* ------------------------------------------------------------------
   17 · The rest of the server. Honest, at the level the README
   documents it. Source: tools/openburnbar-mcp/README.md § Tools,
   § Castle multi-runtime fan-out, § Hermes proxy sidecar, § Local
   memory engine (the ledger writer paragraph).
------------------------------------------------------------------- */
export type ServerSurface = {
  id: string;
  label: string;
  tools: string;
  body: string;
  /** The honest edge on this surface. */
  edge: string;
  source: string;
};

export const SERVER_SURFACES: ServerSurface[] = [
  {
    id: "spend",
    label: "Spend and budget guardrails",
    tools: "12 tools",
    body: "Ranked spend by credential, project, model, provider or day. Every active budget rule with its current burn, projected period end and remaining headroom. A linear forecast from the trailing seven-day average. The audit of what the gate actually did — warnings, blocks, overrides, rule changes. And the three write tools that set a limit, pause a gate until a timestamp, or put it back into enforcement.",
    edge: "The writer is daemon-first: it sends the row through the daemon's RPC so the idempotency cache stays consistent, and falls back to a file-locked append when the daemon is offline. Either way the same idempotency key never double-counts. Enforcement itself is the daemon's job, not the MCP's.",
    source: "tools/openburnbar-mcp/README.md § Tools; § Local memory engine"
  },
  {
    id: "hermes",
    label: "The Hermes proxy sidecar",
    tools: "hermes_proxy.py",
    body: "A stdlib-only, OpenAI-compatible proxy that sits in front of your own gateway and writes a usage row for every completed response. SSE streams, tool calls, auth and model listings are forwarded verbatim; point your client at the proxy instead of the gateway and the spend shows up in OpenBurnBar without changing anything else.",
    edge: "When the upstream response carries no usage block, the default is to record a low-confidence estimate rather than nothing, and to label it as one. Pass --no-estimate if you would rather have a gap than a guess.",
    source: "tools/openburnbar-mcp/README.md § Hermes proxy sidecar"
  },
  {
    id: "castle",
    label: "Castle multi-runtime fan-out",
    tools: `${ORCHESTRATION_TOOL_COUNT} tools, in the atlas under their own headings`,
    body: "The same server carries the tooling that fans work out across coding-agent runtimes and grades the result — Castle across CLI Houses, Ministry for droid workers specifically, Bench for scoring the resulting stacks against each other. A worker counts as landed only when three things agree: the done marker exists, the runtime's own parser says the run did not error, and the worktree HEAD differs from the recorded base SHA.",
    edge: "That triple is the whole point. A dashboard turning green off a process exit code or a generic completed phase is a dashboard that lies; the status record AgentLens reads carries the commit verdict, not the exit status. These tools orchestrate and grade agents rather than serve your memory, which is why the atlas groups them under Castle, Ministry and Bench instead of folding them into the memory surfaces — not why they are left off it.",
    source: "tools/openburnbar-mcp/README.md § Castle multi-runtime fan-out; docs/THE_CASTLE.md"
  },
  {
    id: "project",
    label: "Project Memory snapshots",
    tools: "2 local + 2 hosted",
    body: "The repository briefs the app maintains — sections, freshness, source counts, a content hash — listed and read from any MCP client. A snapshot resolves local first and falls back to the hosted encrypted copy, which is decrypted on this machine.",
    edge: "The two hosted tools are grouped under Encrypted cloud in the atlas rather than here, because what gates them is the cloud capability set, not the snapshot. Cloud sync and cloud delete are separate capabilities from cloud decrypt, and all three are off by default. Uploads carry sealed payloads under vault-derived opaque document ids; the hosted side never sees a project name.",
    source: "tools/openburnbar-mcp/README.md § Tools; § Local memory engine"
  }
];

/* ------------------------------------------------------------------
   18 · Where this runs. Stated exactly as `main` supports it.
   Source: tools/openburnbar-mcp/README.md § Setup, § Support level,
   § Local memory engine.
------------------------------------------------------------------- */
export const PLATFORMS = {
  supported: [
    {
      label: "macOS",
      status: "supported" as const,
      body: "The whole surface. The store defaults to the macOS Application Support directory, the daemon mirror and the signed couriers are macOS, and the Pro model path reads its policy through a Keychain-backed gateway on this machine."
    },
    {
      label: "The engine itself",
      status: "portable" as const,
      body: "Plain Python — 3.11 or newer, 3.12 preferred — with no Rust toolchain and no Cargo for the memory-only bootstrap. OPENBURNBAR_MEMORY_DB_PATH moves the store anywhere you like. Nothing in the engine is macOS-specific, and that is a description of the code, not a support claim."
    },
    {
      label: "Windows and Linux",
      status: "unsupported" as const,
      body: "Not supported, not tested, not claimed. There is a Linux port plan in the repository; a plan is not a platform, and we would rather you found that out here than after an install."
    }
  ],
  supportLevel:
    "OpenBurnBar treats the local MCP as adjacent tooling: public, useful for local developer workflows, not required to build or run the macOS app, daemon, CLI or editor extension — and best-effort supported compared with those core surfaces.",
  source: "tools/openburnbar-mcp/README.md § Setup; § Support level"
} as const;

/* ------------------------------------------------------------------
   19 · Packs and answers — the "hand the agent a budget" surface.
   Source: tools/openburnbar-mcp/README.md § Structured refusals
   (the pack budget paragraph) and § Ask my memory.
------------------------------------------------------------------- */
export const PACKS = [
  {
    tool: "burnbar_recall_pack",
    title: "A block, not a result set",
    body: "The most relevant memories, serialized into one prompt-ready block inside a token budget you set. The budget covers the whole envelope, each memory stays on one line, pack sentinels inside a body are neutralised so a memory cannot forge the wrapper, and only the memories that actually fit are reinforced. The floor is 192 tokens: the envelope plus one truncated line."
  },
  {
    tool: "burnbar_context_pack · burnbar_code_context_pack",
    title: "The same idea for code",
    body: "A budgeted pack of the most relevant code from the local index, with the source text wrapped as untrusted content."
  },
  {
    tool: "burnbar_memory_ask",
    title: "An answer, with citations or a refusal",
    body: "Up to twelve approved memories — never injection-labelled ones — are listed to a model as numbered untrusted data. What comes back is an answer plus citations, each naming a memory id, and a groundedness verdict: grounded when every citation is one of the listed memories, partial when unknown ones were dropped, refused when nothing valid was left. An answer carrying wrapper sentinels or a tool call is rejected outright and replaced by the refusal. An empty pack refuses without calling a model at all."
  }
];
