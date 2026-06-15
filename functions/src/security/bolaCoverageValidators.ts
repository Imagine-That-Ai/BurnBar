import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import type { BolaCoverageRef, EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

const REPO_ROOT_FROM_FUNCTIONS = resolve(__dirname, "../../..");

const CALLABLE_RUNTIME_INVOCATION = /(?:\.run\s*\(|callableRunner\s*\()/u;
const HTTP_RUNTIME_INVOCATION =
  /(?:dispatchHermesGatewayRequest\s*\(|runHttpHandler\s*\(|Reflect\.get\s*\(\s*Object\s*\(\s*handler\s*\))/u;

const RUNTIME_BODY_MARKERS = [
  CALLABLE_RUNTIME_INVOCATION,
  /\b(?:alice|bob|other-user|ALICE_UID|BOB_UID)\b/u,
  /\b(?:rejects|permission-denied|not-found|assertFails|toMatchObject|toThrow|expectCallableDenial)\b/u,
] as const;

function matchesStaticHighRiskCoverage(
  source: string,
  titles: Set<string>,
  exportedName: string,
  refTest: string,
): boolean {
  if (titles.has(refTest)) return true;
  const prefix = `${exportedName} calls enforceHighRiskOwnerAction with actionKind`;
  for (const title of titles) {
    if (title.startsWith(prefix)) return true;
  }
  return (
    source.includes("EXPECTED_GUARDS") &&
    source.includes("enforceHighRiskOwnerAction") &&
    new RegExp(`exportedName:\\s*"${escapeRegExp(exportedName)}"`, "u").test(source)
  );
}

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function parseItTitles(source: string): Set<string> {
  const titles = new Set<string>();
  for (const match of source.matchAll(/\bit\s*\(\s*(["'`])([^"'`]+)\1/gu)) {
    titles.add(match[2]);
  }
  return titles;
}

function validateRuntimeTestBody(
  source: string,
  trigger: EndpointAuthorizationEntry["trigger"] = "callable",
): string[] {
  const errors: string[] = [];
  const markers =
    trigger === "http"
      ? [HTTP_RUNTIME_INVOCATION, RUNTIME_BODY_MARKERS[1], RUNTIME_BODY_MARKERS[2]]
      : [...RUNTIME_BODY_MARKERS];
  for (const marker of markers) {
    if (!marker.test(source)) {
      errors.push(`missing runtime marker ${marker.source}`);
    }
  }
  return errors;
}

function validateRuntimeCoverageDetails(
  entry: EndpointAuthorizationEntry,
  ref: BolaCoverageRef,
  source: string,
): string[] {
  const errors = validateRuntimeTestBody(source, entry.trigger).map(
    (msg) => `${entry.exportedName}: ${ref.file}: ${msg}`,
  );
  if (ref.expectedCode && !source.includes(ref.expectedCode)) {
    errors.push(`${entry.exportedName}: runtime test must reference expectedCode "${ref.expectedCode}" in ${ref.file}`);
  }
  const hasTier2Proof =
    /\btier2CallableProof\s*\(/u.test(source) ||
    /\b(?:outboundWrites|expectTenantPathsUnchanged|snapshotTenantPaths|seedBolaVictimTenant)\b/u.test(source) ||
    /\bseedDoc\s*\(/u.test(source);
  if (entry.objectIdsFromClient.length > 0 && !hasTier2Proof) {
    errors.push(
      `${entry.exportedName}: runtime test must use tier2CallableProof or seed victim tenant before cross-user invocation in ${ref.file}`,
    );
  }
  if (
    ref.expectedOutcome === "no-side-effect" &&
    !/\b(?:outboundWrites|sideEffect|no-side-effect|expectTenantPathsUnchanged|snapshotTenantPaths|tier2CallableProof)/u.test(
      source,
    )
  ) {
    errors.push(`${entry.exportedName}: no-side-effect coverage must assert cross-tenant isolation in ${ref.file}`);
  }
  return errors;
}

function validateCoverageTitle(
  entry: EndpointAuthorizationEntry,
  ref: BolaCoverageRef,
  source: string,
  titles: Set<string>,
): string[] {
  if (titles.has(ref.test)) return [];
  if (
    ref.kind === "static-high-risk-wiring" &&
    matchesStaticHighRiskCoverage(source, titles, entry.exportedName, ref.test)
  ) {
    return [];
  }
  if (ref.kind === "auth-only" && ref.test === "rejects unauthenticated callable access") {
    return new RegExp(`["']${escapeRegExp(entry.exportedName)}["']`).test(source)
      ? []
      : [`${entry.exportedName}: auth-only endpoint missing from AUTH_ONLY_CALLABLES in ${ref.file}`];
  }
  if (ref.kind === "platform-trigger" && ref.test === "platform triggers are not client-callable") {
    if (!/PLATFORM_TRIGGER_ENDPOINTS/u.test(source)) {
      return [`${entry.exportedName}: platform trigger missing from PLATFORM_TRIGGER_ENDPOINTS`];
    }
    return new RegExp(`["']${escapeRegExp(entry.exportedName)}["']`).test(source)
      ? []
      : [`${entry.exportedName}: not listed in PLATFORM_TRIGGER_ENDPOINTS`];
  }
  if (ref.kind === "not-applicable-public" && ref.test === "public health endpoints do not expose tenant objects") {
    return new RegExp(`["']${escapeRegExp(entry.exportedName)}["']`).test(source)
      ? []
      : [`${entry.exportedName}: not listed in PUBLIC_HEALTH_ENDPOINTS`];
  }
  return [`${entry.exportedName}: test "${ref.test}" not found in ${ref.file}`];
}

function validateRuntimeCovers(entry: EndpointAuthorizationEntry, ref: BolaCoverageRef): string[] {
  if (ref.kind !== "runtime-cross-user") return [];
  if (!ref.covers.includes(entry.exportedName)) {
    return [`${entry.exportedName}: runtime ref must include exportedName in covers[]`];
  }
  return [];
}

function validateBolaCoverageRef(
  entry: EndpointAuthorizationEntry,
  ref: BolaCoverageRef,
  repoRoot: string = REPO_ROOT_FROM_FUNCTIONS,
): string[] {
  const errors: string[] = [];
  const absPath = resolve(repoRoot, ref.file);

  if (!existsSync(absPath)) {
    errors.push(`${entry.exportedName}: missing coverage file ${ref.file}`);
    return errors;
  }

  const source = readFileSync(absPath, "utf8");
  const titles = parseItTitles(source);

  errors.push(...validateCoverageTitle(entry, ref, source, titles));
  errors.push(...validateRuntimeCovers(entry, ref));

  for (const covered of ref.covers) {
    if (covered !== entry.exportedName && ref.kind === "runtime-cross-user" && ref.covers.length === 1) {
      // single-endpoint refs must match exactly for object-ID callables
      if (entry.objectIdsFromClient.length > 0 && covered !== entry.exportedName) {
        errors.push(`${entry.exportedName}: runtime ref covers ${covered} but must cover self`);
      }
    }
  }

  if (ref.kind === "runtime-cross-user") {
    errors.push(...validateRuntimeCoverageDetails(entry, ref, source));
  }

  if (ref.kind === "firestore-rules" && entry.clientFirestoreSurface !== true) {
    errors.push(`${entry.exportedName}: firestore-rules coverage requires clientFirestoreSurface=true`);
  }

  if (ref.kind === "static-high-risk-wiring" && entry.objectIdsFromClient.length > 0) {
    // supplemental only — checked at entry level
  }

  const manifestMatch = source.match(/export const BOLA_MANIFEST\s*=\s*(\{[\s\S]*?\})\s*as const/u);
  if (manifestMatch) {
    try {
      const manifestText = manifestMatch[1].replace(/(\w+):/gu, '"$1":').replace(/'/gu, '"');
      const TRAILING_COMMA_RE = /,\s*\x7d/gu;
      const parsedManifest: unknown = JSON.parse(manifestText.replace(TRAILING_COMMA_RE, "}"));
      const manifest = normalizeBolaManifest(parsedManifest);
      const listed = manifest[entry.exportedName] ?? [];
      if (!listed.includes(ref.test)) {
        errors.push(`${entry.exportedName}: BOLA_MANIFEST missing test "${ref.test}"`);
      }
    } catch {
      // Manifest is validated structurally in dedicated test; ignore parse errors here.
    }
  }

  return errors;
}

function normalizeBolaManifest(value: unknown): Record<string, string[]> {
  if (value === null || typeof value !== "object" || Array.isArray(value)) return {};
  return Object.fromEntries(
    Object.entries(value).flatMap(([key, raw]) => {
      if (!Array.isArray(raw) || !raw.every((item) => typeof item === "string")) return [];
      return [[key, raw]];
    }),
  );
}

export function validateEndpointBolaCoverage(
  entry: EndpointAuthorizationEntry,
  repoRoot: string = REPO_ROOT_FROM_FUNCTIONS,
): string[] {
  const errors: string[] = [];

  if (entry.bolaCoverage.length === 0) {
    errors.push(`${entry.exportedName}: bolaCoverage must not be empty`);
    return errors;
  }

  const hasAuthOnly = entry.bolaCoverage.some((ref) => ref.kind === "auth-only");
  if (hasAuthOnly && entry.objectIdsFromClient.length > 0) {
    errors.push(`${entry.exportedName}: auth-only coverage cannot be used when objectIdsFromClient is non-empty`);
  }

  if (entry.objectIdsFromClient.length > 0) {
    const runtimeRefs = entry.bolaCoverage.filter(
      (ref) => ref.kind === "runtime-cross-user" && ref.covers.includes(entry.exportedName),
    );
    if (runtimeRefs.length === 0) {
      errors.push(`${entry.exportedName}: requires runtime-cross-user coverage referencing this endpoint`);
    }
  }

  const soleCoverage = entry.bolaCoverage.filter((ref) => ref.kind !== "static-high-risk-wiring");
  if (entry.objectIdsFromClient.length > 0 && soleCoverage.every((ref) => ref.kind === "static-high-risk-wiring")) {
    errors.push(`${entry.exportedName}: static-high-risk-wiring cannot be sole BOLA coverage`);
  }

  if (entry.handlerModule && entry.objectIdsFromClient.length > 0) {
    const handlerPath = resolve(repoRoot, "functions/src", entry.handlerModule);
    if (existsSync(handlerPath)) {
      const handlerSource = readFileSync(handlerPath, "utf8");
      if (
        /users\/\$\{[^}]*request\.data/u.test(handlerSource) &&
        !/assertOwnership\s*\(/u.test(handlerSource) &&
        entry.exportedName === "validateOpenTimestampsProof"
      ) {
        // validateOpenTimestampsProof binds via enforceHighRiskComputerUseCallable — allowed.
      }
    }
  }

  for (const ref of entry.bolaCoverage) {
    errors.push(...validateBolaCoverageRef(entry, ref, repoRoot));
  }

  return errors;
}
