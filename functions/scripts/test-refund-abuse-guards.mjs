#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFileSync } from "node:fs";
import { dirname, join } from "node:path";
import { fileURLToPath } from "node:url";

const root = dirname(dirname(fileURLToPath(import.meta.url)));
const read = (path) => readFileSync(join(root, path), "utf8");

const suspensionSource = read("src/cloudFeatureSuspensions.ts");
assert.match(suspensionSource, /users\/\{uid\}\/ops\/suspensions\/cloudFeatures/);
assert.match(suspensionSource, /CLOUD_FEATURE_ABUSE_DAILY_REFRESH_LIMIT = 5/);
for (const surface of ["hosted_quota", "remote_mcp", "floo_relay", "hosted_agent_control"]) {
  assert.match(suspensionSource, new RegExp(`"${surface}"`));
}

const sharedSource = read("src/callables/shared.ts");
assert.match(sharedSource, /assertCloudFeatureNotSuspended\(db, uid, "hosted_quota"\)/);
assert.match(sharedSource, /assertCloudFeatureNotSuspended\(db, uid, "burnbar_cloud"\)/);
assert.match(sharedSource, /assertCloudFeatureNotSuspended\(db, uid, "burnbar_cloud_pro"\)/);

const quotaSource = read("src/quota.ts");
assert.match(quotaSource, /assertCloudFeatureNotSuspended\(db, uid, "hosted_quota"\)/);
assert.match(quotaSource, /hostedQuotaDailyRefreshLimitForUser\(db, uid,/);

const allowanceSource = read("src/cloudProAllowance.ts");
assert.match(allowanceSource, /assertCloudFeatureNotSuspended\(db, uid, "hosted_agent_control"\)/);
assert.match(allowanceSource, /assertCloudFeatureNotSuspended\(db, uid, "floo_relay"\)/);

const remoteMcpSource = read("src/callables/remoteMcp.ts");
assert.match(remoteMcpSource, /assertCloudFeatureNotSuspended\(db, uid, "remote_mcp"\)/);
assert.match(read("src/remoteMcpGrant.ts"), /revokeAllRemoteMcpGrantsForUser/);

const hostedAnswerSource = read("src/insightsHostedAnswer.ts");
assert.match(hostedAnswerSource, /assertCloudFeatureNotSuspended\(db\(\), uid, "burnbar_cloud"\)/);

console.log("refund-abuse guards wired");
