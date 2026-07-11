import { readFileSync } from "node:fs";
import { resolve } from "node:path";

import ts from "typescript";
import { describe, expect, it } from "vitest";

const REPO_ROOT = resolve(__dirname, "../../..");
const FIREBASE_WEB_APP_ID = /^1:\d+:web:[A-Za-z0-9]+$/u;

type RegistrySources = {
  productionEnv: string;
  websiteClient: string;
  consoleClient: string;
};

function firebaseConfigAppId(source: string, path: string): string | undefined {
  const file = ts.createSourceFile(path, source, ts.ScriptTarget.Latest, true, ts.ScriptKind.TS);
  let result: string | undefined;
  const visit = (node: ts.Node): void => {
    if (result) return;
    if (ts.isPropertyAssignment(node)) {
      const name = ts.isIdentifier(node.name) || ts.isStringLiteralLike(node.name) ? node.name.text : undefined;
      if (name === "appId") {
        const findLiteral = (candidate: ts.Node): void => {
          if (result) return;
          if (ts.isStringLiteralLike(candidate) && FIREBASE_WEB_APP_ID.test(candidate.text)) {
            result = candidate.text;
            return;
          }
          ts.forEachChild(candidate, findLiteral);
        };
        findLiteral(node.initializer);
      }
    }
    ts.forEachChild(node, visit);
  };
  visit(file);
  return result;
}

function parseEnv(source: string): Map<string, string> {
  const values = new Map<string, string>();
  for (const rawLine of source.split(/\r?\n/u)) {
    const line = rawLine.trim();
    if (!line || line.startsWith("#")) continue;
    const separator = line.indexOf("=");
    if (separator <= 0) continue;
    const key = line.slice(0, separator).trim();
    if (values.has(key)) throw new Error(`Duplicate production environment key: ${key}`);
    values.set(key, line.slice(separator + 1).trim());
  }
  return values;
}

function stringList(value: string | undefined): string[] {
  return (value ?? "")
    .split(/[\s,]+/u)
    .map((item) => item.trim())
    .filter(Boolean);
}

function validateRegistrySources(sources: RegistrySources): string[] {
  const errors: string[] = [];
  const websiteAppId = firebaseConfigAppId(sources.websiteClient, "website/firebaseClient.ts");
  const consoleAppId = firebaseConfigAppId(sources.consoleClient, "console/firebaseClient.ts");
  const env = parseEnv(sources.productionEnv);
  const registered = new Set(stringList(env.get("APP_CHECK_STANDARD_WEB_APP_IDS")));

  if (!websiteAppId || !consoleAppId) errors.push("both browser clients must commit a Firebase Web app ID fallback");
  if (websiteAppId && consoleAppId && websiteAppId !== consoleAppId) {
    errors.push("website and console Firebase Web app IDs must match");
  }
  const expected = new Set([websiteAppId, consoleAppId].filter((value): value is string => Boolean(value)));
  if (registered.size !== expected.size || [...expected].some((value) => !registered.has(value))) {
    errors.push("production standard Web App Check registry must exactly match committed browser app IDs");
  }
  if ([...registered].some((value) => !FIREBASE_WEB_APP_ID.test(value))) {
    errors.push("standard Web App Check registry contains a malformed Firebase Web app ID");
  }

  const desktop = new Set([
    ...stringList(env.get("APP_CHECK_ALLOWED_APP_IDS")),
    ...stringList(env.get("LINUX_APP_CHECK_APP_ID")),
    ...stringList(env.get("WINDOWS_APP_CHECK_APP_ID")),
  ]);
  if ([...registered].some((value) => desktop.has(value))) {
    errors.push("standard Web and lower-trust desktop App Check registries must be disjoint");
  }
  return errors;
}

const actualSources: RegistrySources = {
  productionEnv: readFileSync(resolve(REPO_ROOT, "functions/.env.burnbar.production"), "utf8"),
  websiteClient: readFileSync(resolve(REPO_ROOT, "website/src/lib/firebaseClient.ts"), "utf8"),
  consoleClient: readFileSync(resolve(REPO_ROOT, "apps/console/lib/firebaseClient.ts"), "utf8"),
};

const websiteFixture = `const firebaseConfig = { appId: env.APP_ID || "1:123:web:browser" };`;
const consoleFixture = `const firebaseConfig = { appId: env.APP_ID || "1:123:web:browser" };`;

describe("production App Check browser registry", () => {
  it("matches the exact Firebase app ID shipped by the website and console", () => {
    expect(validateRegistrySources(actualSources)).toEqual([]);
  });

  it("rejects a missing production registry", () => {
    expect(
      validateRegistrySources({
        productionEnv: "ENFORCE_APP_CHECK=true",
        websiteClient: websiteFixture,
        consoleClient: consoleFixture,
      }),
    ).toContain("production standard Web App Check registry must exactly match committed browser app IDs");
  });

  it("rejects browser-client drift", () => {
    expect(
      validateRegistrySources({
        productionEnv: "APP_CHECK_STANDARD_WEB_APP_IDS=1:123:web:browser",
        websiteClient: websiteFixture,
        consoleClient: `const firebaseConfig = { appId: env.APP_ID || "1:123:web:other" };`,
      }),
    ).toContain("website and console Firebase Web app IDs must match");
  });

  it("rejects a browser app ID reused as a lower-trust desktop ID", () => {
    expect(
      validateRegistrySources({
        productionEnv: "APP_CHECK_STANDARD_WEB_APP_IDS=1:123:web:browser\nLINUX_APP_CHECK_APP_ID=1:123:web:browser",
        websiteClient: websiteFixture,
        consoleClient: consoleFixture,
      }),
    ).toContain("standard Web and lower-trust desktop App Check registries must be disjoint");
  });
});
