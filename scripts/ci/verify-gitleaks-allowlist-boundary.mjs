#!/usr/bin/env node
/**
 * Verifies that gitleaks global allowlists cannot suppress by file path alone.
 *
 * Any allowlist that combines `paths` with another suppression criterion must
 * use `condition = "AND"` so the exception only applies when both the expected
 * content/commit pattern and expected path match.
 */

import { readFileSync } from "node:fs";
import { fileURLToPath } from "node:url";

const DEFAULT_CONFIG = ".gitleaks.toml";

export function findAllowlistBoundaryViolations(configText) {
  const lines = configText.split(/\r?\n/u);
  const sections = [];
  let current = null;

  function finishCurrent() {
    if (current) {
      sections.push(current);
    }
  }

  for (let index = 0; index < lines.length; index += 1) {
    const line = lines[index];
    if (
      /^\s*\[\[allowlists\]\]\s*$/u.test(line) ||
      /^\s*\[allowlist\]\s*$/u.test(line) ||
      /^\s*\[\[rules\.allowlists\]\]\s*$/u.test(line) ||
      /^\s*\[rules\.allowlist\]\s*$/u.test(line)
    ) {
      finishCurrent();
      current = {
        line: index + 1,
        description: "",
        table: line.trim(),
        hasCommits: false,
        hasRegexes: false,
        hasPaths: false,
        hasStopwords: false,
        condition: null,
      };
      continue;
    }

    if (!current) {
      continue;
    }

    const descriptionMatch = line.match(/^\s*description\s*=\s*"([^"]*)"/u);
    if (descriptionMatch) {
      current.description = descriptionMatch[1];
    }
    if (/^\s*regexes\s*=\s*\[/u.test(line)) {
      current.hasRegexes = true;
    }
    if (/^\s*paths\s*=\s*\[/u.test(line)) {
      current.hasPaths = true;
    }
    if (/^\s*stopwords\s*=\s*\[/u.test(line)) {
      current.hasStopwords = true;
    }
    if (/^\s*commits\s*=\s*\[/u.test(line)) {
      current.hasCommits = true;
    }
    const conditionMatch = line.match(/^\s*condition\s*=\s*"([^"]*)"/u);
    if (conditionMatch) {
      current.condition = conditionMatch[1];
    }
  }
  finishCurrent();

  return sections.filter(
    (section) =>
      section.hasPaths &&
      (section.hasRegexes || section.hasStopwords || section.hasCommits) &&
      section.condition !== "AND",
  );
}

export function main(argv = process.argv) {
  const configPath = argv[2] ?? DEFAULT_CONFIG;
  const configText = readFileSync(configPath, "utf8");
  const violations = findAllowlistBoundaryViolations(configText);
  if (violations.length === 0) {
    console.log("OK: gitleaks path-bound allowlists require condition = \"AND\".");
    return 0;
  }

  console.error(
    "Gitleaks allowlists with paths plus regexes, stopwords, or commits must set condition = \"AND\".",
  );
  for (const violation of violations) {
    const label = violation.description
      ? ` (${violation.description})`
      : "";
    console.error(`  ${configPath}:${violation.line} ${violation.table}${label}`);
  }
  return 1;
}

if (process.argv[1] === fileURLToPath(import.meta.url)) {
  process.exit(main());
}
