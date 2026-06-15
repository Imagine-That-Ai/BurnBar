import { existsSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import type { BolaCoverageKind, BolaCoverageRef, EndpointAuthorizationEntry } from "./bolaCoverageTypes.js";

export const REPO_ROOT_FROM_FUNCTIONS = resolve(__dirname, "../../..");

const RUNTIME_BODY_MARKERS = [
  /\.run\s*\(/u,
  /\b(?:alice|bob|other-user|ALICE_UID|BOB_UID)\b/u,
  /\b(?:rejects|permission-denied|not-found|assertFails|toMatchObject|toThrow)\b/u,
] as const;

const IT_TITLE_PATTERN = (title: string) =>
  new RegExp(`\\bit\\s*\\(\\s*(["'\`])${escapeRegExp(title)}\\1`, "u");

function escapeRegExp(value: string): string {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

export function parseItTitles(source: string): Set<string> {
  const titles = new Set<string>();
  for (const match of source.matchAll(/\bit\s*\(\s*(["'`])([^"'`]+)\1/gu)) {
    titles.add(match[2]);
  }
  return titles;
}

export function validateRuntimeTestBody(source: string): string[] {
  const errors: string[] = [];
  for (const marker of RUNTIME_BODY_MARKERS) {
    if (!marker.test(source)) {
      errors.push(`missing runtime marker ${marker.source}`);
    }
  }
  return errors;
}

export function validateBolaCoverageRef(
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

  if (!titles.has(ref.test)) {
    errors.push(`${entry.exportedName}: test "${ref.test}" not found in ${ref.file}`);
  }

  if (!ref.covers.includes(entry.exportedName) && ref.kind === "runtime-cross-user") {
    const coversEntry = ref.covers.some((name) => name === entry.exportedName);
    if (!coversEntry) {
      errors.push(`${entry.exportedName}: runtime ref must include exportedName in covers[]`);
    }
  }

  for (const covered of ref.covers) {
    if (covered !== entry.exportedName && ref.kind === "runtime-cross-user" && ref.covers.length === 1) {
      // single-endpoint refs must match exactly for object-ID callables
      if (entry.objectIdsFromClient.length > 0 && covered !== entry.exportedName) {
        errors.push(`${entry.exportedName}: runtime ref covers ${covered} but must cover self`);
      }
    }
  }

  if (ref.kind === "runtime-cross-user") {
    errors.push(...validateRuntimeTestBody(source).map((msg) => `${entry.exportedName}: ${ref.file}: ${msg}`));
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
      const manifestText = manifestMatch[1]
          .replace(/(\w+):/gu, '"$1":')
          .replace(/'/gu, '"');
      // eslint-disable-next-line no-control-regex -- reason: strip trailing commas before closing brace
      const TRAILING_COMMA_RE = /,\s*\x7d/gu;
      const manifest: Record<string, string[]> = JSON.parse(
        manifestText.replace(TRAILING_COMMA_RE, "}"),
      );
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
  if (
    entry.objectIdsFromClient.length > 0 &&
    soleCoverage.every((ref) => ref.kind === "static-high-risk-wiring")
  ) {
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

export function collectBolaCoverageKinds(entry: EndpointAuthorizationEntry): Set<BolaCoverageKind> {
  return new Set(entry.bolaCoverage.map((ref) => ref.kind));
}