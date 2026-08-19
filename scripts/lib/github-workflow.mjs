/**
 * @fileoverview Minimal, dependency-free reader for GitHub Actions workflows.
 *
 * CI verifiers run from the trusted default-branch tree before `npm ci` has
 * happened, so they cannot import a YAML parser. Six scripts under `scripts/ci`
 * each hand-rolled their own block scanner as a result. This module is the
 * canonical one; new verifiers should import it instead of growing a seventh.
 *
 * It deliberately reads only the structure CI invariants are written against —
 * triggers, path filters, job dependencies, conditions, environments, and the
 * shell/action bodies of steps. It is not a general YAML parser and will not
 * become one: anything needing full YAML semantics belongs in a build step that
 * can install dependencies.
 */

import { readFileSync } from "node:fs";

/** Indentation width of a line, or null for blank lines. */
function indentOf(line) {
  if (line.trim() === "") return null;
  return /^[ ]*/u.exec(line)[0].length;
}

/**
 * Strip a trailing `#` comment, honouring quotes so that `if: ${{ x == '#a' }}`
 * survives intact. Returns the line unchanged when no comment is present.
 */
export function stripComment(line) {
  let single = false;
  let double = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const previous = index > 0 ? line[index - 1] : "";
    if (char === "'" && !double) single = !single;
    else if (char === '"' && !single && previous !== "\\") double = !double;
    else if (
      char === "#" &&
      !single &&
      !double &&
      (index === 0 || /\s/u.test(previous))
    ) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

/**
 * Lines belonging to the block that starts on `startIndex`, i.e. every
 * following line indented deeper than the block's own key.
 */
function blockLines(lines, startIndex) {
  const base = indentOf(lines[startIndex]);
  const out = [];
  for (let index = startIndex + 1; index < lines.length; index += 1) {
    const depth = indentOf(lines[index]);
    if (depth === null) {
      out.push(lines[index]);
      continue;
    }
    if (depth <= base) break;
    out.push(lines[index]);
  }
  // Trailing blank lines belong to whatever comes next, not to this block.
  while (out.length > 0 && out.at(-1).trim() === "") out.pop();
  return out;
}

/**
 * A scalar value for `key` at the given indent, folded onto one line.
 *
 * Handles `key: value`, block scalars (`|`, `>`), and values continued on the
 * following indented lines — all three appear in `if:` conditions across the
 * repo's workflows.
 */
function scalarAt(lines, keyIndex) {
  const line = stripComment(lines[keyIndex]);
  const inline = line.slice(line.indexOf(":") + 1).trim();
  // Block scalar indicators (`|`, `>`, with optional chomping/indent modifiers)
  // introduce a value rather than being one. Treating `>-` as a value is how a
  // condition ends up prefixed with its own indicator.
  const isBlockIndicator = /^[|>][+-]?[0-9]?$/u.test(inline);
  if (inline !== "" && !isBlockIndicator) {
    // A value may still continue on deeper-indented following lines.
    const continued = blockLines(lines, keyIndex)
      .map((entry) => stripComment(entry).trim())
      .filter((entry) => entry !== "" && !entry.startsWith("-"));
    return [inline, ...continued].join(" ").trim();
  }
  return blockLines(lines, keyIndex)
    .map((entry) => stripComment(entry).trim())
    .filter((entry) => entry !== "")
    .join(" ")
    .trim();
}

function parseFlowSequence(text) {
  return text
    .replace(/^\[|\]$/gu, "")
    .split(",")
    .map((entry) => unquote(entry.trim()))
    .filter((entry) => entry !== "");
}

/**
 * List items directly under `key`, unquoted.
 *
 * Accepts all three spellings GitHub allows: a block sequence of `- ` items, an
 * inline flow sequence, and a flow sequence opened on the line *after* the key —
 * which is how `release.yml` writes its longer `needs:` lists. Collapsing that
 * third form into one scalar silently invents a dependency name that matches no
 * job, which makes any `needs`-graph audit under-report rather than fail.
 */
function listAt(lines, keyIndex) {
  const line = stripComment(lines[keyIndex]);
  const inline = line.slice(line.indexOf(":") + 1).trim();
  if (inline.startsWith("[")) return parseFlowSequence(inline);

  const body = blockLines(lines, keyIndex).map((entry) =>
    stripComment(entry).trim(),
  );
  const joined = body.filter((entry) => entry !== "").join(" ");
  if (joined.startsWith("[")) return parseFlowSequence(joined);

  return body
    .filter((entry) => entry.startsWith("- "))
    .map((entry) => unquote(entry.slice(2).trim()));
}

function unquote(value) {
  const trimmed = value.trim();
  if (
    (trimmed.startsWith('"') && trimmed.endsWith('"') && trimmed.length > 1) ||
    (trimmed.startsWith("'") && trimmed.endsWith("'") && trimmed.length > 1)
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

/** Index of the first line declaring `key` at exactly `depth`. */
function findKey(lines, key, depth, from = 0) {
  const pattern = new RegExp(`^[ ]{${depth}}${key}:`, "u");
  for (let index = from; index < lines.length; index += 1) {
    if (pattern.test(stripComment(lines[index]))) return index;
  }
  return -1;
}

/** Keys declared at `depth` within `lines`, in document order. */
function keysAt(lines, depth) {
  const pattern = new RegExp(`^[ ]{${depth}}([A-Za-z0-9_.-]+):`, "u");
  const out = [];
  for (let index = 0; index < lines.length; index += 1) {
    const match = pattern.exec(stripComment(lines[index]));
    if (match) out.push({ key: match[1], index });
  }
  return out;
}

function parseSteps(stepLines) {
  const steps = [];
  const itemIndices = [];
  for (let index = 0; index < stepLines.length; index += 1) {
    if (/^[ ]*-[ ]/u.test(stripComment(stepLines[index]))) {
      itemIndices.push(index);
    }
  }
  for (let position = 0; position < itemIndices.length; position += 1) {
    const start = itemIndices[position];
    const end = itemIndices[position + 1] ?? stepLines.length;
    // Normalise `- name: x` into `  name: x` so the item reads like a mapping.
    const body = stepLines
      .slice(start, end)
      .map((line, offset) =>
        offset === 0 ? line.replace(/^([ ]*)-[ ]/u, "$1  ") : line,
      );
    const depth = indentOf(body[0]) ?? 0;
    const read = (key) => {
      const at = findKey(body, key, depth);
      return at === -1 ? undefined : scalarAt(body, at);
    };
    steps.push({
      name: read("name"),
      uses: read("uses"),
      if: read("if"),
      run: read("run"),
      raw: body.join("\n"),
    });
  }
  return steps;
}

/**
 * Read a workflow file into the subset of structure CI invariants care about.
 *
 * @param {string} path absolute path to a `.yml` workflow
 * @returns {{name: string|undefined, path: string, raw: string,
 *   triggers: Record<string, {paths: string[], branches: string[]}>,
 *   jobs: Record<string, {needs: string[], if: string|undefined,
 *     environment: string|undefined, steps: Array<object>, raw: string}>}}
 */
export function readWorkflow(path) {
  const raw = readFileSync(path, "utf8");
  const lines = raw.split("\n");

  const nameIndex = findKey(lines, "name", 0);
  const name = nameIndex === -1 ? undefined : unquote(scalarAt(lines, nameIndex));

  const triggers = {};
  // `on:` is the YAML 1.1 boolean `true`, so some workflows quote it.
  let onIndex = findKey(lines, "on", 0);
  if (onIndex === -1) onIndex = findKey(lines, '"on"', 0);
  if (onIndex === -1) onIndex = findKey(lines, "'on'", 0);
  if (onIndex !== -1) {
    const onBlock = blockLines(lines, onIndex);
    const depth = onBlock.length > 0 ? (indentOf(onBlock[0]) ?? 2) : 2;
    for (const { key, index } of keysAt(onBlock, depth)) {
      const eventBlock = blockLines(onBlock, index);
      const eventDepth =
        eventBlock.length > 0 ? (indentOf(eventBlock[0]) ?? depth + 2) : depth + 2;
      const pathsAt = findKey(eventBlock, "paths", eventDepth);
      const branchesAt = findKey(eventBlock, "branches", eventDepth);
      triggers[key] = {
        paths: pathsAt === -1 ? [] : listAt(eventBlock, pathsAt),
        branches: branchesAt === -1 ? [] : listAt(eventBlock, branchesAt),
      };
    }
  }

  const jobs = {};
  const jobsIndex = findKey(lines, "jobs", 0);
  if (jobsIndex !== -1) {
    const jobsBlock = blockLines(lines, jobsIndex);
    const depth = jobsBlock.length > 0 ? (indentOf(jobsBlock[0]) ?? 2) : 2;
    for (const { key, index } of keysAt(jobsBlock, depth)) {
      const body = blockLines(jobsBlock, index);
      const bodyDepth = body.length > 0 ? (indentOf(body[0]) ?? depth + 2) : depth + 2;
      const needsAt = findKey(body, "needs", bodyDepth);
      const ifAt = findKey(body, "if", bodyDepth);
      const envAt = findKey(body, "environment", bodyDepth);
      const stepsAt = findKey(body, "steps", bodyDepth);
      const needsInline =
        needsAt === -1
          ? []
          : (() => {
              const list = listAt(body, needsAt);
              if (list.length > 0) return list;
              const scalar = scalarAt(body, needsAt);
              return scalar === "" ? [] : [unquote(scalar)];
            })();
      jobs[key] = {
        needs: needsInline,
        if: ifAt === -1 ? undefined : scalarAt(body, ifAt),
        environment: envAt === -1 ? undefined : unquote(scalarAt(body, envAt)),
        steps: stepsAt === -1 ? [] : parseSteps(blockLines(body, stepsAt)),
        raw: body.join("\n"),
      };
    }
  }

  return { name, path, raw, triggers, jobs };
}

/**
 * GitHub only overrides the implicit `success()` guard on a job when its `if:`
 * calls a status-check function. Without one, a *skipped* upstream job
 * propagates its skip transitively through `needs` — even across an
 * intermediate job that ran under `always()` and succeeded. That is the defect
 * that silently stopped every production hosting deploy for a month.
 *
 * @see docs/CI_RELEASE_RUNBOOK.md
 */
export const STATUS_CHECK_FUNCTIONS = [
  "always()",
  "!cancelled()",
  "cancelled()",
  "success()",
  "failure()",
];

export function hasStatusCheckFunction(condition) {
  if (typeof condition !== "string") return false;
  const normalised = condition.replace(/\s+/gu, "");
  return STATUS_CHECK_FUNCTIONS.some((fn) =>
    normalised.includes(fn.replace(/\s+/gu, "")),
  );
}

/** Every job that `job` depends on, transitively. */
export function transitiveNeeds(jobs, jobName, seen = new Set()) {
  for (const upstream of jobs[jobName]?.needs ?? []) {
    if (seen.has(upstream)) continue;
    seen.add(upstream);
    transitiveNeeds(jobs, upstream, seen);
  }
  return seen;
}
