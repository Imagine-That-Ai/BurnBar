#!/usr/bin/env node
// Canonical candidate-commit selector for domain-core CI.
//
// On pull_request events GITHUB_SHA is the *synthetic merge commit* GitHub
// creates by merging the PR head into the base branch (refs/pull/{n}/merge).
// That ephemeral SHA must never be embedded into a build artifact or used as
// the expected identity for a native-load verifier — the artifact is built
// from the PR head, so the identity chain must bind to the exact PR head SHA.
//
// This module selects the canonical candidate commit:
//   - pull_request       → payload.pull_request.head.sha (the real PR head)
//   - push / dispatch     → GITHUB_SHA (the exact pushed/dispatched commit)
//
// Every returned SHA is re-validated as a full lowercase 40-hex Git SHA-1.
// Any missing coordinate, malformed SHA, or unsupported event throws — the
// caller MUST treat an exception as a fail-closed abort of the promotion
// pipeline, never as a fallback to the synthetic merge SHA.

import { appendFileSync, readFileSync } from "node:fs";

const FULL_GIT_SHA1_PATTERN = /^[0-9a-f]{40}$/;

/**
 * Validate that a string is a full lowercase 40-hex Git SHA-1.
 * Returns the SHA unchanged on success; throws on any deviation.
 */
export function validateCandidateCommit(sha) {
  if (typeof sha !== "string" || !FULL_GIT_SHA1_PATTERN.test(sha)) {
    throw new Error(
      "candidate commit must be a full lowercase 40-character Git SHA-1",
    );
  }
  return sha;
}

/**
 * Select the canonical candidate commit for a domain-core CI run.
 *
 * @param {object}  input
 * @param {string}  input.event       GitHub event name (pull_request, push, workflow_dispatch, …).
 * @param {object}  [input.payload]   Parsed GitHub webhook payload.
 *                                     Required for pull_request events
 *                                     (must contain payload.pull_request.head.sha).
 * @param {string}  [input.fallbackSha] GITHUB_SHA — the exact commit for push/dispatch.
 * @returns {string} A validated lowercase 40-hex Git SHA-1.
 * @throws  {Error}  On missing coordinates, malformed SHAs, or unsupported events.
 */
export function selectCanonicalCandidateCommit({ event, payload, fallbackSha }) {
  if (event === "pull_request") {
    if (!payload || typeof payload !== "object") {
      throw new Error(
        "pull_request event requires a payload with pull_request.head.sha",
      );
    }
    const pr = payload.pull_request;
    if (!pr || typeof pr !== "object") {
      throw new Error("pull_request payload is missing the pull_request object");
    }
    const head = pr.head;
    if (!head || typeof head !== "object") {
      throw new Error("pull_request payload is missing the head object");
    }
    const headSha = head.sha;
    if (typeof headSha !== "string") {
      throw new Error("pull_request head.sha is not a string");
    }
    return validateCandidateCommit(headSha);
  }

  if (event === "push" || event === "workflow_dispatch") {
    if (typeof fallbackSha !== "string") {
      throw new Error(
        `${event} event requires fallbackSha (GITHUB_SHA)`,
      );
    }
    return validateCandidateCommit(fallbackSha);
  }

  throw new Error(
    `unsupported GitHub event for canonical candidate selection: ${event}`,
  );
}

// --- CLI mode --------------------------------------------------------------
// Invoked from a workflow step:
//   node scripts/ci/canonical-candidate-commit.mjs
// Reads GITHUB_EVENT_NAME, GITHUB_EVENT_PATH, and GITHUB_SHA from the
// environment, prints the canonical candidate commit to stdout, and appends
// `candidate_commit=<sha>` to $GITHUB_OUTPUT when that env var is set.

if (import.meta.url === `file://${process.argv[1]}`) {
  const event = process.env.GITHUB_EVENT_NAME;
  const eventPath = process.env.GITHUB_EVENT_PATH;
  const fallbackSha = process.env.GITHUB_SHA;

  let payload;
  if (eventPath) {
    try {
      payload = JSON.parse(readFileSync(eventPath, "utf8"));
    } catch (error) {
      throw new Error(
        `unable to parse GitHub event payload at ${eventPath}: ${error.message}`,
      );
    }
  }

  const candidateCommit = selectCanonicalCandidateCommit({
    event,
    payload,
    fallbackSha,
  });

  const githubOutput = process.env.GITHUB_OUTPUT;
  if (githubOutput) {
    appendFileSync(githubOutput, `candidate_commit=${candidateCommit}\n`);
  }

  process.stdout.write(`${candidateCommit}\n`);
}