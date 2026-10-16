#!/usr/bin/env node
/**
 * test-card-host-emulator.mjs — prove how Firebase Hosting serves /c/v1.
 *
 * Firebase documents redirect and cleanUrls behaviour but not which value wins
 * when two header rules set the same key. This runs the real marketing hosting
 * config (copied from firebase.json, with `public` pointed at the built dist/)
 * in the Firebase Hosting emulator and checks the actual responses:
 *   - /c/v1 is 200, unredirected, byte-identical, and carries exactly the
 *     headers effectiveHeaders() predicts (so the route CSP wins over "**");
 *   - /c/v1.html and /c/v1/ are a 301 to exactly /c/v1;
 *   - other products keep the site-wide CSP and cache policy;
 *   - unknown card versions fall through to the site's 404.
 *
 * Local only: it binds 127.0.0.1, uses a demo- project (no credentials, no
 * network calls to Firebase) and deploys nothing.
 *
 * Usage (after npm run build):
 *   npm run test:card-host:emulator
 *   FIREBASE_BIN=/path/to/firebase npm run test:card-host:emulator
 */
import assert from "node:assert/strict";
import { spawn } from "node:child_process";
import { mkdtempSync, readFileSync, rmSync, writeFileSync } from "node:fs";
import { createServer } from "node:net";
import { tmpdir } from "node:os";
import { join, relative } from "node:path";
import { CARD_PUBLIC_FILE, CARD_ROUTE, WEBSITE_ROOT, effectiveHeaders } from "./lib/card-host.mjs";

const REPO_ROOT = join(WEBSITE_ROOT, "..");
const START_TIMEOUT_MS = 120_000;
const REQUEST_TIMEOUT_MS = 10_000;
const firebaseConfig = JSON.parse(readFileSync(join(REPO_ROOT, "firebase.json"), "utf8"));
const marketing = firebaseConfig.hosting.find((site) => site.target === "marketing");
assert.ok(marketing, "firebase.json must define the marketing hosting target");
const firebaseToolsVersion = JSON.parse(
  readFileSync(join(REPO_ROOT, "functions", "package.json"), "utf8")
).devDependencies?.["firebase-tools"];
assert.match(
  firebaseToolsVersion ?? "",
  /^\d+\.\d+\.\d+$/,
  "functions/package.json must pin firebase-tools exactly"
);

function freePort() {
  return new Promise((resolve, reject) => {
    const server = createServer();
    server.once("error", reject);
    server.listen(0, "127.0.0.1", () => {
      const { port } = server.address();
      server.close(() => resolve(port));
    });
  });
}

async function request(base, path) {
  const response = await fetch(`${base}${path}`, {
    redirect: "manual",
    signal: AbortSignal.timeout(REQUEST_TIMEOUT_MS)
  });
  return {
    status: response.status,
    headers: response.headers,
    body: Buffer.from(await response.arrayBuffer())
  };
}

async function waitForHosting(base, child, log) {
  const deadline = Date.now() + START_TIMEOUT_MS;
  while (Date.now() < deadline) {
    if (child.exitCode !== null)
      throw new Error(`the Hosting emulator exited early (${child.exitCode}):\n${log()}`);
    try {
      // A 404 here means the emulator is up but not serving dist/.
      const probe = await request(base, "/robots.txt");
      if (probe.status === 200) return;
      throw new Error(
        `the Hosting emulator answered /robots.txt with ${probe.status}; is dist/ built?`
      );
    } catch (error) {
      if (error instanceof Error && error.message.startsWith("the Hosting emulator answered"))
        throw error;
      await new Promise((resolve) => setTimeout(resolve, 500));
    }
  }
  throw new Error(
    `the Hosting emulator did not answer within ${START_TIMEOUT_MS / 1000}s:\n${log()}`
  );
}

const work = mkdtempSync(join(tmpdir(), "card-host-emulator-"));
const port = await freePort();
const { target: _target, ...site } = marketing;
writeFileSync(
  join(work, "firebase.json"),
  // The emulator resolves `public` relative to the config file and serves
  // nothing for an absolute path, so point at dist/ relatively.
  JSON.stringify({
    hosting: { ...site, public: relative(work, join(WEBSITE_ROOT, "dist")) },
    emulators: { hosting: { host: "127.0.0.1", port } }
  })
);

const [command, ...prefix] = process.env.FIREBASE_BIN
  ? [process.env.FIREBASE_BIN]
  : ["npx", "--yes", `firebase-tools@${firebaseToolsVersion}`];
let output = "";
const child = spawn(
  command,
  [...prefix, "emulators:start", "--only", "hosting", "--project", "demo-burnbar-card-host"],
  {
    cwd: work,
    env: { ...process.env, CI: "1" },
    stdio: ["ignore", "pipe", "pipe"],
    detached: true
  }
);
child.stdout.on("data", (chunk) => (output += chunk));
child.stderr.on("data", (chunk) => (output += chunk));
const stop = () => {
  if (child.exitCode === null) {
    try {
      process.kill(-child.pid, "SIGTERM");
    } catch {
      // already gone
    }
  }
};
process.on("exit", stop);

const base = `http://127.0.0.1:${port}`;
let checks = 0;
const check = (condition, message) => {
  checks += 1;
  assert.ok(condition, message);
};
try {
  await waitForHosting(base, child, () => output.slice(-4000));

  // 1. The exact link: 200, no redirect, the imported bytes, the predicted headers.
  const card = await request(base, CARD_ROUTE);
  check(card.status === 200, `${CARD_ROUTE} must be 200 (got ${card.status})`);
  check(card.headers.get("location") === null, `${CARD_ROUTE} must not redirect`);
  check(
    card.body.equals(readFileSync(join(WEBSITE_ROOT, CARD_PUBLIC_FILE))),
    `${CARD_ROUTE} must serve the imported bytes`
  );
  check(
    card.headers.get("content-type") === "text/html; charset=utf-8",
    `${CARD_ROUTE} content-type: ${card.headers.get("content-type")}`
  );
  const predicted = effectiveHeaders(marketing, CARD_ROUTE);
  for (const [key, value] of predicted) {
    check(
      card.headers.get(key) === value,
      `${CARD_ROUTE} ${key}: expected ${JSON.stringify(value)}, served ${JSON.stringify(card.headers.get(key))}`
    );
  }
  const siteCsp = marketing.headers
    .find((rule) => rule.source === "**")
    .headers.find((header) => header.key === "Content-Security-Policy").value;
  check(
    card.headers.get("content-security-policy") !== siteCsp,
    "the route CSP must win over the site-wide CSP (last match wins)"
  );

  // 2. Variants redirect to the exact link (the fragment survives a 3xx per RFC 9110 §10.2.2).
  for (const variant of [`${CARD_ROUTE}.html`, `${CARD_ROUTE}/`]) {
    const response = await request(base, variant);
    check(response.status === 301, `${variant} must be a 301 (got ${response.status})`);
    check(
      response.headers.get("location") === CARD_ROUTE,
      `${variant} must redirect to ${CARD_ROUTE} (got ${response.headers.get("location")})`
    );
  }

  // 3. Other products keep the site-wide policy.
  for (const path of ["/", "/download", "/pricing", "/privacy"]) {
    const response = await request(base, path);
    check(response.status === 200, `${path} must stay 200 (got ${response.status})`);
    check(
      response.headers.get("content-security-policy") === siteCsp,
      `${path} must keep the site-wide CSP`
    );
    check(
      response.headers.get("cache-control") === "no-cache, must-revalidate",
      `${path} must keep its cache policy`
    );
  }

  // 4. Unknown versions are not served by the card page.
  const v2 = await request(base, "/c/v2");
  check(v2.status === 404, `/c/v2 must be 404 (got ${v2.status})`);
} finally {
  stop();
  rmSync(work, { recursive: true, force: true });
}

console.log(
  `✓ card host emulator (firebase-tools ${firebaseToolsVersion}): ${checks} checks; ${CARD_ROUTE} 200 with route-scoped headers, ` +
    `variants 301 to ${CARD_ROUTE}, site-wide CSP unchanged elsewhere.`
);
process.exit(0);
