#!/usr/bin/env node
/**
 * Static confidentiality gate for the scheduled Factory security review.
 *
 * The workflow may generate raw security findings, but those findings must not
 * be printed to CI logs, passed through long-lived shell argv, uploaded as
 * artifacts, or routed to Slack as a substitute for a private advisory.
 */

import { existsSync, readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const ROOT =
  process.env.FACTORY_SECURITY_REVIEW_BOUNDARY_ROOT ??
  join(dirname(fileURLToPath(import.meta.url)), "..", "..");
const WORKFLOW = join(ROOT, ".github/workflows/factory-security-review.yml");

const failures = [];
const fail = (message) => failures.push(message);

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
    if (
      char === "#" &&
      !singleQuoted &&
      !doubleQuoted &&
      (index === 0 || /\s/u.test(previous))
    ) {
      return line.slice(0, index).trimEnd();
    }
  }
  return line;
}

const stripComments = (source) =>
  source
    .split("\n")
    .map((line) => stripYamlLineComment(line))
    .join("\n");

if (!existsSync(WORKFLOW)) {
  console.error(`MISCONFIGURED: workflow not found: ${WORKFLOW}`);
  process.exit(2);
}

const rawSource = readFileSync(WORKFLOW, "utf8");
const source = stripComments(rawSource);

if (/\bset\s+-x\b/u.test(source)) {
  fail("workflow must not enable shell xtrace around security reports");
}

if (!/review_output="\$\{RUNNER_TEMP\}\/factory-security-review-output\.log"/u.test(source)) {
  fail("Droid mission output must be captured to a runner-temp file");
}

if (!/if ! droid exec --mission --auto high/u.test(source)) {
  fail("Droid mission must run behind an explicit fail-closed wrapper");
}

if (!/>"\$\{review_output\}" 2>&1/u.test(source)) {
  fail("Droid mission stdout/stderr must not stream to CI logs");
}

if (/droid exec --mission[\s\S]*?\/security-review[\s\S]*?(?<!>)\n/u.test(source)) {
  const missionBlock = source.match(/if ! droid exec --mission[\s\S]*?\/security-review[\s\S]*?2>&1/u)?.[0] ?? "";
  if (!missionBlock.includes('>"${review_output}" 2>&1')) {
    fail("Droid mission command appears without the required output redirection");
  }
}

if (/actions\/upload-artifact@/u.test(source) && /security-audits|report_tmp|factory-security-review-output/u.test(source)) {
  fail("raw security review outputs must not be uploaded as artifacts");
}

if (/\b(?:cat|tail|head)\s+"\$\{report_tmp\}"/u.test(source)) {
  fail("combined security report must not be printed to CI logs");
}

if (/\becho\s+.*\$\{?(?:body|report_tmp|description_tmp)\}?/u.test(source)) {
  fail("security report buffers must not be echoed to CI logs");
}

if (/-f\s+description=|-F\s+description=|body="\$\(head -c/u.test(source)) {
  fail("private advisory body must not be passed through shell argv");
}

if (!/--rawfile description "\$\{description_tmp\}"/u.test(source)) {
  fail("private advisory body must be loaded by jq from a temp file");
}

if (!/--input "\$\{payload_tmp\}"/u.test(source)) {
  fail("GitHub advisory API call must read the JSON payload from a file");
}

if (!/confidential: true/u.test(source)) {
  fail("advisory payload must mark reports confidential");
}

if (/review full report in CI logs|full report in CI logs/iu.test(source)) {
  fail("workflow must never direct humans to raw findings in CI logs");
}

if (
  source.includes(
    'advisory_created}" == "false" && "${slack_sent',
  )
) {
  fail("Slack notification must not substitute for private advisory routing");
}

if (!/Slack is\s+#?\s*only an alert|Slack is[\s\S]*never a substitute/u.test(rawSource)) {
  fail("workflow must document Slack as alert-only routing");
}

if (!/Critical findings detected but private advisory routing failed/u.test(source)) {
  fail("critical findings must fail closed when private advisory routing fails");
}

if (failures.length > 0) {
  console.error("Factory security review boundary verification failed:");
  for (const failure of failures) console.error(`  - ${failure}`);
  process.exit(1);
}

console.log("PASS: Factory security review keeps raw findings out of CI logs and shell argv.");
