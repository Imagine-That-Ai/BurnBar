#!/usr/bin/env node

import assert from "node:assert/strict";
import { execFileSync } from "node:child_process";
import { mkdirSync, mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { tmpdir } from "node:os";
import { join } from "node:path";

const SCRIPT = new URL("./redact-qa-artifacts.mjs", import.meta.url).pathname;
const secretEnv = {
  ...process.env,
  FACTORY_API_KEY: "factory_live_secret_123456789",
  FIREBASE_APP_CHECK_DEBUG_TOKEN: "appcheck-debug-token-abcdef123456",
  QA_FIREBASE_EMAIL: "qa+ci@example.invalid",
  QA_FIREBASE_PASSWORD: "qa-password-secret-987654",
};
const fakeGitHubToken = ["ghp", "123456789012345678901234567890123456"].join("_");
const fakeSlackToken = ["xoxb", "123456789012", "abcdefghijklmnopqrstuvwxyz"].join("-");
const opaqueBearerToken = "abcdefghijklmnopqrstuvwxyz123456789";
const structuredPassword = "json-password-abcdef123456";
const structuredToken = "json-token-abcdef123456789";
const plistPassword = "plist-password-abcdef123456";

function run(args, options = {}) {
  return execFileSync("node", [SCRIPT, ...args], {
    env: secretEnv,
    input: options.input,
    encoding: "utf8",
    stdio: options.input ? ["pipe", "pipe", "pipe"] : ["ignore", "pipe", "pipe"],
  });
}

function assertRedacted(text) {
  for (const value of [
    secretEnv.FACTORY_API_KEY,
    secretEnv.FIREBASE_APP_CHECK_DEBUG_TOKEN,
    secretEnv.QA_FIREBASE_EMAIL,
    secretEnv.QA_FIREBASE_PASSWORD,
    fakeGitHubToken,
    fakeSlackToken,
    opaqueBearerToken,
    structuredPassword,
    structuredToken,
    plistPassword,
  ]) {
    assert.equal(text.includes(value), false, `raw sensitive value survived: ${value}`);
  }
}

const roots = [];
process.on("exit", () => {
  for (const root of roots) {
    rmSync(root, { recursive: true, force: true });
  }
});

{
  const output = run(["--stream"], {
    input: [
      `FACTORY_API_KEY=${secretEnv.FACTORY_API_KEY}`,
      `FIRAAppCheckDebugToken=${secretEnv.FIREBASE_APP_CHECK_DEBUG_TOKEN}`,
      `signed in as ${secretEnv.QA_FIREBASE_EMAIL}`,
      `Authorization: Bearer ${opaqueBearerToken}`,
      `{"password":"${structuredPassword}","token":"${structuredToken}"}`,
      `github token ${fakeGitHubToken}`,
      `slack token ${fakeSlackToken}`,
    ].join("\n"),
  });
  assertRedacted(output);
  assert.match(output, /\[REDACTED\]/u);
}

{
  const root = mkdtempSync(join(tmpdir(), "qa-redaction-"));
  roots.push(root);
  mkdirSync(join(root, "logs"));
  writeFileSync(
    join(root, "logs", "firebase-config.log"),
    [
      `token=${secretEnv.FIREBASE_APP_CHECK_DEBUG_TOKEN}`,
      `email=${secretEnv.QA_FIREBASE_EMAIL}`,
      `password=${secretEnv.QA_FIREBASE_PASSWORD}`,
      "safe line stays useful",
    ].join("\n"),
  );
  writeFileSync(
    join(root, "summary.json"),
    JSON.stringify({ note: `Factory key ${secretEnv.FACTORY_API_KEY}` }),
  );
  writeFileSync(
    join(root, "config.plist"),
    [
      "<?xml version=\"1.0\" encoding=\"UTF-8\"?>",
      "<plist>",
      "<dict>",
      "<key>password</key>",
      `<string>${plistPassword}</string>`,
      "</dict>",
      "</plist>",
    ].join("\n"),
  );

  run([root]);

  const log = readFileSync(join(root, "logs", "firebase-config.log"), "utf8");
  const summary = readFileSync(join(root, "summary.json"), "utf8");
  const plist = readFileSync(join(root, "config.plist"), "utf8");
  assertRedacted(`${log}\n${summary}\n${plist}`);
  assert.match(log, /safe line stays useful/u);
}

console.log("PASS: QA artifact redaction controls");
