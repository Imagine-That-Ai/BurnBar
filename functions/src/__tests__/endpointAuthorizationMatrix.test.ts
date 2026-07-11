import { readdirSync, readFileSync } from "node:fs";
import { resolve } from "node:path";

import ts from "typescript";
import { describe, expect, it } from "vitest";

import { endpointAuthorizationMatrix } from "../security/endpointAuthorizationMatrix.js";

const FUNCTIONS_SRC = resolve(__dirname, "..");

type ProductionSource = { path: string; source: string };

function productionTypeScriptSources(directory: string): ProductionSource[] {
  return readdirSync(directory, { withFileTypes: true }).flatMap((entry) => {
    const path = resolve(directory, entry.name);
    if (entry.isDirectory()) return entry.name === "__tests__" ? [] : productionTypeScriptSources(path);
    return entry.isFile() && entry.name.endsWith(".ts") ? [{ path, source: readFileSync(path, "utf8") }] : [];
  });
}

function stringArgument(call: ts.CallExpression, index: number): string | undefined {
  const argument = call.arguments[index];
  return argument && ts.isStringLiteralLike(argument) ? argument.text : undefined;
}

function isIdentifierCall(node: ts.Expression, name: string): boolean {
  return ts.isIdentifier(node) && node.text === name;
}

function initializerUsesTrustWrapper(initializer: ts.Expression, exportedName: string): boolean {
  if (!ts.isCallExpression(initializer)) return false;
  if (isIdentifierCall(initializer.expression, "onCallProduction")) {
    return stringArgument(initializer, 0) === exportedName;
  }
  if (!isIdentifierCall(initializer.expression, "onCall")) return false;
  const wrappedHandler = initializer.arguments[1];
  return (
    wrappedHandler !== undefined &&
    ts.isCallExpression(wrappedHandler) &&
    isIdentifierCall(wrappedHandler.expression, "wrapCallableHandler") &&
    stringArgument(wrappedHandler, 0) === exportedName
  );
}

function wrappedCallableExports(sources: ProductionSource[]): Set<string> {
  const wrapped = new Set<string>();
  for (const { path, source } of sources) {
    const file = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
    for (const statement of file.statements) {
      if (!ts.isVariableStatement(statement)) continue;
      if (!statement.modifiers?.some((modifier) => modifier.kind === ts.SyntaxKind.ExportKeyword)) continue;
      for (const declaration of statement.declarationList.declarations) {
        if (!ts.isIdentifier(declaration.name) || !declaration.initializer) continue;
        if (initializerUsesTrustWrapper(declaration.initializer, declaration.name.text)) {
          wrapped.add(declaration.name.text);
        }
      }
    }
  }
  return wrapped;
}

const productionSources = productionTypeScriptSources(FUNCTIONS_SRC);

describe("endpoint authorization matrix", () => {
  it("has actionable authorization fields for every endpoint", () => {
    for (const entry of endpointAuthorizationMatrix) {
      expect(entry.trigger, entry.exportedName).toMatch(
        /^(callable|http|scheduled|firestore-trigger|task-queue|provider-webhook)$/u,
      );
      expect(entry.authMethod.trim(), entry.exportedName).not.toEqual("");
      expect(entry.appCheck, entry.exportedName).toMatch(/^(required|not-applicable|not-required)$/u);
      expect(entry.lowerTrustDesktopPolicy, entry.exportedName).toMatch(
        /^(not-applicable|deny|linux-low-risk|desktop-attestation-binding|desktop-nonce-bootstrap|desktop-trusted-device-step-up)$/u,
      );
      expect(entry.tenantSource.trim(), entry.exportedName).not.toEqual("");
      expect(entry.ownershipCheck.trim(), entry.exportedName).not.toEqual("");
      expect(entry.bolaCoverage.length, entry.exportedName).toBeGreaterThan(0);
      if (entry.appCheck === "not-required" || entry.trigger === "provider-webhook") {
        expect(entry.publicJustification?.trim(), entry.exportedName).toBeTruthy();
      }
    }
  });

  it("keeps the lower-trust desktop allow surface explicit and fail-closed", () => {
    const byPolicy = new Map<string, string[]>();
    for (const entry of endpointAuthorizationMatrix) {
      const names = byPolicy.get(entry.lowerTrustDesktopPolicy) ?? [];
      names.push(entry.exportedName);
      byPolicy.set(entry.lowerTrustDesktopPolicy, names);
      if (entry.appCheck === "required") {
        expect(entry.lowerTrustDesktopPolicy, entry.exportedName).not.toBe("not-applicable");
      } else {
        expect(entry.lowerTrustDesktopPolicy, entry.exportedName).toBe("not-applicable");
      }
    }

    expect(byPolicy.get("linux-low-risk")).toHaveLength(29);
    expect(byPolicy.get("desktop-attestation-binding")).toEqual(["bindAppCheckAttestation"]);
    expect(byPolicy.get("desktop-nonce-bootstrap")).toEqual(["issueHighRiskActionNonce"]);
    expect(byPolicy.get("desktop-trusted-device-step-up")).toHaveLength(15);
    expect(byPolicy.get("deny")).toHaveLength(73);
  });

  it("has no duplicate exported names", () => {
    const names = endpointAuthorizationMatrix.map((entry) => entry.exportedName);
    const duplicates = names.filter((name, index) => names.indexOf(name) !== index);
    expect(duplicates).toEqual([]);
  });

  it("routes every callable through the shared trust-enforcing wrapper", () => {
    const wrapped = wrappedCallableExports(productionSources);
    const missing = endpointAuthorizationMatrix
      .filter((entry) => entry.trigger === "callable")
      .map((entry) => entry.exportedName)
      .filter((name) => !wrapped.has(name));
    expect(missing).toEqual([]);
  });

  it("catalogs every production callable that uses the shared trust wrapper", () => {
    const catalogCallables = new Set(
      endpointAuthorizationMatrix.filter((entry) => entry.trigger === "callable").map((entry) => entry.exportedName),
    );
    const uncataloged = [...wrappedCallableExports(productionSources)].filter((name) => !catalogCallables.has(name));
    expect(uncataloged).toEqual([]);
  });

  it("does not accept comments or sibling decoys as callable wrapper proof", () => {
    const source = `
      // wrapCallableHandler("unsafeEndpoint", async () => ({}))
      const decoy = wrapCallableHandler("unsafeEndpoint", async () => ({}));
      export const unsafeEndpoint = onCall({}, async () => ({}));
      export const safeEndpoint = onCall({}, wrapCallableHandler("safeEndpoint", async () => ({})));
    `;
    const wrapped = wrappedCallableExports([{ path: "fixture.ts", source }]);
    expect([...wrapped]).toEqual(["safeEndpoint"]);
  });
});
