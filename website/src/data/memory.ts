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
export const MEMORY_TOOL_COUNT = 32;

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
    body: "Stores the verbatim text in an encrypted vault table, keeps a redacted searchable body in the main store, and hides the memory from default recall. It needs its own capability flag that the operator profile never grants, and reading it back needs sensitive_read plus include_secrets. Retained memories are never mirrored, never exported by default, and never leave the device."
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
    pin: "tests/test_eval_extraction.py — every row's raw column must be true",
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
    note: "This is the entry the BurnBar checkout already ships. Copy it into any other project to give that project's sessions the same memory."
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
    expect: `openburnbar appears and reports ${MEMORY_TOOL_COUNT} tools.`,
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
    title: "macOS paths by default",
    body: "The store defaults to the macOS Application Support directory. OPENBURNBAR_MEMORY_DB_PATH moves it, and the engine itself is plain Python 3.11+.",
    source: "tools/openburnbar-mcp/README.md § Local memory engine"
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
