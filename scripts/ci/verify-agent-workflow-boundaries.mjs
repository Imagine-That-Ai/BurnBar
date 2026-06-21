#!/usr/bin/env node
/**
 * Static boundary gate for interactive agent workflows.
 *
 * Secrets-bearing agent workflows may post PR/issue feedback, but they must not
 * receive repository write checkout credentials by default. The Factory API key
 * must be passed only to the action invocation or the Droid CLI execution step,
 * interactive executions must receive the bounded workflow token explicitly,
 * and PR-triggered agent runs must remain scoped to same-repository pull
 * requests. The only OIDC exception is the pinned automatic Droid review
 * validator, which requires id-token:write after the main review run.
 *
 * Usage:  node scripts/ci/verify-agent-workflow-boundaries.mjs
 * Exit:   0 = all scoped workflows are structurally gated; 1 = violation;
 *         2 = repository/workflow directory misconfigured.
 */

import { existsSync, readFileSync, readdirSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const REPO_ROOT = process.env.AGENT_WORKFLOW_BOUNDARY_ROOT
  ? process.env.AGENT_WORKFLOW_BOUNDARY_ROOT
  : join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW_DIR = join(REPO_ROOT, ".github", "workflows");

const failures = [];
const fail = (file, message) => failures.push(`${file}: ${message}`);
const FACTORY_KEY_VALUE = "${{ secrets.FACTORY_API_KEY }}";

function workflowFiles() {
  if (!existsSync(WORKFLOW_DIR)) {
    console.error(`MISCONFIGURED: workflow directory not found: ${WORKFLOW_DIR}`);
    process.exit(2);
  }
  return readdirSync(WORKFLOW_DIR)
    .filter((name) => /\.ya?ml$/u.test(name))
    .sort();
}

function stripYamlLineComment(line) {
  let singleQuoted = false;
  let doubleQuoted = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    const previous = index > 0 ? line[index - 1] : "";
    if (char === "'" && !doubleQuoted) {
      singleQuoted = !singleQuoted;
      continue;
    }
    if (char === '"' && !singleQuoted && previous !== "\\") {
      doubleQuoted = !doubleQuoted;
      continue;
    }
    if (char === "#" && !singleQuoted && !doubleQuoted && (index === 0 || /\s/u.test(previous))) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

function stripYamlComments(source) {
  return source
    .split("\n")
    .map((line) => stripYamlLineComment(line))
    .join("\n");
}

function indentOf(line) {
  return line.match(/^(\s*)/u)[1].length;
}

function isBlank(line) {
  return line.trim().length === 0;
}

function blockSource(lines, start, end) {
  return lines.slice(start, end).join("\n");
}

function hasDroidActionSurface(source) {
  return /Factory-AI\/droid-action@/u.test(source);
}

function blockHasDroidExec(source) {
  return /\bdroid\s+exec\b/u.test(source);
}

function stepRunValue(step) {
  return directEntryValue(step, "run") ?? "";
}

function stepRunsDroidExec(step) {
  return blockHasDroidExec(stepRunValue(step));
}

function hasDroidCliSurface(source) {
  const lines = source.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const runMatch = line.match(/^(\s*)run:\s*(.*)$/u);
    if (!runMatch) continue;
    if (blockHasDroidExec(runMatch[2])) return true;
    if (!/^[>|]/u.test(runMatch[2].trim())) continue;

    const runIndent = runMatch[1].length;
    for (let blockIndex = index + 1; blockIndex < lines.length; blockIndex += 1) {
      const blockLine = lines[blockIndex];
      if (!isBlank(blockLine) && indentOf(blockLine) <= runIndent) break;
      if (blockHasDroidExec(blockLine)) return true;
    }
  }
  return false;
}

function hasInteractiveAgentSurface(source) {
  return hasDroidActionSurface(source) || hasDroidCliSurface(source);
}

function jobBlocks(source) {
  const lines = source.split("\n");
  const jobsIndex = lines.findIndex((line) => /^(\s*)jobs:\s*$/u.test(line));
  if (jobsIndex === -1) return [{ start: 0, end: lines.length, source }];

  const jobsIndent = indentOf(lines[jobsIndex]);
  let jobIndent = null;
  const blocks = [];
  for (let index = jobsIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    const lineIndent = indentOf(line);
    if (lineIndent <= jobsIndent) break;

    const jobMatch = line.match(/^(\s*)[A-Za-z0-9_-]+:\s*$/u);
    if (!jobMatch) continue;
    if (jobIndent === null) jobIndent = lineIndent;
    if (lineIndent !== jobIndent) continue;

    let end = lines.length;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const cursorLine = lines[cursor];
      if (isBlank(cursorLine)) continue;
      const cursorIndent = indentOf(cursorLine);
      if (cursorIndent <= jobsIndent) {
        end = cursor;
        break;
      }
      if (cursorIndent === jobIndent && /^(\s*)[A-Za-z0-9_-]+:\s*$/u.test(cursorLine)) {
        end = cursor;
        break;
      }
    }
    blocks.push({ start: index, end, source: blockSource(lines, index, end) });
    index = end - 1;
  }

  return blocks.length > 0 ? blocks : [{ start: 0, end: lines.length, source }];
}

function stepBlocks(source) {
  const lines = source.split("\n");
  const blocks = [];
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    const stepsMatch = line.match(/^(\s*)steps:\s*$/u);
    if (!stepsMatch) continue;

    const stepsIndent = stepsMatch[1].length;
    let stepIndent = null;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const cursorLine = lines[cursor];
      if (isBlank(cursorLine)) continue;
      const cursorIndent = indentOf(cursorLine);
      if (cursorIndent <= stepsIndent) break;

      const stepMatch = cursorLine.match(/^(\s*)-\s+/u);
      if (!stepMatch) continue;
      if (stepIndent === null) stepIndent = stepMatch[1].length;
      if (stepMatch[1].length !== stepIndent) continue;

      let end = lines.length;
      for (let endCursor = cursor + 1; endCursor < lines.length; endCursor += 1) {
        const endLine = lines[endCursor];
        if (isBlank(endLine)) continue;
        const endIndent = indentOf(endLine);
        if (endIndent <= stepsIndent) {
          end = endCursor;
          break;
        }
        const nextStep = endLine.match(/^(\s*)-\s+/u);
        if (nextStep && nextStep[1].length === stepIndent) {
          end = endCursor;
          break;
        }
      }
      blocks.push({ start: cursor, end, source: blockSource(lines, cursor, end) });
      cursor = end - 1;
    }
  }
  return blocks;
}

function blockContainingLine(blocks, lineIndex) {
  return blocks.find((block) => block.start <= lineIndex && lineIndex < block.end);
}

function uniqueBlocks(blocks) {
  return [...new Map(blocks.map((block) => [block.start, block])).values()];
}

function normalizeYamlScalar(value) {
  const trimmed = value.trim();
  if (
    trimmed.length >= 2 &&
    ((trimmed.startsWith('"') && trimmed.endsWith('"')) ||
      (trimmed.startsWith("'") && trimmed.endsWith("'")))
  ) {
    return trimmed.slice(1, -1);
  }
  return trimmed;
}

function firstChildIndent(lines, startIndex, parentIndent) {
  for (let index = startIndex; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    const lineIndent = indentOf(line);
    if (lineIndent <= parentIndent) return null;
    return lineIndent;
  }
  return null;
}

function blockDirectIndent(lines, parentIndent) {
  if (/^\s*-\s+[A-Za-z0-9_-]+:\s*/u.test(lines[0] ?? "")) return parentIndent + 2;
  return firstChildIndent(lines, 1, parentIndent);
}

function topLevelSectionHasEntry(source, sectionName, key, expectedValue) {
  const lines = source.split("\n");
  const sectionIndex = lines.findIndex((line) =>
    line.match(new RegExp(`^${sectionName}:\\s*$`, "u")),
  );
  if (sectionIndex === -1) return false;

  let entryIndent = null;
  for (let index = sectionIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    const lineIndent = indentOf(line);
    if (lineIndent === 0) break;
    if (entryIndent === null) entryIndent = lineIndent;
    if (lineIndent !== entryIndent) continue;

    const entry = line.match(/^\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
    if (entry?.[1] === key && normalizeYamlScalar(entry[2]) === expectedValue) return true;
  }

  return false;
}

function directEntryValue(block, key) {
  const lines = block.source.split("\n");
  const blockIndent = indentOf(lines[0] ?? "");
  const firstLine = lines[0]?.match(/^\s*-\s+([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
  if (firstLine?.[1] === key) return directEntryScalarValue(lines, 0, blockIndent + 2, firstLine[2]);

  const directIndent = blockDirectIndent(lines, blockIndent);
  if (directIndent === null) return null;
  for (let index = 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    const lineIndent = indentOf(line);
    if (lineIndent <= blockIndent) break;
    if (lineIndent !== directIndent) continue;

    const entry = line.match(/^\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
    if (entry?.[1] === key) return directEntryScalarValue(lines, index, lineIndent, entry[2]);
  }
  return null;
}

function splitFlowMappingEntries(value) {
  const trimmed = normalizeYamlScalar(value);
  if (!trimmed.startsWith("{") || !trimmed.endsWith("}")) return [];
  const body = trimmed.slice(1, -1);
  const entries = [];
  let quote = null;
  let depth = 0;
  let start = 0;

  for (let index = 0; index < body.length; index += 1) {
    const char = body[index];
    const previous = index > 0 ? body[index - 1] : "";
    if (quote) {
      if (char === quote && (quote === "'" || previous !== "\\")) quote = null;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === "{" || char === "[" || char === "(") depth += 1;
    if (char === "}" || char === "]" || char === ")") depth = Math.max(0, depth - 1);
    if (char === "," && depth === 0) {
      entries.push(body.slice(start, index).trim());
      start = index + 1;
    }
  }

  entries.push(body.slice(start).trim());
  return entries.filter(Boolean);
}

function flowMappingHasEntry(value, key, expectedValue) {
  for (const entry of splitFlowMappingEntries(value ?? "")) {
    const match = entry.match(/^([^:]+):\s*(.*?)\s*$/u);
    if (!match) continue;
    if (normalizeYamlScalar(match[1]) !== key) continue;
    if (normalizeYamlScalar(match[2]) === expectedValue) return true;
  }
  return false;
}

function directEntryScalarValue(lines, entryIndex, entryIndent, rawValue) {
  const normalized = normalizeYamlScalar(rawValue);
  if (!/^[>|]/u.test(normalized)) return normalized;

  const scalarLines = [];
  for (let index = entryIndex + 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (!isBlank(line) && indentOf(line) <= entryIndent) break;
    scalarLines.push(line.trim());
  }
  return scalarLines.join(normalized.startsWith(">") ? " " : "\n").trim();
}

function directSectionLines(block, sectionName) {
  const lines = block.source.split("\n");
  const blockIndent = indentOf(lines[0] ?? "");
  const sectionIndent = blockDirectIndent(lines, blockIndent);
  if (sectionIndent === null) return [];
  const sections = [];

  for (let index = 1; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line)) continue;
    const lineIndent = indentOf(line);
    if (lineIndent <= blockIndent) break;
    if (lineIndent !== sectionIndent) continue;

    const section = line.match(/^\s*([A-Za-z0-9_-]+):\s*$/u);
    if (section?.[1] !== sectionName) continue;

    let end = lines.length;
    for (let cursor = index + 1; cursor < lines.length; cursor += 1) {
      const cursorLine = lines[cursor];
      if (isBlank(cursorLine)) continue;
      if (indentOf(cursorLine) <= sectionIndent) {
        end = cursor;
        break;
      }
    }
    sections.push({ indent: sectionIndent, lines: lines.slice(index + 1, end) });
  }
  return sections;
}

function sectionHasEntry(block, sectionName, key, expectedValue) {
  for (const section of directSectionLines(block, sectionName)) {
    let entryIndent = null;
    for (let index = 0; index < section.lines.length; index += 1) {
      const line = section.lines[index];
      if (isBlank(line)) continue;
      const lineIndent = indentOf(line);
      if (lineIndent <= section.indent) break;
      if (entryIndent === null) entryIndent = lineIndent;
      if (lineIndent !== entryIndent) continue;
      const entry = line.match(/^\s*([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
      if (entry?.[1] !== key) continue;
      if (directEntryScalarValue(section.lines, index, lineIndent, entry[2]) === expectedValue) {
        return true;
      }
    }
  }
  return false;
}

function mappingHasEntry(block, sectionName, key, expectedValue) {
  return (
    sectionHasEntry(block, sectionName, key, expectedValue) ||
    flowMappingHasEntry(directEntryValue(block, sectionName), key, expectedValue)
  );
}

function topLevelMappingHasEntry(source, sectionName, key, expectedValue) {
  return (
    topLevelSectionHasEntry(source, sectionName, key, expectedValue) ||
    flowMappingHasEntry(topLevelEntryValue(source, sectionName), key, expectedValue)
  );
}

function normalizedCondition(condition) {
  return condition.replace(/\s+/gu, " ").trim();
}

function splitTopLevelBooleanOperator(condition, operator) {
  const parts = [];
  let quote = null;
  let depth = 0;
  let start = 0;

  for (let index = 0; index < condition.length; index += 1) {
    const char = condition[index];
    const previous = index > 0 ? condition[index - 1] : "";
    if (quote) {
      if (char === quote && (quote === "'" || previous !== "\\")) quote = null;
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      continue;
    }
    if (char === "(") {
      depth += 1;
      continue;
    }
    if (char === ")") {
      depth = Math.max(0, depth - 1);
      continue;
    }
    if (depth === 0 && condition.slice(index, index + operator.length) === operator) {
      parts.push(condition.slice(start, index).trim());
      start = index + operator.length;
      index += operator.length - 1;
    }
  }

  parts.push(condition.slice(start).trim());
  return parts.filter(Boolean);
}

function exactConditionTerms(condition, operator) {
  return splitTopLevelBooleanOperator(stripBalancedOuterParens(condition), operator).map((part) =>
    stripBalancedOuterParens(part).trim(),
  );
}

function conditionRequiresEventConjunct(condition, eventConjunct, requiredConjunct) {
  const normalized = normalizedCondition(condition);
  let sawEventBranch = false;
  for (const branch of exactConditionTerms(normalized, "||")) {
    const conjuncts = new Set(exactConditionTerms(branch, "&&"));
    if (!conjuncts.has(eventConjunct)) continue;
    sawEventBranch = true;
    if (!conjuncts.has(requiredConjunct)) return false;
  }
  return sawEventBranch;
}

function conditionRequiresGlobalConjunctWithoutDisjunction(condition, requiredConjunct) {
  const normalized = normalizedCondition(condition);
  if (splitTopLevelBooleanOperator(normalized, "||").length > 1) return false;
  return new Set(exactConditionTerms(normalized, "&&")).has(requiredConjunct);
}

function stripBalancedOuterParens(expression) {
  let normalized = expression.trim();
  while (normalized.startsWith("(") && normalized.endsWith(")")) {
    let depth = 0;
    let wraps = true;
    for (let index = 0; index < normalized.length; index += 1) {
      const char = normalized[index];
      if (char === "(") depth += 1;
      if (char === ")") depth -= 1;
      if (depth === 0 && index < normalized.length - 1) {
        wraps = false;
        break;
      }
      if (depth < 0) {
        wraps = false;
        break;
      }
    }
    if (!wraps || depth !== 0) break;
    normalized = normalized.slice(1, -1).trim();
  }
  return normalized;
}

function conditionHasDisallowedAlwaysTrue(condition) {
  return splitTopLevelBooleanOperator(normalizedCondition(condition), "||")
    .some((part) => {
      const literal = stripBalancedOuterParens(part).replace(/\s+/gu, "");
      const match = literal.match(/^(!*)(true|false)$/u);
      if (!match) return false;
      const value = match[2] === "true";
      const negated = match[1].length % 2 === 1;
      return negated ? !value : value;
    });
}

function conditionHasRequiredConjunctsOnly(condition, requiredConjuncts) {
  const normalized = normalizedCondition(condition);
  if (
    splitTopLevelBooleanOperator(normalized, "||").length > 1 ||
    conditionHasDisallowedAlwaysTrue(normalized)
  ) {
    return false;
  }
  const conjuncts = new Set(exactConditionTerms(normalized, "&&"));
  return requiredConjuncts.every((required) => conjuncts.has(required));
}

function stepUsesAction(step, action) {
  return directEntryValue(step, "uses")?.startsWith(action) ?? false;
}

function stepUsesDroidAction(step) {
  return stepUsesAction(step, "Factory-AI/droid-action@");
}

function topLevelEntryValue(source, key) {
  const lines = source.split("\n");
  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (isBlank(line) || indentOf(line) !== 0) continue;
    const entry = line.match(/^([A-Za-z0-9_-]+):\s*(.*?)\s*$/u);
    if (entry?.[1] === key) return directEntryScalarValue(lines, index, 0, entry[2]);
  }
  return null;
}

function jobSteps(job, steps) {
  return steps.filter((step) => job.start <= step.start && step.start < job.end);
}

function stepWithId(job, steps, id) {
  return jobSteps(job, steps).find((step) => directEntryValue(step, "id") === id) ?? null;
}

function readShellHeredocDelimiter(line, start) {
  if (start >= line.length) return null;
  const first = line[start];
  if (first === "'" || first === '"') {
    let escaped = false;
    let delimiter = "";
    for (let index = start + 1; index < line.length; index += 1) {
      const char = line[index];
      if (first === '"' && !escaped && char === "\\") {
        escaped = true;
        continue;
      }
      if (!escaped && char === first) return { delimiter, end: index + 1 };
      delimiter += char;
      escaped = false;
    }
    return null;
  }

  let delimiter = "";
  let index = start;
  while (index < line.length && !/[\s;&|()<>]/u.test(line[index])) {
    delimiter += line[index];
    index += 1;
  }
  delimiter = delimiter.replace(/\\/gu, "");
  return delimiter.length > 0 ? { delimiter, end: index } : null;
}

function shellLineHeredocDelimiters(line) {
  const delimiters = [];
  let quote = null;
  let escaped = false;
  for (let index = 0; index < line.length; index += 1) {
    const char = line[index];
    if (quote) {
      if (quote === '"' && !escaped && char === "\\") {
        escaped = true;
      } else {
        if (!escaped && char === quote) quote = null;
        escaped = false;
      }
      continue;
    }

    if (char === "'" || char === '"') {
      quote = char;
      escaped = false;
      continue;
    }
    if (char === "#") break;
    if (char !== "<" || line[index + 1] !== "<" || line[index + 2] === "<") continue;

    let cursor = index + 2;
    const stripTabs = line[cursor] === "-";
    if (stripTabs) cursor += 1;
    while (cursor < line.length && /\s/u.test(line[cursor])) cursor += 1;
    const parsed = readShellHeredocDelimiter(line, cursor);
    if (parsed) {
      delimiters.push({ delimiter: parsed.delimiter, stripTabs });
      index = parsed.end - 1;
    }
  }
  return delimiters;
}

function maskShellHeredocBodies(body) {
  const pending = [];
  return body
    .split("\n")
    .map((line) => {
      if (pending.length > 0) {
        const current = pending[0];
        const comparable = current.stripTabs ? line.replace(/^\t+/u, "") : line;
        if (comparable === current.delimiter) pending.shift();
        return " ".repeat(line.length);
      }

      pending.push(...shellLineHeredocDelimiters(line));
      return line;
    })
    .join("\n");
}

function maskShellStringsAndComments(body) {
  const bodyWithoutHeredocs = maskShellHeredocBodies(body);
  let masked = "";
  let quote = null;
  let escaped = false;
  let inComment = false;
  for (const char of bodyWithoutHeredocs) {
    if (inComment) {
      if (char === "\n") {
        inComment = false;
        masked += char;
      } else {
        masked += " ";
      }
      escaped = false;
      continue;
    }

    if (quote) {
      if (quote === '"' && !escaped && char === "\\") {
        escaped = true;
      } else {
        if (!escaped && char === quote) quote = null;
        escaped = false;
      }
      masked += char === "\n" ? char : " ";
      continue;
    }

    if (char === "'" || char === '"') {
      quote = char;
      masked += " ";
      escaped = false;
      continue;
    }

    if (char === "#") {
      inComment = true;
      masked += " ";
      escaped = false;
      continue;
    }

    masked += char;
    escaped = false;
  }
  return masked;
}

function positionIsInsideShellStringOrComment(source, position) {
  let quote = null;
  let escaped = false;
  let inComment = false;
  for (let index = 0; index < position; index += 1) {
    const char = source[index];
    if (inComment) {
      if (char === "\n") inComment = false;
      escaped = false;
      continue;
    }
    if (quote) {
      if (quote === '"' && !escaped && char === "\\") {
        escaped = true;
      } else {
        if (!escaped && char === quote) quote = null;
        escaped = false;
      }
      continue;
    }
    if (char === "'" || char === '"') {
      quote = char;
      escaped = false;
      continue;
    }
    if (char === "#") {
      inComment = true;
      escaped = false;
    }
  }
  return quote !== null || inComment;
}

function shellBlockHasTopLevelNonzeroExit(body) {
  const executableBody = maskShellStringsAndComments(body);
  const tokenPattern = /\bif\b|\belif\b|\belse\b|\bfi\b|\bexit\s+[1-9][0-9]*\b|\(|\)/gu;
  let depth = 0;
  let parenDepth = 0;
  let match = tokenPattern.exec(executableBody);
  while (match) {
    const token = match[0];
    if (token === "(") {
      parenDepth += 1;
    } else if (token === ")") {
      parenDepth = Math.max(0, parenDepth - 1);
    } else if (token === "if") {
      depth += 1;
    } else if ((token === "elif" || token === "else") && depth === 0) {
      return false;
    } else if (token === "fi") {
      if (depth === 0) return false;
      depth -= 1;
    } else if (depth === 0 && parenDepth === 0) {
      return true;
    }
    match = tokenPattern.exec(executableBody);
  }
  return false;
}

function droidCliStepFailsClosed(step) {
  const run = stepRunValue(step);
  const searchableRun = maskShellHeredocBodies(run);
  const preflightPattern =
    /if\s+\[\[\s+-z\s+"\$\{FACTORY_API_KEY\}"\s*\]\]\s*;?\s*then/gu;
  let match = preflightPattern.exec(searchableRun);
  while (match) {
    if (
      !positionIsInsideShellStringOrComment(run, match.index) &&
      shellBlockHasTopLevelNonzeroExit(run.slice(match.index + match[0].length))
    ) {
      return true;
    }
    match = preflightPattern.exec(searchableRun);
  }
  return false;
}

function hasDroidReviewOidcException(step) {
  return (
    stepUsesDroidAction(step) &&
    mappingHasEntry(step, "with", "automatic_review", "true") &&
    mappingHasEntry(step, "with", "automatic_security_review", "true") &&
    mappingHasEntry(step, "with", "github_token", "${{ github.token }}") &&
    mappingHasEntry(step, "with", "factory_api_key", "${{ secrets.FACTORY_API_KEY }}")
  );
}

function issueCommentScopeStepVerifiesSameRepository(scopeStep) {
  const run = stepRunValue(scopeStep);
  const assignsHeadRepoFromGhApi = /^ *head_repo="\$\(gh api "\$\{PR_URL\}" --jq '\.head\.repo\.full_name'\)" *$/mu.test(
    run,
  );
  const rejectsDifferentRepository =
    /^ *if \[\[ "\$\{head_repo\}" != "\$\{REPOSITORY\}" \]\]; then *$/mu.test(run) &&
    /^ *allowed=false *$/mu.test(run);
  const writesAllowedOutput = /^ *echo "allowed=\$\{allowed\}" >> "\$\{GITHUB_OUTPUT\}" *$/mu.test(run);
  return assignsHeadRepoFromGhApi && rejectsDifferentRepository && writesAllowedOutput;
}

for (const file of workflowFiles()) {
  const rawSource = readFileSync(join(WORKFLOW_DIR, file), "utf8");
  const source = stripYamlComments(rawSource);
  if (!hasInteractiveAgentSurface(source)) continue;

  const usesDroidAction = hasDroidActionSurface(source);
  const usesDroidCli = hasDroidCliSurface(source);
  const jobs = jobBlocks(source);
  const steps = stepBlocks(source);
  const droidActionSteps = steps.filter(stepUsesDroidAction);
  const droidActionJobs = uniqueBlocks(
    droidActionSteps
      .map((step) => blockContainingLine(jobs, step.start))
      .filter(Boolean),
  );

  const grantsContentsWrite =
    topLevelMappingHasEntry(source, "permissions", "contents", "write") ||
    jobs.some((job) => mappingHasEntry(job, "permissions", "contents", "write"));
  if (grantsContentsWrite || topLevelEntryValue(source, "permissions") === "write-all" ||
    jobs.some((job) => directEntryValue(job, "permissions") === "write-all")
  ) {
    fail(file, "interactive agent workflow must not request contents:write");
  }
  if (topLevelMappingHasEntry(source, "permissions", "id-token", "write")) {
    fail(file, "interactive agent workflow must not grant id-token:write at workflow scope");
  }
  for (const job of jobs) {
    if (!mappingHasEntry(job, "permissions", "id-token", "write")) continue;
    if (!jobSteps(job, droidActionSteps).some(hasDroidReviewOidcException)) {
      fail(file, "interactive agent workflow must not request id-token:write outside automatic Droid review validation");
    }
  }

  if (usesDroidAction) {
    if (
      topLevelMappingHasEntry(source, "env", "FACTORY_API_KEY", FACTORY_KEY_VALUE) ||
      jobs.some((job) => mappingHasEntry(job, "env", "FACTORY_API_KEY", FACTORY_KEY_VALUE))
    ) {
      fail(file, "Factory API key must not be exposed in Droid-action workflow or job env");
    }

    for (const job of droidActionJobs) {
      if (
        !mappingHasEntry(
          job,
          "env",
          "FACTORY_API_KEY_AVAILABLE",
          "${{ secrets.FACTORY_API_KEY != '' }}",
        )
      ) {
        fail(file, "missing boolean Factory API key availability env");
      }
      if (
        !steps.some(
          (step) =>
            blockContainingLine(jobs, step.start) === job &&
            directEntryValue(step, "if") === "env.FACTORY_API_KEY_AVAILABLE == 'false'",
        )
      ) {
        fail(file, "missing fail-closed no-key skip step");
      }
    }

    for (const step of droidActionSteps) {
      const requiredActionConjuncts = ["env.FACTORY_API_KEY_AVAILABLE == 'true'"];
      if (/issue_comment:/u.test(source)) {
        requiredActionConjuncts.push("steps.pr-comment-scope.outputs.allowed == 'true'");
      }
      if (!conditionHasRequiredConjunctsOnly(directEntryValue(step, "if") ?? "", requiredActionConjuncts)) {
        fail(file, "agent action must be gated by boolean Factory key availability");
      }
      if (!mappingHasEntry(step, "with", "factory_api_key", "${{ secrets.FACTORY_API_KEY }}")) {
        fail(file, "Factory API key must be passed only as the Droid action input");
      }
      if (!mappingHasEntry(step, "with", "github_token", "${{ github.token }}")) {
        fail(file, "Droid action must use the bounded workflow token instead of OIDC token minting");
      }
    }
  }

  if (usesDroidCli) {
    if (
      !steps.some(
        (step) =>
          stepRunsDroidExec(step) &&
          mappingHasEntry(step, "env", "FACTORY_API_KEY", FACTORY_KEY_VALUE),
      )
    ) {
      fail(file, "Droid CLI workflow must pass Factory key only to the Droid execution step");
    }
    if (!steps.some((step) => stepRunsDroidExec(step) && droidCliStepFailsClosed(step))) {
      fail(file, "Droid CLI workflow must fail closed when FACTORY_API_KEY is unavailable");
    }
  }

  for (const step of steps) {
    if (!mappingHasEntry(step, "env", "FACTORY_API_KEY", FACTORY_KEY_VALUE)) continue;
    if (!stepRunsDroidExec(step)) {
      fail(file, "Factory API key secret env must appear only on Droid CLI execution steps");
    }
  }

  for (const step of steps) {
    if (
      stepUsesAction(step, "actions/checkout@") &&
      !mappingHasEntry(step, "with", "persist-credentials", "false")
    ) {
      fail(file, "each agent workflow checkout must set persist-credentials:false");
    }
  }

  if (
    /pull_request:/u.test(source) ||
    /pull_request_review:/u.test(source) ||
    /pull_request_review_comment:/u.test(source)
  ) {
    for (const job of droidActionJobs) {
      const jobIf = directEntryValue(job, "if") ?? "";
      if (conditionHasDisallowedAlwaysTrue(jobIf)) {
        fail(file, "PR-triggered agent workflow must not include always-true bypasses");
      }
      const sameRepositoryConjunct =
        "github.event.pull_request.head.repo.full_name == github.repository";

      const hasPullRequestReviewCommentGuard =
        !/pull_request_review_comment:/u.test(source) ||
        conditionRequiresEventConjunct(
          jobIf,
          "github.event_name == 'pull_request_review_comment'",
          sameRepositoryConjunct,
        );
      const hasPullRequestReviewGuard =
        !/pull_request_review:/u.test(source) ||
        conditionRequiresEventConjunct(
          jobIf,
          "github.event_name == 'pull_request_review'",
          sameRepositoryConjunct,
        );
      const hasPullRequestGuard =
        !/pull_request:/u.test(source) ||
        conditionRequiresEventConjunct(
          jobIf,
          "github.event_name == 'pull_request'",
          sameRepositoryConjunct,
        ) ||
        conditionRequiresGlobalConjunctWithoutDisjunction(jobIf, sameRepositoryConjunct);

      if (!hasPullRequestReviewCommentGuard || !hasPullRequestReviewGuard || !hasPullRequestGuard) {
        fail(file, "PR-triggered agent workflow must require same-repository pull requests");
      }
    }
  }

  if (/issue_comment:/u.test(source)) {
    for (const job of droidActionJobs) {
      if (
        !droidActionSteps.some(
          (step) =>
            blockContainingLine(jobs, step.start) === job &&
            conditionHasRequiredConjunctsOnly(directEntryValue(step, "if") ?? "", [
              "env.FACTORY_API_KEY_AVAILABLE == 'true'",
              "steps.pr-comment-scope.outputs.allowed == 'true'",
            ]),
        )
      ) {
        fail(file, "issue-comment agent workflow must gate Droid execution on resolved PR comment scope");
      }

      const scopeStep = stepWithId(job, steps, "pr-comment-scope");
      if (!scopeStep) {
        fail(file, "issue-comment agent workflow must resolve PR comment scope before Droid execution");
        continue;
      }
      if (
        !mappingHasEntry(
          scopeStep,
          "env",
          "ISSUE_IS_PR",
          "${{ github.event.issue.pull_request != null }}",
        ) ||
        !mappingHasEntry(
          scopeStep,
          "env",
          "PR_URL",
          "${{ github.event.issue.pull_request.url || '' }}",
        )
      ) {
        fail(file, "issue-comment agent workflow must look up PR metadata before running on PR comments");
      }
      if (!issueCommentScopeStepVerifiesSameRepository(scopeStep)) {
        fail(file, "issue-comment agent workflow must verify PR comments come from same-repository pull requests");
      }
    }
  }
}

if (failures.length > 0) {
  console.error("Agent workflow boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: interactive agent workflows keep secrets and write privileges bounded.");
