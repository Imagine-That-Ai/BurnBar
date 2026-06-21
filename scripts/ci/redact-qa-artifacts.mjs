#!/usr/bin/env node
/**
 * Redact secret-bearing QA output before it can be uploaded as an artifact or
 * copied into a PR comment. The workflow also uses stream mode to scrub tee
 * output while the QA secret environment is still in scope.
 */

import { createInterface } from "node:readline";
import { fileURLToPath } from "node:url";
import {
  existsSync,
  readdirSync,
  readFileSync,
  statSync,
  writeFileSync,
} from "node:fs";
import { join } from "node:path";

const SENSITIVE_ENV_NAMES = [
  "FACTORY_API_KEY",
  "FIREBASE_PLIST_BASE64",
  "FIREBASE_APP_CHECK_DEBUG_TOKEN",
  "FIRAAppCheckDebugToken",
  "QA_FIREBASE_EMAIL",
  "QA_FIREBASE_PASSWORD",
  "ANTHROPIC_API_KEY",
  "OPENAI_API_KEY",
  "OPENROUTER_API_KEY",
  "ZAI_API_KEY",
  "Z_AI_API_KEY",
  "MINIMAX_API_KEY",
  "CURSOR_API_KEY",
  "GH_TOKEN",
  "GITHUB_TOKEN",
  "SLACK_SECURITY_WEBHOOK",
  "SENTRY_AUTH_TOKEN",
];

const ASSIGNMENT_KEYS = [
  ...SENSITIVE_ENV_NAMES,
  "api_key",
  "apikey",
  "authorization",
  "bearer",
  "cookie",
  "password",
  "secret",
  "token",
];

const TEXT_EXTENSIONS = new Set([
  "",
  ".env",
  ".json",
  ".log",
  ".md",
  ".plist",
  ".txt",
  ".xml",
  ".yaml",
  ".yml",
]);

function escapeRegExp(value) {
  return value.replace(/[.*+?^${}()|[\]\\]/g, "\\$&");
}

function exactSecretValues() {
  const values = [];
  for (const name of SENSITIVE_ENV_NAMES) {
    const value = process.env[name];
    if (typeof value === "string" && value.length >= 3) {
      values.push(value);
    }
  }
  return [...new Set(values)].sort((a, b) => b.length - a.length);
}

function redactKnownAssignments(text) {
  const keyPattern = ASSIGNMENT_KEYS.map(escapeRegExp).join("|");
  return text.replace(
    new RegExp(
      `(["']?)\\b(${keyPattern})\\b\\1\\s*[:=]\\s*(['"]?)[^\\s'"<>|&{},\\[\\]]{3,}\\3`,
      "giu",
    ),
    (_match, keyQuote, key, valueQuote) =>
      `${keyQuote}${key}${keyQuote}=${valueQuote}[REDACTED]${valueQuote}`,
  );
}

function redactTokenShapes(text) {
  return text
    .replace(/\bBearer\s+[A-Za-z0-9._~+/=-]{12,}/gu, "Bearer [REDACTED]")
    .replace(
      /\b(?:sk-ant|sk-proj|sk-|sk_live_|sk_test_|rk_live_|rk_test_)[A-Za-z0-9._-]{12,}\b/giu,
      "[REDACTED_TOKEN]",
    )
    .replace(/\b(?:ghp_|github_pat_)[A-Za-z0-9_]{20,}\b/gu, "[REDACTED_GITHUB_TOKEN]")
    .replace(/\bxox[baprs]-[A-Za-z0-9-]{10,}\b/gu, "[REDACTED_SLACK_TOKEN]")
    .replace(
      /\beyJ[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\.[A-Za-z0-9_-]{10,}\b/gu,
      "[REDACTED_JWT]",
    )
    .replace(
      /\b[A-Za-z0-9._%+-]+@[A-Za-z0-9.-]+\.[A-Za-z]{2,}\b/gu,
      "[REDACTED_EMAIL]",
    );
}

function redactStructuredSecretFields(text) {
  const keyPattern = ASSIGNMENT_KEYS.map(escapeRegExp).join("|");
  return text
    .replace(
      new RegExp(`\\b(${keyPattern})\\b(\\s*[:=]\\s*)(["'])(?:\\\\.|[^\\\\])*?\\3`, "giu"),
      "$1$2$3[REDACTED]$3",
    )
    .replace(
      new RegExp(`(["'])(${keyPattern})\\1(\\s*[:=]\\s*)(["'])(?:\\\\.|[^\\\\])*?\\4`, "giu"),
      "$1$2$1$3$4[REDACTED]$4",
    )
    .replace(
      new RegExp(
        `(<key>\\s*(?:${keyPattern})\\s*</key>\\s*<(?:string|data)>)[\\s\\S]*?(</(?:string|data)>)`,
        "giu",
      ),
      "$1[REDACTED]$2",
    )
    .replace(
      new RegExp(`(<(${keyPattern})\\b[^>]*>)[\\s\\S]*?(</\\2>)`, "giu"),
      "$1[REDACTED]$3",
    );
}

export function redactText(input, exactValues = exactSecretValues()) {
  let output = input;
  for (const value of exactValues) {
    output = output.split(value).join("[REDACTED]");
  }

  output = redactTokenShapes(output);
  output = redactStructuredSecretFields(output);
  output = redactKnownAssignments(output);
  return output;
}

function isProbablyText(buffer, path) {
  const extension = path.includes(".") ? path.slice(path.lastIndexOf(".")) : "";
  if (!TEXT_EXTENSIONS.has(extension)) {
    return false;
  }
  return !buffer.includes(0);
}

function redactFile(path, exactValues) {
  const buffer = readFileSync(path);
  if (!isProbablyText(buffer, path)) {
    return false;
  }

  const before = buffer.toString("utf8");
  const after = redactText(before, exactValues);
  if (after !== before) {
    writeFileSync(path, after, "utf8");
    return true;
  }
  return false;
}

function redactDirectory(root) {
  if (!existsSync(root)) {
    return 0;
  }

  const exactValues = exactSecretValues();
  let changed = 0;
  const stack = [root];
  while (stack.length > 0) {
    const current = stack.pop();
    const stats = statSync(current);
    if (stats.isDirectory()) {
      for (const entry of readdirSync(current)) {
        stack.push(join(current, entry));
      }
      continue;
    }
    if (!stats.isFile() || stats.size > 20 * 1024 * 1024) {
      continue;
    }
    if (redactFile(current, exactValues)) {
      changed += 1;
    }
  }
  return changed;
}

async function redactStream() {
  const exactValues = exactSecretValues();
  const reader = createInterface({ input: process.stdin, crlfDelay: Infinity });
  for await (const line of reader) {
    process.stdout.write(`${redactText(line, exactValues)}\n`);
  }
}

async function main() {
  if (process.argv.includes("--stream")) {
    await redactStream();
    return;
  }

  const target = process.argv[2] ?? "qa-results";
  const changed = redactDirectory(target);
  console.error(`QA artifact redaction complete (${changed} file(s) updated).`);
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  main().catch((error) => {
    console.error(
      `QA artifact redaction failed: ${error instanceof Error ? error.message : String(error)}`,
    );
    process.exit(1);
  });
}
