#!/usr/bin/env node
/**
 * sync-domains.mjs — keep apps/console bound to the canonical data-domain registry.
 *
 * The registry at packages/data-domains/registry.json is the SOURCE OF TRUTH.
 * codegen.mjs emits packages/data-domains/gen/domains.ts. Because apps/console is
 * a standalone Next app (not a workspace member), we copy that generated file into
 * lib/domains.generated.ts on every dev/build/test so the domain list + encryption
 * tiers can never drift from the registry. We DO NOT hand-author the domain list.
 *
 * Fail behaviour: if the registry package is unavailable (e.g. a thin checkout),
 * we keep any previously synced copy rather than failing the build, but we warn.
 */
import { copyFileSync, mkdirSync, readFileSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const consoleRoot = resolve(here, "..");
const repoRoot = resolve(consoleRoot, "..", "..");

/**
 * Copy a source-of-truth artifact into the app, keeping a prior copy if the
 * source is unavailable (thin checkout) but the destination already exists.
 */
function syncArtifact(source, dest, label) {
  mkdirSync(dirname(dest), { recursive: true });
  try {
    copyFileSync(source, dest);
    console.log(`[sync-domains] synced ${source} -> ${dest}`);
  } catch (error) {
    if (error?.code === "ENOENT") {
      try {
        readFileSync(dest);
        console.warn(`[sync-domains] ${label} not found at ${source}; keeping existing ${dest}`);
        return;
      } catch {
        console.error(
          `[sync-domains] ${label} not found at ${source} and no prior copy at ${dest}.`,
        );
        process.exit(1);
      }
    }
    if (error?.code === "ENOTDIR") {
      console.error(`[sync-domains] cannot sync ${label}; path is not a directory.`);
      process.exit(1);
    }
    throw error;
  }
}

function readOptionalText(path) {
  try {
    return readFileSync(path, "utf8");
  } catch (error) {
    if (error?.code === "ENOENT") {
      return;
    }
    throw error;
  }
}

const domainsDest = resolve(consoleRoot, "lib", "domains.generated.ts");
syncArtifact(
  resolve(repoRoot, "packages/data-domains/gen/domains.ts"),
  domainsDest,
  "registry gen (domains.ts)",
);

/**
 * Compatibility shim: the upstream codegen passes through the registry's
 * `tieredLimits` value for the Pensieve domain but omits the matching optional
 * field on the `DataDomain` interface, so the generated literal does not
 * typecheck under strict TS. We add the optional field to OUR copy (data stays
 * verbatim) so the console typechecks. Upstream codegen.mjs should add this field
 * to the interface; see integrationNeeded.
 */
{
  const src = readOptionalText(domainsDest);
  if (src && src.includes('"tieredLimits"') && !/tieredLimits\?: string;/.test(src)) {
    const patched = src.replace(
      "  entitlementGate: string | null;",
      "  /** Added by sync-domains shim; upstream codegen should emit this. */\n  tieredLimits?: string;\n  entitlementGate: string | null;",
    );
    if (patched !== src) {
      writeFileSync(domainsDest, patched);
      console.log("[sync-domains] applied tieredLimits interface shim to domains.generated.ts");
    }
  }
}

syncArtifact(
  resolve(repoRoot, "packages/design-tokens/dist/css/pensieve.css"),
  resolve(consoleRoot, "styles", "pensieve.tokens.css"),
  "design tokens (pensieve.css)",
);
