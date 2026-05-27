#!/usr/bin/env node
/**
 * Batch-fix common unsafe-cast patterns introduced before the zero-lock burn-down.
 * Idempotent: safe to re-run; skips files that already import errorMessage.
 */
import fs from 'node:fs';
import path from 'node:path';

const ROOT = path.resolve(process.cwd());
const TARGET_DIRS = [
  'functions/src',
  'extensions',
  'services',
  'website/src',
];

function walk(dir, out = []) {
  if (!fs.existsSync(dir)) return out;
  for (const entry of fs.readdirSync(dir, { withFileTypes: true })) {
    const full = path.join(dir, entry.name);
    if (entry.isDirectory()) {
      if (['node_modules', 'dist', 'build', 'Generated', 'uniffi'].includes(entry.name)) continue;
      walk(full, out);
    } else if (/\.(ts|tsx|js|jsx|mjs)$/.test(entry.name)) {
      out.push(full);
    }
  }
  return out;
}

const replacements = [
  [/\(\s*err\s+as\s+Error\s*\)\.message/g, 'errorMessage(err)'],
  [/\(\s*error\s+as\s+Error\s*\)\.message/g, 'errorMessage(error)'],
  [/\(\s*err\s+as\s+Error\s*\)\?\.message/g, 'errorMessage(err)'],
  [/\(\s*error\s+as\s+Error\s*\)\?\.message/g, 'errorMessage(error)'],
];

let changed = 0;
for (const rel of TARGET_DIRS) {
  for (const file of walk(path.join(ROOT, rel))) {
    let src = fs.readFileSync(file, 'utf8');
    let next = src;
    for (const [pattern, replacement] of replacements) {
      next = next.replace(pattern, replacement);
    }
    if (next === src) continue;

    if (next.includes('errorMessage(') && !/import[\s\S]*errorMessage/.test(next)) {
      if (next.includes('from "./guards.js"') || next.includes("from './guards.js'")) {
        next = next.replace(
          /from ['"]\.\/guards\.js['"];?/,
          (match) => match.includes('errorMessage')
            ? match
            : match.replace('}', '').replace('from "./guards.js"', 'errorMessage, isRecord } from "./guards.js"')
                .replace("from './guards.js'", "errorMessage, isRecord } from './guards.js'")
        );
        if (!next.includes('errorMessage')) {
          next = next.replace(
            /import\s+\{([^}]+)\}\s+from\s+['"]\.\/guards\.js['"];/,
            'import {$1, errorMessage } from "./guards.js";'
          );
        }
      } else if (file.includes(`${path.sep}functions${path.sep}src${path.sep}`)) {
        next = next.replace(
          /^(import .*\n)/,
          '$1import { errorMessage } from "./guards.js";\n'
        );
        // avoid duplicate if already added
        next = next.replace(/import \{ errorMessage \} from "\.\/guards\.js";\nimport \{ errorMessage \}/, 'import { errorMessage');
      } else if (file.includes(`${path.sep}services${path.sep}`)) {
        const guardsImport = next.match(/^import .+\n/m);
        if (guardsImport && !next.includes('errorMessage')) {
          // services may not have guards - use inline helper at top
          next = `function errorMessage(error: unknown): string {\n  return error instanceof Error ? error.message : String(error);\n}\n\n${next}`;
        }
      }
    }

    fs.writeFileSync(file, next);
    changed += 1;
    console.log('updated', path.relative(ROOT, file));
  }
}
console.log('files changed:', changed);
