#!/usr/bin/env node
/**
 * Provision (create or rotate) the dedicated Firebase Auth account used by
 * local QA runs and the GitHub Actions QA workflow.
 *
 * By design this script:
 *   - Uses Application Default Credentials (`gcloud auth application-default
 *     login` or a service account file via GOOGLE_APPLICATION_CREDENTIALS).
 *   - Targets a single, dedicated email (default: qa+local@openburnbar.app).
 *   - Generates a fresh shell-safe password on every run and seals it into:
 *       1. ~/.openburnbar/qa.env  (chmod 0600, gitignored)
 *       2. macOS Keychain (service: "OpenBurnBar.QAFirebase",
 *                          account: <QA email>)
 *       3. GitHub repo secrets QA_FIREBASE_EMAIL and QA_FIREBASE_PASSWORD
 *          (when run with --sync-github).
 *   - Sets custom claims `{ qa: true, env: "local" }` so server-side checks
 *     can permit QA-only operations.
 *
 * It does NOT touch the production Firebase plist or any user data outside
 * the QA account's own user namespace. The QA account is fully owner-scoped
 * by the existing Firestore rules and exists solely to exercise auth-required
 * QA flows.
 *
 * Usage:
 *   GOOGLE_CLOUD_PROJECT=burnbar node tools/qa/provision-qa-firebase.js
 *   GOOGLE_CLOUD_PROJECT=burnbar node tools/qa/provision-qa-firebase.js --sync-github
 *   node tools/qa/provision-qa-firebase.js --email qa+ci@openburnbar.app
 */

"use strict";

const path = require("path");
const fs = require("fs");
const os = require("os");
const crypto = require("crypto");
const { execFileSync } = require("child_process");

const REPO_ROOT = path.resolve(__dirname, "..", "..");
const ADMIN_PATH = path.join(REPO_ROOT, "functions", "node_modules", "firebase-admin");

if (!fs.existsSync(ADMIN_PATH)) {
  console.error(
    `[fatal] firebase-admin not found at ${ADMIN_PATH}. Run 'npm ci --prefix functions' first.`
  );
  process.exit(2);
}
const admin = require(ADMIN_PATH);

function parseArgs(argv) {
  const args = { email: "qa+local@openburnbar.app", syncGithub: false };
  for (let i = 2; i < argv.length; i += 1) {
    const a = argv[i];
    if (a === "--email") {
      args.email = argv[++i];
    } else if (a === "--sync-github") {
      args.syncGithub = true;
    } else if (a === "-h" || a === "--help") {
      args.help = true;
    } else {
      console.error(`[fatal] unknown argument: ${a}`);
      process.exit(2);
    }
  }
  return args;
}

function generatePassword() {
  // 24-char URL-safe random + uppercase + digits, shell-safe (no
  // characters that need quoting in bash: !, $, `, \, ", ').
  const base = crypto
    .randomBytes(18)
    .toString("base64url")
    .replace(/[^A-Za-z0-9_-]/g, "x");
  return `Qa${base}9z`;
}

function shellQuote(s) {
  return `'${String(s).replace(/'/g, "'\\''")}'`;
}

function writeQaEnv(env) {
  const dir = path.join(os.homedir(), ".openburnbar");
  fs.mkdirSync(dir, { recursive: true, mode: 0o700 });
  const file = path.join(dir, "qa.env");
  const lines = [
    "# OpenBurnBar QA secrets — generated locally, do not commit",
    `FIREBASE_PROJECT_ID=${shellQuote(env.FIREBASE_PROJECT_ID)}`,
  ];
  if (env.FIREBASE_APP_CHECK_DEBUG_TOKEN) {
    lines.push(
      `FIREBASE_APP_CHECK_DEBUG_TOKEN=${shellQuote(env.FIREBASE_APP_CHECK_DEBUG_TOKEN)}`
    );
  }
  for (const k of [
    "QA_FIREBASE_EMAIL",
    "QA_FIREBASE_PASSWORD",
    "QA_FIREBASE_UID",
    "QA_FIREBASE_DISPLAY_NAME",
  ]) {
    if (env[k]) lines.push(`${k}=${shellQuote(env[k])}`);
  }
  fs.writeFileSync(file, lines.join("\n") + "\n", { mode: 0o600 });
  fs.chmodSync(file, 0o600);
  return file;
}

function sealKeychain(email, password) {
  // Idempotent: delete then add.
  try {
    execFileSync(
      "security",
      ["delete-generic-password", "-s", "OpenBurnBar.QAFirebase", "-a", email],
      { stdio: ["ignore", "ignore", "ignore"] }
    );
  } catch {}
  execFileSync(
    "security",
    [
      "add-generic-password",
      "-s",
      "OpenBurnBar.QAFirebase",
      "-a",
      email,
      "-w",
      password,
      "-l",
      "OpenBurnBar QA Firebase Account",
      "-j",
      "QA-only Firebase Auth account; managed by tools/qa/provision-qa-firebase.js",
    ],
    { stdio: ["ignore", "inherit", "inherit"] }
  );
}

function syncGithubSecret(name, value) {
  // Use stdin to avoid leaking the value on the argv list.
  execFileSync("gh", ["secret", "set", name], {
    input: value,
    stdio: ["pipe", "inherit", "inherit"],
  });
}

(async () => {
  const args = parseArgs(process.argv);
  if (args.help) {
    console.log(
      "Usage: node tools/qa/provision-qa-firebase.js [--email EMAIL] [--sync-github]\n" +
        "  --email EMAIL         Firebase Auth email to provision (default: qa+local@openburnbar.app)\n" +
        "  --sync-github         After local sealing, also write QA_FIREBASE_EMAIL/PASSWORD to GitHub secrets via 'gh'.\n"
    );
    process.exit(0);
  }

  const projectId =
    process.env.GOOGLE_CLOUD_PROJECT ||
    process.env.GCLOUD_PROJECT ||
    process.env.FIREBASE_PROJECT ||
    "burnbar";

  admin.initializeApp({ projectId });
  const auth = admin.auth();
  const password = generatePassword();
  let user;
  try {
    user = await auth.getUserByEmail(args.email);
    await auth.updateUser(user.uid, {
      password,
      emailVerified: true,
      disabled: false,
      displayName: "OpenBurnBar QA Local",
    });
    console.error(`[info] rotated existing QA user (uid=${user.uid})`);
  } catch (e) {
    if (e.code === "auth/user-not-found") {
      user = await auth.createUser({
        email: args.email,
        password,
        emailVerified: true,
        displayName: "OpenBurnBar QA Local",
      });
      console.error(`[info] created QA user (uid=${user.uid})`);
    } else {
      throw e;
    }
  }
  await auth.setCustomUserClaims(user.uid, { qa: true, env: "local" });

  const env = {
    FIREBASE_PROJECT_ID: projectId,
    QA_FIREBASE_EMAIL: args.email,
    QA_FIREBASE_PASSWORD: password,
    QA_FIREBASE_UID: user.uid,
    QA_FIREBASE_DISPLAY_NAME: "OpenBurnBar QA Local",
  };
  // Carry over an existing App Check debug token if the env file already has one.
  try {
    const existing = fs
      .readFileSync(path.join(os.homedir(), ".openburnbar", "qa.env"), "utf8")
      .split("\n")
      .reduce((acc, line) => {
        const m = /^([A-Z_][A-Z0-9_]*)=(.*)$/.exec(line.trim());
        if (m) acc[m[1]] = m[2].replace(/^'(.*)'$/, "$1");
        return acc;
      }, {});
    if (existing.FIREBASE_APP_CHECK_DEBUG_TOKEN) {
      env.FIREBASE_APP_CHECK_DEBUG_TOKEN = existing.FIREBASE_APP_CHECK_DEBUG_TOKEN;
    }
  } catch {}

  const envPath = writeQaEnv(env);
  sealKeychain(args.email, password);
  console.error(`[info] sealed creds into ${envPath} and macOS Keychain (OpenBurnBar.QAFirebase)`);

  if (args.syncGithub) {
    syncGithubSecret("QA_FIREBASE_EMAIL", args.email);
    syncGithubSecret("QA_FIREBASE_PASSWORD", password);
    console.error("[info] mirrored QA_FIREBASE_EMAIL/PASSWORD to GitHub repo secrets");
  }

  process.stdout.write(JSON.stringify({ uid: user.uid, email: args.email }) + "\n");
  process.exit(0);
})().catch((err) => {
  console.error("[fatal]", err && (err.stack || err.message || err));
  process.exit(2);
});
