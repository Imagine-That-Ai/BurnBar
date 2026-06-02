import { createHash } from "node:crypto";
export interface ResumeFirestore {
  doc(documentPath: string): {
    get(): Promise<{
      id?: string;
      exists: boolean;
      data(): Record<string, unknown> | undefined;
      get?(field: string): unknown;
    }>;
  };
  collection(collectionPath: string): {
    where(field: string, op: FirebaseFirestore.WhereFilterOp, value: unknown): ResumeQuery;
    orderBy(field: string, direction?: FirebaseFirestore.OrderByDirection): ResumeQuery;
    limit(count: number): ResumeQuery;
    get(): Promise<{ docs: ResumeDoc[] }>;
  };
}

interface ResumeQuery {
  where(field: string, op: FirebaseFirestore.WhereFilterOp, value: unknown): ResumeQuery;
  orderBy(field: string, direction?: FirebaseFirestore.OrderByDirection): ResumeQuery;
  limit(count: number): ResumeQuery;
  get(): Promise<{ docs: ResumeDoc[] }>;
}

interface ResumeDoc {
  id: string;
  exists?: boolean;
  data(): Record<string, unknown> | undefined;
  get(field: string): unknown;
}

interface ResumeArgs {
  provider?: unknown;
  project?: unknown;
  since?: unknown;
  limit?: unknown;
}

interface ResumeConversationArgs {
  session_id?: unknown;
  tokenHashes?: unknown;
  semanticHashes?: unknown;
  provider?: unknown;
  projectName?: unknown;
  target_harness?: unknown;
  target_model?: unknown;
  max_tokens?: unknown;
}

const NATIVE_HOSTED_PROVIDERS = new Set(["Claude Code", "Codex"]);
const HEX_32_128 = /^[a-f0-9]{32,128}$/u;
const SEALED_TEXT_KEYS = ["algorithm", "keyVersion", "nonce", "ciphertext", "tag"] as const;

export async function listResumable(db: ResumeFirestore, uid: string, args: ResumeArgs) {
  const limit = boundedInt(args.limit, 20, 1, 50);
  let query = db.collection(`users/${uid}/cloud_search_documents`);
  if (typeof args.provider === "string" && args.provider.trim()) {
    query = query.where("provider", "==", args.provider.trim());
  }
  if (typeof args.project === "string" && args.project.trim()) {
    query = query.where("projectName", "==", args.project.trim());
  }
  if (typeof args.since === "string" && args.since.trim()) {
    const since = new Date(args.since);
    if (!Number.isNaN(since.valueOf())) {
      query = query.where("endTime", ">=", since);
    }
  }

  const snap = await query.orderBy("endTime", "desc").limit(limit).get();
  return {
    items: snap.docs.map((doc) => {
      const data = doc.data() ?? {};
      const provider = stringField(data.provider);
      const sessionID = stringField(data.sessionId) || stringField(data.sourceID) || doc.id;
      return {
        id: doc.id,
        session_id: sessionID,
        source_id: stringField(data.sourceID) || doc.id,
        provider,
        project_name: stringField(data.projectName),
        model: stringField(data.model),
        started_at: timestampISO(data.startTime),
        last_message_at: timestampISO(data.endTime),
        can_resume_native: NATIVE_HOSTED_PROVIDERS.has(provider) && !!sessionID && !sessionID.includes("/"),
        summary_title_sealed: canonicalSealedText(data.sealedTitle),
        decrypt_mode: "local_decrypt_shim"
      };
    })
  };
}

export async function resumeConversation(db: ResumeFirestore, uid: string, args: ResumeConversationArgs) {
  const sessionID = typeof args.session_id === "string" ? args.session_id.trim() : "";
  let found = sessionID
    ? await findConversation(db, uid, sessionID)
    : { kind: "none" as const };
  if (found.kind === "none" && hasOpaqueQuery(args)) {
    found = await findConversationByOpaqueQuery(db, uid, args);
  }
  if (found.kind === "none") {
    return error(
      sessionID ? "session_not_found" : "resume_query_not_found",
      sessionID
        ? "Run burnbar_list_resumable_conversations to find a valid session id."
        : "No hosted memory matched those local query hashes. Try a more specific /obbresume query or pass a session id."
    );
  }
  if (found.kind === "ambiguous") {
    return {
      kind: "error" as const,
      code: "ambiguous_session",
      session_id: sessionID,
      matches: found.matches,
      recovery: "Pass the hosted document id or a unique composite source id."
    };
  }

  const doc = found.doc;
  const data = doc.data() ?? {};
  const chunks = await db
    .collection(`users/${uid}/cloud_search_chunks`)
    .where("documentID", "==", doc.id)
    .orderBy("ordinal", "asc")
    .limit(50)
    .get();

  const sealedTrail = chunks.docs
    .map((chunk) => chunk.get("sealedSnippet"))
    .map((value) => canonicalSealedText(value))
    .filter((value) => value !== undefined);

  return {
    kind: "ported_sealed" as const,
    target_harness: stringField(args.target_harness) || stringField(data.provider),
    target_model: stringField(args.target_model) || undefined,
    header_plain: {
      provider: stringField(data.provider),
      model: stringField(data.model),
      project_name: stringField(data.projectName),
      started_at: timestampISO(data.startTime),
      last_message_at: timestampISO(data.endTime)
    },
    sealed: {
      summary: canonicalSealedText(data.sealedSummary ?? data.sealedBodyPreview),
      summary_title: canonicalSealedText(data.sealedTitle),
      context: canonicalSealedText(data.sealedContext ?? data.sealedBodyPreview),
      trail_chunks: sealedTrail,
      hand_off: canonicalSealedText(data.sealedHandOff ?? data.sealedBodyPreview)
    },
    trail_chunk_count: sealedTrail.length,
    body_hashes: sealedTrail.map((chunk) => sha256StableJSON(chunk)),
    decrypt_mode: "local_decrypt_shim",
    max_tokens: boundedInt(args.max_tokens, 8000, 1024, 32000)
  };
}

function canonicalSealedText(value: unknown): Record<string, unknown> | undefined {
  if (typeof value !== "object" || value === null || Array.isArray(value)) return undefined;
  const envelope = value as Record<string, unknown>;
  if (envelope.algorithm !== "AES-256-GCM" || typeof envelope.keyVersion !== "number") return undefined;
  for (const key of ["nonce", "ciphertext", "tag"] as const) {
    if (typeof envelope[key] !== "string") return undefined;
  }
  return Object.fromEntries(SEALED_TEXT_KEYS.map((key) => [key, envelope[key]]));
}

async function findConversation(db: ResumeFirestore, uid: string, sessionID: string): Promise<
  | { kind: "one"; doc: ResumeDoc }
  | { kind: "none" }
  | { kind: "ambiguous"; matches: string[] }
> {
  if (/^[A-Za-z0-9_.:-]+$/u.test(sessionID)) {
    const direct = await db.doc(`users/${uid}/cloud_search_documents/${sessionID}`).get();
    if (direct.exists) {
      return { kind: "one", doc: snapshotAsDoc(sessionID, direct) };
    }
  }

  const bySession = await db
    .collection(`users/${uid}/cloud_search_documents`)
    .where("sessionId", "==", sessionID)
    .limit(2)
    .get();
  if (bySession.docs.length === 1) return { kind: "one", doc: bySession.docs[0] };
  if (bySession.docs.length > 1) return { kind: "ambiguous", matches: bySession.docs.map((doc) => doc.id) };

  const bySource = await db
    .collection(`users/${uid}/cloud_search_documents`)
    .where("sourceID", "==", sessionID)
    .limit(2)
    .get();
  if (bySource.docs.length === 1) return { kind: "one", doc: bySource.docs[0] };
  if (bySource.docs.length > 1) return { kind: "ambiguous", matches: bySource.docs.map((doc) => doc.id) };
  return { kind: "none" };
}

async function findConversationByOpaqueQuery(db: ResumeFirestore, uid: string, args: ResumeConversationArgs): Promise<
  | { kind: "one"; doc: ResumeDoc }
  | { kind: "none" }
  | { kind: "ambiguous"; matches: string[] }
> {
  const tokenHashes = hashes(args.tokenHashes, 10);
  const semanticHashes = hashes(args.semanticHashes, 12);
  if (tokenHashes.length === 0 && semanticHashes.length === 0) {
    return { kind: "none" };
  }

  const provider = stringField(args.provider);
  const projectName = stringField(args.projectName);
  const candidates = new Map<string, { documentID: string; score: number }>();
  await collectPostingMatches(db, uid, tokenHashes, "token", provider, projectName, candidates);
  await collectPostingMatches(db, uid, semanticHashes, "semantic", provider, projectName, candidates);

  const ranked = Array.from(candidates.values()).sort((a, b) => b.score - a.score || a.documentID.localeCompare(b.documentID));
  if (ranked.length === 0) return { kind: "none" };
  if (ranked.length > 1 && ranked[0].score === ranked[1].score) {
    return { kind: "ambiguous", matches: ranked.slice(0, 5).map((candidate) => candidate.documentID) };
  }

  const direct = await db.doc(`users/${uid}/cloud_search_documents/${ranked[0].documentID}`).get();
  if (!direct.exists) return { kind: "none" };
  return { kind: "one", doc: snapshotAsDoc(ranked[0].documentID, direct) };
}

async function collectPostingMatches(
  db: ResumeFirestore,
  uid: string,
  inputHashes: string[],
  kind: "token" | "semantic",
  provider: string,
  projectName: string,
  candidates: Map<string, { documentID: string; score: number }>
) {
  if (inputHashes.length === 0) return;
  const requested = new Set(inputHashes);
  let query = db
    .collection(`users/${uid}/cloud_search_postings`)
    .where("postingKey", "in", inputHashes.map((hash) => `${kind}_${hash}`));
  if (provider) query = query.where("provider", "==", provider);
  const snap = await query.limit(50).get();
  for (const posting of snap.docs) {
    const hash = posting.get("hash");
    const documentID = posting.get("documentID");
    if (posting.get("kind") !== kind || typeof hash !== "string" || !requested.has(hash) || typeof documentID !== "string") {
      continue;
    }
    if (projectName && posting.get("projectName") !== projectName) continue;
    const current = candidates.get(documentID) ?? { documentID, score: 0 };
    current.score += kind === "token" ? 2 : 1;
    candidates.set(documentID, current);
  }
}

function snapshotAsDoc(id: string, snap: { data(): Record<string, unknown> | undefined; get?(field: string): unknown }): ResumeDoc {
  return {
    id,
    data: () => snap.data() ?? {},
    get(field: string) {
      if (snap.get) return snap.get(field);
      return (snap.data() ?? {})[field];
    }
  };
}

function boundedInt(value: unknown, fallback: number, min: number, max: number): number {
  const parsed = Math.floor(Number(value ?? fallback));
  if (!Number.isFinite(parsed)) return fallback;
  return Math.max(min, Math.min(parsed, max));
}

function stringField(value: unknown): string {
  return typeof value === "string" ? value : "";
}

function hashes(raw: unknown, max: number): string[] {
  if (!Array.isArray(raw)) return [];
  const seen = new Set<string>();
  const result: string[] = [];
  for (const item of raw) {
    if (typeof item !== "string" || !HEX_32_128.test(item) || seen.has(item)) continue;
    seen.add(item);
    result.push(item);
    if (result.length >= max) break;
  }
  return result;
}

function hasOpaqueQuery(args: ResumeConversationArgs): boolean {
  return hashes(args.tokenHashes, 1).length > 0 || hashes(args.semanticHashes, 1).length > 0;
}

function timestampISO(value: unknown): string | null {
  if (value instanceof Date) return value.toISOString();
  if (typeof value === "string") return value;
  const date = firestoreTimestampToDate(value);
  if (date) return date.toISOString();
  return null;
}

function firestoreTimestampToDate(value: unknown): Date | null {
  if (typeof value !== "object" || value === null) return null;
  const toDate = Reflect.get(value, "toDate");
  if (typeof toDate !== "function") return null;
  const date = toDate.call(value);
  return date instanceof Date && !Number.isNaN(date.valueOf()) ? date : null;
}

function sha256StableJSON(value: unknown): string {
  return createHash("sha256").update(stableJSON(value)).digest("hex");
}

function isPlainRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

function stableJSON(value: unknown): string {
  if (value === null || typeof value !== "object") return JSON.stringify(value);
  if (Array.isArray(value)) return `[${value.map(stableJSON).join(",")}]`;
  if (!isPlainRecord(value)) return JSON.stringify(value);
  return `{${Object.keys(value).sort().map((key) => `${JSON.stringify(key)}:${stableJSON(value[key])}`).join(",")}}`;
}

function error(code: string, recovery: string) {
  return { kind: "error" as const, code, recovery };
}
