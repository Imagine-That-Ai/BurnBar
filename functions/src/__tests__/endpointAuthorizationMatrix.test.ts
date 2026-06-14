import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix, endpointAuthorizationByName } from "../security/endpointAuthorizationMatrix.js";

function exportedFunctionNames(): string[] {
  const indexSource = readFileSync(resolve(__dirname, "../index.ts"), "utf8");
  const names: string[] = [];
  for (const match of indexSource.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"[^"]+";/g)) {
    for (const part of match[1].split(",")) {
      const raw = part.trim();
      if (!raw) continue;
      names.push(raw.split(/\s+as\s+/u).pop()?.trim() ?? raw);
    }
  }
  return names.sort((left, right) => left.localeCompare(right));
}

/**
 * Resolve the on-disk source file that actually DECLARES `exportName`, following
 * `export { x } from "./y.js"` re-export chains (e.g. appstore/index.ts →
 * appstore/callable.ts). Returns undefined if the chain dead-ends.
 */
function resolveDeclaringFile(startFile: string, exportName: string): string | undefined {
  const seen = new Set<string>();
  let file = startFile;
  let name = exportName;
  for (let hops = 0; hops < 6; hops += 1) {
    if (seen.has(`${file}::${name}`)) return undefined;
    seen.add(`${file}::${name}`);
    let source: string;
    try {
      source = readFileSync(file, "utf8");
    } catch {
      return undefined;
    }
    // A direct declaration in this file wins.
    const declRegex = new RegExp(
      String.raw`export\s+(?:const|async\s+function|function)\s+${name}\b`,
      "u",
    );
    if (declRegex.test(source)) return file;
    // Otherwise follow a matching re-export to the next file.
    let nextFile: string | undefined;
    let nextName = name;
    for (const match of source.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"([^"]+)";/g)) {
      for (const part of match[1].split(",")) {
        const raw = part.trim();
        if (!raw) continue;
        const [original, aliased] = raw.split(/\s+as\s+/u).map((piece) => piece.trim());
        const exposed = aliased ?? original;
        if (exposed === name) {
          nextFile = resolve(file, "..", match[2].replace(/\.js$/u, ".ts"));
          nextName = original;
        }
      }
    }
    if (!nextFile) return undefined;
    file = nextFile;
    name = nextName;
  }
  return undefined;
}

/**
 * Map every export name re-exported from index.ts to the on-disk source file
 * that DECLARES it (following re-export chains; resolving `.js` back to `.ts`).
 */
function exportNameToSourceFile(): Map<string, string> {
  const indexFile = resolve(__dirname, "../index.ts");
  const indexSource = readFileSync(indexFile, "utf8");
  const map = new Map<string, string>();
  for (const match of indexSource.matchAll(/export\s+\{([\s\S]*?)\}\s+from\s+"([^"]+)";/g)) {
    const specifier = match[2].replace(/\.js$/u, ".ts");
    const filePath = resolve(__dirname, "..", specifier);
    for (const part of match[1].split(",")) {
      const raw = part.trim();
      if (!raw) continue;
      const exportName = raw.split(/\s+as\s+/u).pop()?.trim() ?? raw;
      const declaringFile = resolveDeclaringFile(filePath, exportName) ?? filePath;
      map.set(exportName, declaringFile);
    }
  }
  return map;
}

// Recognized authorization / tenant-derivation primitives. A handler that
// invokes at least one of these has, by construction, performed an authorization
// or tenant-binding step before reaching tenant data. The list is intentionally
// broad — it spans the uid-scoped callables (`requireUid` / `enforceAuthAndAppCheck`
// / `request.auth.uid`), the gateway HTTP surface (`resolveGatewayGrant`), the
// public one-time-code pairing routes (`checkPublicHttpRateLimit` + code
// consumption), and the Firestore-trigger-shaped entries that derive their tenant
// from the triggering document path (`event.params` / `event.data`). Each member
// is a real authorization/tenant read, never a bare data access.
const AUTH_PRIMITIVES = [
  "enforceAuthAndAppCheck",
  "assertOwnership",
  "assertAuthAndAppCheck",
  "assertAuth",
  "assertAppCheck",
  "resolveGatewayGrant",
  "assertActiveHermesGatewayClient",
  "requireUid",
  "requireAuth",
  "requireAuthedUid",
  "requireUserId",
  "checkPublicHttpRateLimit",
  // High-risk Computer-Use callables bind every action to a verified uid + nonce.
  "enforceHighRiskComputerUse",
  // One-time-code pairing routes prove ownership via a device-secret hash match.
  "deviceSecretHash",
  "request.auth?.uid",
  "request.auth.uid",
  "event.params",
  "event.data",
];

/**
 * Extract the source region that backs a callable export, following the common
 * `onCall(opts, wrapCallableHandler("name", handlerFn))` delegation to the named
 * `handlerFn` defined in the same file. Returns the export's own declaration body
 * concatenated with any same-file handler function it references, so the auth
 * scan sees the code that actually runs.
 */
function callableHandlerSource(fileSource: string, exportName: string): string {
  const declRegex = new RegExp(
    String.raw`export\s+(?:const|async\s+function|function)\s+${exportName}\b[\s\S]*?(?=\nexport\s|$)`,
    "u",
  );
  const declMatch = declRegex.exec(fileSource);
  if (!declMatch) return "";
  let region = declMatch[0];
  // Follow `wrapCallableHandler("name", someHandler)` / `, someHandler)` style
  // delegation to a handler function defined in the same file.
  for (const ref of region.matchAll(/wrapCallableHandler\(\s*"[^"]+"\s*,\s*([A-Za-z0-9_]+)\s*\)/gu)) {
    const handlerName = ref[1];
    const handlerRegex = new RegExp(
      String.raw`(?:export\s+)?(?:async\s+function|function|const)\s+${handlerName}\b[\s\S]*?(?=\n(?:export\s+)?(?:async\s+function|function|const)\s|\nexport\s|$)`,
      "u",
    );
    const handlerMatch = handlerRegex.exec(fileSource);
    if (handlerMatch) region += "\n" + handlerMatch[0];
  }
  return region;
}

describe("endpoint authorization matrix", () => {
  it("covers every exported Cloud Function from index.ts", () => {
    const exported = exportedFunctionNames();
    const matrixNames = endpointAuthorizationMatrix
      .map((entry) => entry.exportedName)
      .sort((left, right) => left.localeCompare(right));

    expect(matrixNames).toEqual(exported);
  });

  it("has actionable BOLA fields for every endpoint", () => {
    const byName = endpointAuthorizationByName();
    const duplicateNames = endpointAuthorizationMatrix
      .map((entry) => entry.exportedName)
      .filter((name, index, all) => all.indexOf(name) !== index);

    expect(duplicateNames).toEqual([]);
    for (const entry of byName.values()) {
      expect(entry.trigger, entry.exportedName).toMatch(/^(callable|http|scheduled|firestore-trigger|provider-webhook)$/u);
      expect(entry.authMethod.trim(), entry.exportedName).not.toEqual("");
      expect(entry.appCheck, entry.exportedName).toMatch(/^(required|not-applicable|not-required)$/u);
      expect(entry.tenantSource.trim(), entry.exportedName).not.toEqual("");
      expect(entry.ownershipCheck.trim(), entry.exportedName).not.toEqual("");
      expect(entry.negativeBolaTest.trim(), entry.exportedName).not.toEqual("");
      if (entry.appCheck === "not-required" || entry.trigger === "provider-webhook") {
        expect(entry.publicJustification?.trim(), entry.exportedName).toBeTruthy();
      }
    }
  });

  // T-AZ-05: the inventory/drift gate above proves the matrix DESCRIBES an
  // ownership check for every endpoint. This adds the STRUCTURAL assertion that
  // each callable handler actually INVOKES one — a handler that silently omits
  // enforceAuthAndAppCheck/assertOwnership/etc. fails CI rather than passing on a
  // matrix row that merely claims an ownership check exists.
  it("every callable handler invokes an ownership/authz primitive", () => {
    const fileMap = exportNameToSourceFile();
    const sourceCache = new Map<string, string>();
    const readSource = (filePath: string): string => {
      let cached = sourceCache.get(filePath);
      if (cached === undefined) {
        cached = readFileSync(filePath, "utf8");
        sourceCache.set(filePath, cached);
      }
      return cached;
    };

    const offenders: string[] = [];
    for (const entry of endpointAuthorizationMatrix) {
      if (entry.trigger !== "callable") continue;
      const filePath = fileMap.get(entry.exportedName);
      if (!filePath) {
        offenders.push(`${entry.exportedName} (no source file resolved from index.ts)`);
        continue;
      }
      const region = callableHandlerSource(readSource(filePath), entry.exportedName);
      if (!region) {
        offenders.push(`${entry.exportedName} (handler declaration not found)`);
        continue;
      }
      const hasAuthPrimitive = AUTH_PRIMITIVES.some((primitive) => region.includes(primitive));
      if (!hasAuthPrimitive) {
        offenders.push(`${entry.exportedName} (no auth/ownership primitive in handler)`);
      }
    }

    expect(offenders, `callable handlers missing an authorization check:\n${offenders.join("\n")}`).toEqual([]);
  });
});
