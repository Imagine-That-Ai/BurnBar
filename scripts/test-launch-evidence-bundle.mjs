#!/usr/bin/env node
/**
 * Regression tests for the GTM final evidence bundle validator.
 */

import assert from "node:assert/strict";
import { mkdtempSync, writeFileSync } from "node:fs";
import { join } from "node:path";
import { tmpdir } from "node:os";
import {
  templateLaunchEvidenceBundle,
  validateLaunchEvidenceBundle,
} from "./validate-launch-evidence-bundle.mjs";

function writeJSON(dir, name, value) {
  writeFileSync(join(dir, name), JSON.stringify(value, null, 2));
}

function evidence(kind, path = `${kind}.png`) {
  return { kind, path };
}

function fixture(dir) {
  const manifest = templateLaunchEvidenceBundle();
  manifest.generatedAt = new Date().toISOString();
  manifest.release.ios.appVersionID = "ios-version-id";
  manifest.release.ios.buildNumber = "42";
  manifest.release.stripe.cloudPriceID = "price_cloud_live";
  manifest.release.stripe.cloudProPriceID = "price_cloud_pro_live";
  manifest.release.website.deployID = "hosting-release-id";

  writeJSON(dir, "latest-commercial-launch-gate.json", {
    verdict: { status: "LAUNCH_DONE" },
    checks: { repo: { ok: true } },
  });

  for (const proof of manifest.paidProofs) {
    writeJSON(dir, proof.path, { ok: true, channel: proof.channel, tier: proof.tier });
  }

  writeJSON(dir, "cross-channel-paid-path-matrix.json", {
    schemaVersion: 1,
    security: { clientSelfGrantDenied: true },
    rows: [
      "stripe_cloud_monthly",
      "stripe_cloud_pro_annual",
      "apple_cloud_restore_cancel_refund",
      "apple_cloud_pro_topup",
      "google_play_cloud_restore_cancel_refund",
      "google_play_cloud_pro_topup",
      "legacy_hosted_quota_group_a_only",
      "expired_canceled_fail_closed",
    ].map((id) => ({ id, ok: true, evidence: [evidence("proof", `${id}.json`)] })),
  });

  writeJSON(dir, "canary-report.json", {
    ok: true,
    hoursObserved: 72,
    noOpenP0P1: true,
    cloudGrossMarginPercent: 82,
    cloudProGrossMarginPercent: 55,
    appCheckDeniedPercent: 0.2,
    entitlementFailurePercent: 0.1,
    mediaProjectedSpendUSD: 500,
    computerUseProjectedSpendUSD: 1200,
    remoteConfig: {
      public_paid_launch: "false",
      paid_canary_percent: "10",
      cloud_pro_enabled: "true",
      cloud_pro_monthly_hosted_action_cap: "2000",
    },
    evidence: [evidence("dashboard"), evidence("cogs-report"), evidence("incident-log")],
  });

  writeJSON(dir, "public-launch-report.json", {
    ok: true,
    remoteConfig: {
      public_paid_launch: "true",
      paid_canary_percent: "100",
      cloud_pro_enabled: "true",
    },
    githubRelease: { draft: false, url: "https://github.com/Imagine-That-Ai/BurnBar/releases/tag/v1.0.0" },
    website: { deployID: "hosting-release-id", pricingHTTPStatus: 200, legalHTTPStatus: 200 },
    launchChannelsPosted: ["github_release", "hacker_news", "reddit", "indie_hackers", "product_hunt", "email"],
    topUpPrepayEnforced: true,
    entitlementGatesVerified: true,
    monitoringDashboardsLive: true,
  });

  writeJSON(dir, "refund-abuse-report.json", {
    ok: true,
    refundCasesCovered: [
      "stripe_subscription_deleted",
      "stripe_chargeback",
      "apple_refund_revocation",
      "apple_expiration",
      "google_play_refund_revocation",
      "google_play_expiration",
    ],
    entitlementRemovedWithinReconciliationWindow: true,
    revocationAuditEventPresent: true,
    topUpConsumedNonRefundableDocumented: true,
    abuseOverridePath: "users/{uid}/ops/suspensions/cloudFeatures",
    userQuotaDailyRefreshLimit: "5",
    remoteMcpGrantsRevoked: true,
    suspendedUserDeniedSurfaces: ["hosted_quota", "remote_mcp", "floo_relay", "hosted_agent_control"],
    evidence: [evidence("runbook", "refund-abuse.md")],
  });

  writeJSON(dir, "rollback-drill.json", {
    ok: true,
    controlsCovered: [
      "remote_config_kill_switch_patch",
      "hosting_release_list",
      "functions_build",
      "cloud_run_revision_list",
      "commercial_launch_gate",
      "ops_readiness",
      "stripe_console_access",
      "apple_console_access",
      "google_play_console_access",
    ],
    remoteConfigPublished: false,
    killSwitchHaltVerified: true,
    onCallCanExecute: true,
  });

  const doneRefs = [
    manifest.launchGate.path,
    manifest.crossChannelMatrix.path,
    manifest.canary.path,
    manifest.rollbackDrill.path,
    manifest.refundAbuseReport.path,
    manifest.release.publicLaunchReport.path,
    ...manifest.paidProofs.map((proof) => proof.path),
    "final-launch-evidence.json",
  ];
  writeFileSync(join(dir, "LAUNCH_DONE.md"), doneRefs.join("\n"));
  writeJSON(dir, "final-launch-evidence.json", manifest);
  return manifest;
}

{
  const dir = mkdtempSync(join(tmpdir(), "openburnbar-launch-evidence-"));
  const manifest = fixture(dir);
  const manifestPath = join(dir, "final-launch-evidence.json");
  assert.equal(validateLaunchEvidenceBundle(manifest, { manifestPath, stage: "paid-proof" }).ok, true);
  assert.equal(validateLaunchEvidenceBundle(manifest, { manifestPath, stage: "public-release" }).ok, true);
  assert.equal(
    validateLaunchEvidenceBundle(manifest, {
      manifestPath,
      stage: "done",
      requireDoneStamp: true,
      donePath: join(dir, "LAUNCH_DONE.md"),
    }).ok,
    true,
  );
}

{
  const dir = mkdtempSync(join(tmpdir(), "openburnbar-launch-evidence-bad-"));
  const manifest = fixture(dir);
  const matrix = JSON.parse(JSON.stringify(manifest));
  writeJSON(dir, "cross-channel-paid-path-matrix.json", {
    schemaVersion: 1,
    security: { clientSelfGrantDenied: true },
    rows: [],
  });
  const result = validateLaunchEvidenceBundle(matrix, {
    manifestPath: join(dir, "final-launch-evidence.json"),
    stage: "paid-proof",
  });
  assert.equal(result.ok, false);
  assert.match(result.errors.join("\n"), /missing row: stripe_cloud_monthly/);
}

console.log("launch-evidence-bundle validator tests passed");
