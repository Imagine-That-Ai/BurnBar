import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import type { BolaCoverageRef, EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

const REPO_ROOT_FROM_FUNCTIONS = resolve(__dirname, "../../..");

const CALLABLE_RUNTIME_INVOCATION = /(?:\.run\s*\(|callableRunner\s*\()/u;
const HTTP_RUNTIME_INVOCATION =
  /(?:dispatchHermesGatewayRequest\s*\(|runHttpHandler\s*\(|Reflect\.get\s*\(\s*Object\s*\(\s*handler\s*\))/u;

const RUNTIME_BODY_MARKERS = [
  CALLABLE_RUNTIME_INVOCATION,
  /\b(?:alice|bob|other-user|ALICE_UID|BOB_UID|tier2CallableProof|seedBolaVictimTenant|snapshotTenantPaths|expectTenantPathsUnchanged)\b/u,
  /\b(?:rejects|permission-denied|not-found|assertFails|toMatchObject|toThrow|expectCallableDenial|tier2CallableProof)\b/u,
] as const;

const USER_TEMPLATE_NAMESPACE = /users\/\$\{([^}]+)\}/gu;
const USER_COLLECTION_DOC_NAMESPACE = /\.collection\(\s*["']users["']\s*\)\s*\.doc\(\s*([^)\n]+)\)/gu;
const EXPORT_SCOPE_BOUNDARY = /^\s*export\s+(?:async\s+)?(?:function|const|let|var)\b/gmu;
const OWNERSHIP_GUARD_CALL =
  /\b(?:assertOwnership|enforceAuthAndAppCheck|enforceHighRiskComputerUseCallable(?:WithNonce)?)\s*\(([^)]*)\)/gu;
const SIMPLE_IDENTIFIER = /^[A-Za-z_$][\w$]*$/u;

type HandlerScope = {
  source: string;
  start: number;
};

type NamespaceBindings = {
  payloadAliases: Map<string, string>;
  payloadObjectAliases: Set<string>;
  trustedAliases: Set<string>;
};

type UserNamespaceMatch = {
  name: string;
  expression: string;
  index: number;
  scopeSource: string;
  guardCandidates: Set<string>;
};

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

function normalizeNamespaceExpression(value: string): string {
  let normalized = value.trim().replace(/;$/u, "");
  while (normalized.startsWith("(") && normalized.endsWith(")")) {
    normalized = normalized.slice(1, -1).trim();
  }
  return normalized.replace(/\s+/gu, "");
}

function candidatePattern(candidate: string): RegExp {
  const normalized = normalizeNamespaceExpression(candidate);
  return SIMPLE_IDENTIFIER.test(normalized)
    ? new RegExp(`\\b${escapeRegExp(normalized)}\\b`, "u")
    : new RegExp(escapeRegExp(normalized), "u");
}

function expressionContainsCandidate(expression: string, candidate: string): boolean {
  return candidatePattern(candidate).test(normalizeNamespaceExpression(expression));
}

function parseDestructuredBindings(bindings: string): Array<{ property: string; alias: string }> {
  return bindings.split(",").flatMap((rawBinding) => {
    const binding = rawBinding.trim().replace(/\s*=.*$/u, "");
    if (binding.length === 0 || binding.startsWith("...")) return [];
    const [rawProperty, rawAlias = rawProperty] = binding.split(":").map((part) => part.trim());
    if (!SIMPLE_IDENTIFIER.test(rawProperty) || !SIMPLE_IDENTIFIER.test(rawAlias)) return [];
    return [{ property: rawProperty, alias: rawAlias }];
  });
}

function expressionUsesPayloadObjectAlias(expression: string, aliases: Set<string>): boolean {
  return [...aliases].some((alias) =>
    new RegExp(`\\b${escapeRegExp(alias)}\\.[A-Za-z_$][\\w$]*`, "u").test(expression),
  );
}

function expressionUsesAlias(expression: string, aliases: Iterable<string>): boolean {
  return [...aliases].some((alias) => candidatePattern(alias).test(normalizeNamespaceExpression(expression)));
}

function collectNamespaceBindings(source: string): NamespaceBindings {
  const payloadAliases = new Map<string, string>();
  const payloadObjectAliases = new Set<string>();
  const trustedAliases = new Set<string>();

  for (const match of source.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*request\.data\b/gu)) {
    payloadObjectAliases.add(match[1]);
  }

  for (const match of source.matchAll(/\b(?:const|let|var)\s*\{([^}]+)\}\s*=\s*([^;\n]*request\.data[^;\n]*)/gu)) {
    for (const { property, alias } of parseDestructuredBindings(match[1])) {
      payloadAliases.set(alias, `request.data.${property}`);
    }
  }

  for (const match of source.matchAll(/\b(?:const|let|var)\s+([A-Za-z_$][\w$]*)\s*=\s*([^;\n]+)/gu)) {
    const [, alias, rawExpression] = match;
    const expression = normalizeNamespaceExpression(rawExpression);
    if (expression === "request.data") {
      payloadObjectAliases.add(alias);
      continue;
    }
    if (expression.includes("request.auth.uid")) {
      trustedAliases.add(alias);
      continue;
    }
    if (
      expression.includes("request.data") ||
      expressionUsesPayloadObjectAlias(expression, payloadObjectAliases) ||
      expressionUsesAlias(expression, payloadAliases.keys())
    ) {
      payloadAliases.set(alias, expression);
    }
  }

  return { payloadAliases, payloadObjectAliases, trustedAliases };
}

function expressionIsTrustedNamespace(expression: string, bindings: NamespaceBindings): boolean {
  const normalized = normalizeNamespaceExpression(expression);
  return (
    normalized.includes("request.auth.uid") ||
    (SIMPLE_IDENTIFIER.test(normalized) && bindings.trustedAliases.has(normalized))
  );
}

function expressionIsPayloadControlled(expression: string, bindings: NamespaceBindings): boolean {
  const normalized = normalizeNamespaceExpression(expression);
  return (
    normalized.includes("request.data") ||
    expressionUsesPayloadObjectAlias(normalized, bindings.payloadObjectAliases) ||
    (SIMPLE_IDENTIFIER.test(normalized) && bindings.payloadAliases.has(normalized)) ||
    expressionUsesAlias(normalized, bindings.payloadAliases.keys())
  );
}

function addEquivalentPayloadAliases(
  candidates: Set<string>,
  bindings: NamespaceBindings,
  sourceExpression: string,
): void {
  const normalizedSource = normalizeNamespaceExpression(sourceExpression);
  for (const [alias, expression] of bindings.payloadAliases) {
    if (normalizeNamespaceExpression(expression) === normalizedSource) {
      candidates.add(alias);
    }
  }
}

function addPayloadPropertyCandidates(candidates: Set<string>, expression: string, bindings: NamespaceBindings): void {
  for (const match of expression.matchAll(/\brequest\.data\.[A-Za-z_$][\w$]*/gu)) {
    candidates.add(match[0]);
    addEquivalentPayloadAliases(candidates, bindings, match[0]);
  }
  for (const objectAlias of bindings.payloadObjectAliases) {
    const pattern = new RegExp(`\\b${escapeRegExp(objectAlias)}\\.[A-Za-z_$][\\w$]*`, "gu");
    for (const match of expression.matchAll(pattern)) {
      candidates.add(match[0]);
      addEquivalentPayloadAliases(candidates, bindings, match[0]);
    }
  }
}

function guardCandidatesForExpression(expression: string, bindings: NamespaceBindings): Set<string> {
  const candidates = new Set<string>();
  const normalized = normalizeNamespaceExpression(expression);
  candidates.add(normalized);
  addPayloadPropertyCandidates(candidates, normalized, bindings);

  for (const [alias, sourceExpression] of bindings.payloadAliases) {
    if (expressionContainsCandidate(normalized, alias)) {
      candidates.add(alias);
      candidates.add(sourceExpression);
      addPayloadPropertyCandidates(candidates, sourceExpression, bindings);
    }
  }

  addEquivalentPayloadAliases(candidates, bindings, normalized);
  return candidates;
}

function getHandlerScope(source: string, index: number): HandlerScope {
  const boundaries = [...source.matchAll(EXPORT_SCOPE_BOUNDARY)].map((match) => match.index ?? 0);
  const start = boundaries.filter((boundary) => boundary <= index).at(-1) ?? 0;
  const end = boundaries.find((boundary) => boundary > index) ?? source.length;
  return { source: source.slice(start, end), start };
}

function rawUserNamespaceMatches(source: string): UserNamespaceMatch[] {
  const matches: UserNamespaceMatch[] = [];
  for (const match of source.matchAll(USER_TEMPLATE_NAMESPACE)) {
    matches.push({
      name: "template users/${...}",
      expression: match[1],
      index: match.index ?? 0,
      scopeSource: source,
      guardCandidates: new Set(),
    });
  }
  for (const match of source.matchAll(USER_COLLECTION_DOC_NAMESPACE)) {
    matches.push({
      name: 'collection("users").doc(...)',
      expression: match[1],
      index: match.index ?? 0,
      scopeSource: source,
      guardCandidates: new Set(),
    });
  }
  return matches;
}

function clientControlledUserNamespaceMatches(handlerSource: string): UserNamespaceMatch[] {
  return rawUserNamespaceMatches(handlerSource).flatMap((rawMatch) => {
    const scope = getHandlerScope(handlerSource, rawMatch.index);
    const localExpressionIndex = rawMatch.index - scope.start;
    const bindings = collectNamespaceBindings(scope.source);
    if (expressionIsTrustedNamespace(rawMatch.expression, bindings)) return [];
    if (!expressionIsPayloadControlled(rawMatch.expression, bindings)) return [];
    return [
      {
        ...rawMatch,
        index: localExpressionIndex,
        scopeSource: scope.source,
        guardCandidates: guardCandidatesForExpression(rawMatch.expression, bindings),
      },
    ];
  });
}

function hasPriorOwnershipGuard(source: string, match: UserNamespaceMatch): boolean {
  const prefix = source.slice(0, match.index);
  for (const guard of prefix.matchAll(OWNERSHIP_GUARD_CALL)) {
    const args = normalizeNamespaceExpression(guard[1]);
    if ([...match.guardCandidates].some((candidate) => expressionContainsCandidate(args, candidate))) {
      return true;
    }
  }
  return false;
}

function validateHandlerUserNamespaceBinding(entry: EndpointAuthorizationEntry, handlerSource: string): string[] {
  const errors: string[] = [];
  if (entry.objectIdsFromClient.length === 0) return errors;

  const unsafeMatches = clientControlledUserNamespaceMatches(handlerSource).filter((match) => {
    return !hasPriorOwnershipGuard(match.scopeSource, match);
  });
  if (unsafeMatches.length > 0) {
    errors.push(
      `${entry.exportedName}: handler constructs a user namespace from callable payload data (${unsafeMatches
        .map(({ name }) => name)
        .join(
          ", ",
        )}); derive users/{uid} from request.auth.uid or add an explicit ownership guard before Admin SDK access`,
    );
  }
  return errors;
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
      errors.push(...validateHandlerUserNamespaceBinding(entry, handlerSource));
    }
  }

  for (const ref of entry.bolaCoverage) {
    errors.push(...validateBolaCoverageRef(entry, ref, repoRoot));
  }

  return errors;
}
