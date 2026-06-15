#!/usr/bin/env node
/**
 * Migrate BOLA scaffold tests to tier2CallableProof (seeded victim-tenant isolation).
 */
import { readFileSync, readdirSync, writeFileSync } from "node:fs";
import { resolve } from "node:path";

const repoRoot = resolve(import.meta.dirname, "../..");
const bolaDir = resolve(repoRoot, "functions/src/__tests__/bola");
const catalogPath = resolve(repoRoot, "functions/src/security/endpointAuthorizationCatalog.generated.ts");

const catalogSource = readFileSync(catalogPath, "utf8");
const catalogMatch = catalogSource.match(
  /export const endpointAuthorizationCatalog:\s*EndpointAuthorizationEntry\[\]\s*=\s*(\[[\s\S]*\])\s*as\s*EndpointAuthorizationEntry\[\];/u,
);
const catalog = JSON.parse(catalogMatch[1]);
const coverageByName = Object.fromEntries(
  catalog.map((entry) => {
    const ref = entry.bolaCoverage?.find(
      (row) => row.kind === "runtime-cross-user" && row.covers?.includes(entry.exportedName),
    );
    return [entry.exportedName, ref];
  }),
);

const skipFiles = new Set([
  "authOnly.bola.test.ts",
  "callableHarness.bola.test.ts",
  "credentialTransfer.bola.test.ts",
  "hermesGateway.bola.test.ts",
  "openTimestamps.bola.test.ts",
  "voipPush.bola.test.ts",
]);

/** Tests with hand-written HTTP/custom proofs — do not rewrite these it() blocks. */
const skipTests = new Set([
  "pollCliLink rejects cross-user object access",
  "burnBarHermesGateway rejects cross-user object access",
  "revokeProviderAccountDeviceLink rejects cross-user object access",
  "deleteProviderCredential rejects cross-user object access",
  "revokeRemoteMcpClient rejects cross-user object access",
  "triggerVoIPCall rejects cross-user object access",
]);

const denyCall =
  /await expectCallableDenial\(\s*run,\s*callableRequest\(ALICE_UID,\s*bolaCrossUserData\(\)\),\s*"([^"]+)"\s*\);/gu;

for (const file of readdirSync(bolaDir).filter((name) => name.endsWith(".bola.test.ts"))) {
  if (skipFiles.has(file)) continue;
  const path = resolve(bolaDir, file);
  let source = readFileSync(path, "utf8");
  if (!source.includes("expectCallableDenial")) continue;

  if (!source.includes("tier2CallableProof")) {
    source = source.replace(
      /import \{([^}]+)\} from "\.\/callableBolaHarness\.js";/u,
      (match, imports) => {
        const names = imports.split(",").map((part) => part.trim()).filter(Boolean);
        if (!names.includes("tier2CallableProof")) names.push("tier2CallableProof");
        return `import { ${names.join(", ")} } from "./callableBolaHarness.js";`;
      },
    );
  }

  source = source.replace(
    /it\("([^"]+)", async \(\) => \{([\s\S]*?)\n  \}\);/gu,
    (block, title, body) => {
      if (skipTests.has(title)) return block;
      if (!body.includes("expectCallableDenial")) return block;
      const exportedMatch = title.match(/^(\w+) rejects cross-user object access$/u);
      if (!exportedMatch) return block;

      const exportedName = exportedMatch[1];
      if (new RegExp(`exportedName:\\s*"${exportedName}"`, "u").test(body) && body.includes("tier2CallableProof")) {
        return block;
      }
      const coverage = coverageByName[exportedName];
      const expectedCode = coverage?.expectedCode ?? "not-found";
      const expectedOutcome = coverage?.expectedOutcome ?? "throws";

      let updatedBody = body.replace(denyCall, "");
      updatedBody = updatedBody.replace(
        /const run = callableRunner\([^)]+\);\s*/u,
        (runLine) => `${runLine}\n    await tier2CallableProof(bolaStore, {\n      exportedName: "${exportedName}",\n      run,\n      expectedCode: "${expectedCode}",\n      expectedOutcome: "${expectedOutcome}",\n    });`,
      );

      if (updatedBody === body) return block;
      return `it("${title}", async () => {${updatedBody}\n  });`;
    },
  );

  writeFileSync(path, source);
  console.log(`tier2 migrated ${file}`);
}