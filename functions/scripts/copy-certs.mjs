#!/usr/bin/env node
/**
 * Copy Apple root certificate `.cer` files from src/appstore/certs into the
 * compiled lib/appstore/certs output. tsc only emits .ts → .js, so the
 * vendored DER blobs need a deterministic copy step.
 *
 * Run automatically by `npm run build`.
 */

import { readdirSync, mkdirSync, copyFileSync, statSync } from "node:fs";
import { join, dirname } from "node:path";
import { fileURLToPath } from "node:url";

const here = dirname(fileURLToPath(import.meta.url));
const root = join(here, "..");
const srcDir = join(root, "src", "appstore", "certs");
const dstDir = join(root, "lib", "appstore", "certs");

mkdirSync(dstDir, { recursive: true });

let copied = 0;
for (const entry of readdirSync(srcDir)) {
  const srcPath = join(srcDir, entry);
  const dstPath = join(dstDir, entry);
  const st = statSync(srcPath);
  if (!st.isFile()) continue;
  if (!/\.(cer|md)$/i.test(entry)) continue;
  copyFileSync(srcPath, dstPath);
  copied += 1;
}

console.log(`copy-certs: copied ${copied} file(s) from src/appstore/certs → lib/appstore/certs`);
