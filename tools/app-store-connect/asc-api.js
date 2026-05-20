#!/usr/bin/env node
/**
 * App Store Connect API utility for OpenBurnBar release preparation.
 *
 * This is intentionally credential-source agnostic. Export the ASC key values
 * before running it, or pipe them from Secret Manager in the calling shell:
 *
 *   export APP_STORE_ASC_KEY_ID="$(firebase functions:secrets:access APP_STORE_ASC_KEY_ID --project burnbar)"
 *   export APP_STORE_ASC_ISSUER_ID="$(firebase functions:secrets:access APP_STORE_ASC_ISSUER_ID --project burnbar)"
 *   export APP_STORE_ASC_KEY_P8="$(firebase functions:secrets:access APP_STORE_ASC_KEY_P8 --project burnbar)"
 *   node tools/app-store-connect/asc-api.js prepare-ios
 */

const crypto = require("crypto");
const fs = require("fs");
const path = require("path");

const REPO_ROOT = path.resolve(__dirname, "../..");
const API_BASE = "https://api.appstoreconnect.apple.com/v1";
const STOREKIT_BASES = {
  Production: "https://api.storekit.apple.com",
  Sandbox: "https://api.storekit-sandbox.apple.com",
};
const LEGAL_URLS = {
  terms: "https://burnbar.ai/legal/terms",
  privacy: "https://burnbar.ai/legal/privacy-policy",
};
const PUBLIC_URLS = {
  support: "https://burnbar.ai/support",
  marketing: "https://burnbar.ai",
};

const APP = {
  appleId: process.env.APP_STORE_APPLE_APP_ID || "6766366964",
  bundleId: process.env.APP_STORE_BUNDLE_ID || "com.openburnbar.app",
  buildVersion: process.env.APP_STORE_BUILD_VERSION || currentMobileBuildVersion(),
  subscriptionId:
    process.env.OPENBURNBAR_HOSTED_QUOTA_SUBSCRIPTION_ID || "6768773163",
  subscriptionProductId:
    process.env.OPENBURNBAR_HOSTED_QUOTA_PRODUCT_ID ||
    "com.openburnbar.hostedQuotaSync.cloud.monthly",
  subscriptionGroupId:
    process.env.OPENBURNBAR_HOSTED_QUOTA_SUBSCRIPTION_GROUP_ID || "22067981",
  locale: process.env.APP_STORE_LOCALE || "en-US",
  screenshotDir:
    process.env.OPENBURNBAR_SCREENSHOT_DIR ||
    path.join(REPO_ROOT, ".appstore-screenshots"),
};

function currentMobileBuildVersion() {
  const projectPath = path.join(REPO_ROOT, "project.yml");
  try {
    const project = fs.readFileSync(projectPath, "utf8");
    const match = project.match(
      /OpenBurnBarMobile:[\s\S]*?CURRENT_PROJECT_VERSION:\s*"?([^"\n]+)"?/
    );
    return match?.[1]?.trim() || "1";
  } catch {
    return "1";
  }
}

const APP_REVIEW = {
  email:
    process.env.OPENBURNBAR_REVIEW_EMAIL ||
    process.env.APP_STORE_REVIEW_USERNAME ||
    "app-review@openburnbar.app",
  password:
    process.env.OPENBURNBAR_REVIEW_PASSWORD ||
    process.env.APP_STORE_REVIEW_PASSWORD ||
    "",
  contactFirstName: process.env.APP_STORE_REVIEW_CONTACT_FIRST_NAME || "Alberto",
  contactLastName: process.env.APP_STORE_REVIEW_CONTACT_LAST_NAME || "Nunez",
  contactEmail:
    process.env.APP_STORE_REVIEW_CONTACT_EMAIL || "support@openburnbar.app",
  contactPhone: process.env.APP_STORE_REVIEW_CONTACT_PHONE || "+13125550100",
  notes:
    process.env.APP_STORE_REVIEW_NOTES ||
    `OpenBurnBar is a companion app for the macOS app. The mobile app displays cloud-synced AI usage and quota data produced by the Mac app, and it can also configure supported quota providers directly on iPhone and iPad for on-demand quota refresh.

Use the supplied review account to see seeded companion-app data:
1. Open OpenBurnBar on iPhone or iPad.
2. Choose "Sign in with email".
3. Sign in with the supplied App Review username and password.
4. The Pulse, Burn, Quota, and You views show synced Mac usage, provider quota snapshots, connected devices, and provider accounts.
5. To find the In-App Purchase: You tab -> Settings -> OpenBurnBar Cloud -> Subscribe. The purchase screen shows Hosted Quota Sync Monthly, monthly price/period, restore, Privacy Policy, and Terms of Use (EULA) links.
6. Alternate IAP path: You tab -> Provider connections -> Codex -> Hosted Quota Sync -> Subscribe.
7. To verify account deletion: You tab -> Settings -> Account -> Delete account -> Delete account confirmation. This calls the server-side deleteUserCloudData function, deletes the Firebase Auth user, and returns to signed-out state.

Guideline 3.1.2(c) subscription disclosure fix:
The OpenBurnBar Cloud purchase screen now includes a dedicated "Subscription Details" section before purchase. It states the auto-renewing subscription title (OpenBurnBar Cloud Monthly), length (1 month, auto-renews monthly), price (StoreKit display price per month), services provided during each period (Hosted Codex quota refresh, Conversation Backup & Resume, Full Session-Log Sync, and Hermes Remote Relay), Apple billing/cancel instructions, and functional Privacy Policy and Terms of Use (EULA) links.

Guideline 2.1(a) camera crash fix:
Build ${APP.buildVersion} adds NSCameraUsageDescription to the iOS app Info.plist for the Take Photo attachment flow. The attachment menu also checks camera availability before presenting the camera sheet.

Guideline 2.1(b) subscription responsiveness fix:
Build ${APP.buildVersion} no longer blocks the Subscribe button on Firebase authentication or background StoreKit product metadata loading. If App Review opens the OpenBurnBar Cloud screen before signing in, tapping Subscribe still attempts Apple's StoreKit purchase flow immediately. Signed-in users continue to get server-side entitlement binding through appAccountToken, and signed-out purchases finish cleanly with an actionable sign-in/restore message instead of an Unauthenticated error.

Terms of Use: ${LEGAL_URLS.terms}
Privacy Policy: ${LEGAL_URLS.privacy}

Codex supports Hosted Quota Sync after subscription. Claude Code uses a self-hosted runner; OpenBurnBar does not collect hosted Claude Code OAuth/session tokens.`,
};

const IOS_METADATA = {
  description: `OpenBurnBar keeps your AI agent burn rate and quota pressure visible across Mac, iPhone, and iPad.

Track Claude Code, Codex, Cursor, Factory Droid, Kimi, and other coding agents from one calm dashboard. The Mac app reads local session logs and can sync selected usage and quota signals to your private cloud workspace so your mobile devices stay useful when you are away from the desk.

KEY FEATURES

AI SPEND AT A GLANCE
See today's estimated spend, token volume, request count, and provider mix without opening billing dashboards.

QUOTA VISIBILITY
Surface Claude Code, Codex, OpenAI, and other provider quota signals in one place. OpenBurnBar separates local Mac-sourced signals from hosted quota checks so you know exactly where each number came from.

REMOTE CODEX QUOTA REFRESH
The optional Hosted Quota Sync subscription lets the mobile app request on-demand Codex quota refreshes through OpenBurnBar's cloud runner. Refreshes happen when you ask for them, not on a random background schedule.

OPTIONAL SUBSCRIPTION
OpenBurnBar Cloud Monthly is an optional auto-renewable subscription. Length: 1 month, auto-renews monthly. Price: shown in the purchase screen before confirmation and billed monthly by Apple. Each subscription period includes Hosted Codex quota refresh, Conversation Backup & Resume, Full Session-Log Sync, and Hermes Remote Relay. You can manage or cancel the subscription in Settings -> Apple ID.

MAC, IPHONE, AND IPAD
Your Mac remains the local-first source for private CLI logs. iPhone and iPad provide a clean cockpit for burn, quota, connected devices, and provider status.

LOCAL-FIRST PRIVACY
OpenBurnBar does not collect analytics by default. Local session logs stay on your Mac unless you explicitly enable sync. API keys are not required for the core tracker.

SUPPORTED AGENTS
Claude Code, Codex, Cursor, Factory Droid, Kimi, Windsurf, Goose, Aider, Cline, RooCode, Kilo Code, OpenClaw, Forge, Augment, Copilot, Gemini CLI, Warp AI, and Hermes.

TERMS AND PRIVACY
Terms of Use: ${LEGAL_URLS.terms}
Privacy Policy: ${LEGAL_URLS.privacy}`,
  keywords:
    "AI,Claude,Codex,Cursor,quota,tokens,cost,budget,developer,LLM,agent,tracker",
  marketingUrl: PUBLIC_URLS.marketing,
  promotionalText:
    "Track AI agent spend and quota pressure across Mac, iPhone, and iPad.",
  supportUrl: PUBLIC_URLS.support,
  whatsNew:
    "Initial iPhone and iPad release with AI spend tracking, provider quota visibility, connected device sync, and optional Hosted Quota Sync for on-demand Codex quota refreshes.",
};

const SCREENSHOT_PLAN = [
  {
    displayType: "APP_IPHONE_67",
    files: ["iphone-promax-pulse.png", "iphone-promax-burn.png"],
  },
  {
    displayType: "APP_IPAD_PRO_3GEN_129",
    files: [
      "ipad-pro13-pulse.png",
      "ipad-pro13-burn.png",
      "ipad-pro13-providers.png",
    ],
  },
];

function requiredEnv(name, aliases = []) {
  const value = [name, ...aliases]
    .map((key) => process.env[key])
    .find((candidate) => candidate && candidate.trim().length > 0);
  if (!value) throw new Error(`${name} is not set`);
  return value.trim();
}

function base64url(input) {
  return Buffer.from(input)
    .toString("base64")
    .replace(/=/g, "")
    .replace(/\+/g, "-")
    .replace(/\//g, "_");
}

function makeToken() {
  const keyId = requiredEnv("APP_STORE_ASC_KEY_ID", ["ASC_KEY_ID"]);
  const issuerId = requiredEnv("APP_STORE_ASC_ISSUER_ID", ["ASC_ISSUER_ID"]);
  const privateKey = requiredEnv("APP_STORE_ASC_KEY_P8", [
    "ASC_PRIVATE_KEY",
    "ASC_KEY_P8",
  ]).replace(/\\n/g, "\n");

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: now - 10,
    exp: now + 20 * 60,
    aud: "appstoreconnect-v1",
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(
    JSON.stringify(payload)
  )}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

function makeStoreKitToken() {
  const keyId = requiredEnv("APP_STORE_ASC_KEY_ID", ["ASC_KEY_ID"]);
  const issuerId = requiredEnv("APP_STORE_ASC_ISSUER_ID", ["ASC_ISSUER_ID"]);
  const privateKey = requiredEnv("APP_STORE_ASC_KEY_P8", [
    "ASC_PRIVATE_KEY",
    "ASC_KEY_P8",
  ]).replace(/\\n/g, "\n");

  const now = Math.floor(Date.now() / 1000);
  const header = { alg: "ES256", kid: keyId, typ: "JWT" };
  const payload = {
    iss: issuerId,
    iat: now - 10,
    exp: now + 15 * 60,
    aud: "appstoreconnect-v1",
    bid: APP.bundleId,
  };
  const signingInput = `${base64url(JSON.stringify(header))}.${base64url(
    JSON.stringify(payload)
  )}`;
  const signature = crypto.sign("sha256", Buffer.from(signingInput), {
    key: privateKey,
    dsaEncoding: "ieee-p1363",
  });
  return `${signingInput}.${base64url(signature)}`;
}

function query(params) {
  const entries = Object.entries(params).filter(
    ([, value]) => value !== undefined && value !== null && value !== ""
  );
  if (entries.length === 0) return "";
  return `?${entries
    .map(([key, value]) => `${encodeURIComponent(key)}=${encodeURIComponent(value)}`)
    .join("&")}`;
}

async function api(method, resourcePath, body = undefined) {
  const response = await fetch(`${API_BASE}${resourcePath}`, {
    method,
    headers: {
      Authorization: `Bearer ${makeToken()}`,
      Accept: "application/json",
      ...(body ? { "Content-Type": "application/json" } : {}),
    },
    body: body ? JSON.stringify(body) : undefined,
  });
  const text = await response.text();
  if (!response.ok) {
    let detail = text;
    try {
      const parsed = JSON.parse(text);
      detail = JSON.stringify(parsed, null, 2);
    } catch {
      // keep raw response text
    }
    throw new Error(`${method} ${resourcePath} failed (${response.status}): ${detail}`);
  }
  if (!text) return null;
  return JSON.parse(text);
}

async function storeKitApi(environment, method, resourcePath) {
  const base = STOREKIT_BASES[environment];
  if (!base) throw new Error(`Unknown StoreKit environment: ${environment}`);

  const response = await fetch(`${base}${resourcePath}`, {
    method,
    headers: {
      Authorization: `Bearer ${makeStoreKitToken()}`,
      Accept: "application/json",
    },
  });
  const text = await response.text();
  let payload = null;
  if (text) {
    try {
      payload = JSON.parse(text);
    } catch {
      payload = text;
    }
  }
  return {
    ok: response.ok,
    status: response.status,
    payload,
  };
}

function data(type, attributes = {}, relationships = undefined, id = undefined) {
  return {
    data: {
      type,
      ...(id ? { id } : {}),
      ...(Object.keys(attributes).length ? { attributes } : {}),
      ...(relationships ? { relationships } : {}),
    },
  };
}

function rel(type, id) {
  return { data: { type, id } };
}

async function getLatestIosVersion() {
  const response = await api(
    "GET",
    `/apps/${APP.appleId}/appStoreVersions${query({
      "filter[platform]": "IOS",
      include: "appStoreVersionLocalizations",
      limit: 10,
    })}`
  );
  const versions = response.data || [];
  if (versions.length === 0) {
    throw new Error(`No iOS app store versions found for app ${APP.appleId}`);
  }
  const preferredStates = new Set([
    "PREPARE_FOR_SUBMISSION",
    "DEVELOPER_REJECTED",
    "REJECTED",
    "METADATA_REJECTED",
    "WAITING_FOR_REVIEW",
  ]);
  return (
    versions.find((version) => preferredStates.has(version.attributes?.appStoreState)) ||
    versions[0]
  );
}

async function getApp() {
  const response = await api("GET", `/apps/${APP.appleId}`);
  return response.data;
}

async function getAppStoreVersionWithBuild(versionId) {
  return api(
    "GET",
    `/appStoreVersions/${versionId}${query({
      include: "build",
    })}`
  );
}

async function getAppStoreVersion(versionId) {
  const response = await api("GET", `/appStoreVersions/${versionId}`);
  return response.data;
}

async function getBuild(buildId) {
  const response = await api("GET", `/builds/${buildId}`);
  return response.data;
}

async function getLinkedBuild(versionId) {
  const response = await getAppStoreVersionWithBuild(versionId);
  const buildRelationship = response.data?.relationships?.build?.data;
  if (!buildRelationship?.id) return null;
  return (
    (response.included || []).find(
      (item) => item.type === "builds" && item.id === buildRelationship.id
    ) || { id: buildRelationship.id, type: buildRelationship.type }
  );
}

async function getLatestValidBuild(versionString) {
  const response = await api(
    "GET",
    `/builds${query({
      "filter[app]": APP.appleId,
      include: "preReleaseVersion",
      sort: "-uploadedDate",
      limit: 25,
    })}`
  );
  const preReleaseVersionsById = new Map(
    (response.included || [])
      .filter((item) => item.type === "preReleaseVersions")
      .map((item) => [item.id, item])
  );

  const build = (response.data || []).find((candidate) => {
    const preReleaseVersionId =
      candidate.relationships?.preReleaseVersion?.data?.id;
    const preReleaseVersion = preReleaseVersionsById.get(preReleaseVersionId);
    return (
      candidate.attributes?.version === APP.buildVersion &&
      candidate.attributes?.processingState === "VALID" &&
      candidate.attributes?.buildAudienceType === "APP_STORE_ELIGIBLE" &&
      preReleaseVersion?.attributes?.version === versionString &&
      preReleaseVersion?.attributes?.platform === "IOS"
    );
  });

  if (!build) {
    throw new Error(
      `No valid App Store eligible iOS build ${versionString} (${APP.buildVersion}) found for app ${APP.appleId}`
    );
  }
  return build;
}

async function setLinkedBuildCompliance() {
  const version = await getLatestIosVersion();
  const linkedBuild = await getLinkedBuild(version.id);
  if (!linkedBuild?.id) {
    throw new Error(`No build is linked to iOS version ${version.id}`);
  }

  const existingBuild = await getBuild(linkedBuild.id);
  if (existingBuild.attributes?.usesNonExemptEncryption === false) {
    console.log(`Build ${linkedBuild.id} already has usesNonExemptEncryption=false`);
    return;
  }

  await api(
    "PATCH",
    `/builds/${linkedBuild.id}`,
    data(
      "builds",
      { usesNonExemptEncryption: false },
      undefined,
      linkedBuild.id
    )
  );
  const build = await getBuild(linkedBuild.id);
  console.log(
    `Set build ${linkedBuild.id} usesNonExemptEncryption=${build.attributes?.usesNonExemptEncryption}`
  );
}

async function attachBuildToVersion() {
  const version = await getLatestIosVersion();
  const build = await getLatestValidBuild(version.attributes?.versionString);
  await api(
    "PATCH",
    `/appStoreVersions/${version.id}`,
    data(
      "appStoreVersions",
      {},
      { build: rel("builds", build.id) },
      version.id
    )
  );
  console.log(
    `Attached build ${build.id} (${version.attributes?.versionString}/${build.attributes?.version}) to iOS version ${version.id}`
  );
  await printStatus();
}

async function getBetaGroups() {
  const response = await api(
    "GET",
    `/betaGroups${query({
      "filter[app]": APP.appleId,
      limit: 200,
    })}`
  );
  return response.data || [];
}

function betaGroupName(group) {
  return group.attributes?.name || group.id;
}

async function printBetaGroups() {
  const groups = await getBetaGroups();
  console.log(
    JSON.stringify(
      groups.map((group) => ({
        id: group.id,
        name: group.attributes?.name,
        isInternalGroup: group.attributes?.isInternalGroup,
        publicLinkEnabled: group.attributes?.publicLinkEnabled,
      })),
      null,
      2
    )
  );
}

async function attachBuildToInternalTestFlightGroups() {
  const version = await getLatestIosVersion();
  const build = await getLatestValidBuild(version.attributes?.versionString);
  const groups = await getBetaGroups();
  const internalGroups = groups.filter(
    (group) => group.attributes?.isInternalGroup === true
  );

  if (internalGroups.length === 0) {
    console.log(
      `No internal TestFlight beta groups found for app ${APP.appleId}; build ${build.id} remains uploaded and attached to iOS ${version.attributes?.versionString}.`
    );
    return;
  }

  try {
    await api(
      "POST",
      `/builds/${build.id}/relationships/betaGroups`,
      {
        data: internalGroups.map((group) => ({ type: "betaGroups", id: group.id })),
      }
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("409") && !message.includes("already")) {
      throw error;
    }
  }

  const groupNames = internalGroups.map(betaGroupName).join(", ");
  console.log(
    `Build ${build.id} (${version.attributes?.versionString}/${build.attributes?.version}) is assigned to internal TestFlight group(s): ${groupNames}`
  );
}

async function setManualRelease() {
  const version = await getLatestIosVersion();
  if (version.attributes?.releaseType === "MANUAL") {
    console.log(`iOS version ${version.id} already has releaseType=MANUAL`);
    return;
  }

  await api(
    "PATCH",
    `/appStoreVersions/${version.id}`,
    data("appStoreVersions", { releaseType: "MANUAL" }, undefined, version.id)
  );
  console.log(`Set iOS version ${version.id} releaseType=MANUAL`);
}

async function setContentRightsDeclaration() {
  const app = await getApp();
  if (app.attributes?.contentRightsDeclaration === "DOES_NOT_USE_THIRD_PARTY_CONTENT") {
    console.log(`App ${APP.appleId} already has contentRightsDeclaration=DOES_NOT_USE_THIRD_PARTY_CONTENT`);
    return;
  }

  await api(
    "PATCH",
    `/apps/${APP.appleId}`,
    data(
      "apps",
      { contentRightsDeclaration: "DOES_NOT_USE_THIRD_PARTY_CONTENT" },
      undefined,
      APP.appleId
    )
  );
  console.log(`Set app ${APP.appleId} contentRightsDeclaration=DOES_NOT_USE_THIRD_PARTY_CONTENT`);
}

async function setNoAdvertisingIdentifier() {
  const version = await getLatestIosVersion();
  const current = await getAppStoreVersion(version.id);
  if (current.attributes?.usesIdfa === false) {
    console.log(`iOS version ${version.id} already has usesIdfa=false`);
    return;
  }

  await api(
    "PATCH",
    `/appStoreVersions/${version.id}`,
    data("appStoreVersions", { usesIdfa: false }, undefined, version.id)
  );
  const updated = await getAppStoreVersion(version.id);
  console.log(`Set iOS version ${version.id} usesIdfa=${updated.attributes?.usesIdfa}`);
}

async function releaseApprovedIos() {
  const version = await getLatestIosVersion();
  const versionString = version.attributes?.versionString;
  const state = version.attributes?.appStoreState;
  const releaseType = version.attributes?.releaseType;

  if (state !== "PENDING_DEVELOPER_RELEASE") {
    throw new Error(
      `Refusing to release iOS ${versionString} (${version.id}); App Store state is ${state}, not PENDING_DEVELOPER_RELEASE.`
    );
  }
  if (releaseType !== "MANUAL") {
    throw new Error(
      `Refusing to release iOS ${versionString} (${version.id}); releaseType is ${releaseType}, not MANUAL.`
    );
  }

  const expectedConfirmation = `${versionString}:${version.id}`;
  const confirmation = process.env.OPENBURNBAR_RELEASE_APPROVED_IOS || "";
  if (confirmation !== expectedConfirmation) {
    throw new Error(
      "Refusing to release without explicit confirmation. " +
        `Set OPENBURNBAR_RELEASE_APPROVED_IOS="${expectedConfirmation}" and rerun only when you are ready to publish.`
    );
  }

  const response = await api(
    "POST",
    "/appStoreVersionReleaseRequests",
    {
      data: {
        type: "appStoreVersionReleaseRequests",
        relationships: {
          appStoreVersion: rel("appStoreVersions", version.id),
        },
      },
    }
  );

  console.log(
    JSON.stringify(
      {
        released: true,
        app: APP.appleId,
        bundleId: APP.bundleId,
        versionString,
        appStoreVersionId: version.id,
        releaseRequestId: response?.data?.id,
      },
      null,
      2
    )
  );
}

function isSubmissionAlreadyInProgress(error) {
  const message = error instanceof Error ? error.message : String(error);
  return (
    message.includes("ENTITY_ERROR.ATTRIBUTE.INVALID_STATE") ||
    message.includes("STATE_ERROR") ||
    message.includes("ENTITY_ERROR.RELATIONSHIP.NOT_UNIQUE") ||
    message.toLowerCase().includes("already")
  );
}

async function submitSubscriptionReview() {
  const subscription = await getSubscription();
  const state = subscription.data?.attributes?.state;
  const settledStates = new Set([
    "WAITING_FOR_REVIEW",
    "IN_REVIEW",
    "APPROVED",
    "READY_FOR_SALE",
  ]);
  if (settledStates.has(state)) {
    console.log(`Subscription ${APP.subscriptionId} is already in review/sale state: ${state}`);
    return;
  }
  if (
    state === "DEVELOPER_ACTION_NEEDED" &&
    process.env.OPENBURNBAR_FORCE_SUBSCRIPTION_SUBMISSION !== "1"
  ) {
    console.log(
      `Subscription ${APP.subscriptionId} remains DEVELOPER_ACTION_NEEDED; skipping duplicate API subscription submissions. Apple requires first auto-renewable subscriptions to be added to an app review submission in App Store Connect. Set OPENBURNBAR_FORCE_SUBSCRIPTION_SUBMISSION=1 to retry the raw subscriptionSubmissions endpoint.`
    );
    return;
  }

  try {
    const response = await api(
      "POST",
      "/subscriptionSubmissions",
      {
        data: {
          type: "subscriptionSubmissions",
          relationships: {
            subscription: rel("subscriptions", APP.subscriptionId),
          },
        },
      }
    );
    console.log(
      `Created subscription submission ${response?.data?.id} for ${APP.subscriptionId}`
    );
  } catch (error) {
    if (!isSubmissionAlreadyInProgress(error)) throw error;
    console.log(`Subscription ${APP.subscriptionId} already submitted or not in a directly submit-able state`);
  }
}

async function submitSubscriptionGroupReview({ force = false } = {}) {
  const subscription = await getSubscription();
  const groupId =
    subscription.data?.relationships?.group?.data?.id ||
    APP.subscriptionGroupId;
  if (!groupId) {
    console.log(`Subscription ${APP.subscriptionId} has no subscription group relationship; skipping group submission.`);
    return;
  }
  if (!force && process.env.OPENBURNBAR_FORCE_SUBSCRIPTION_GROUP_SUBMISSION !== "1") {
    console.log(
      `Skipping duplicate subscription group submission for ${groupId}. Set OPENBURNBAR_FORCE_SUBSCRIPTION_GROUP_SUBMISSION=1 to retry the raw subscriptionGroupSubmissions endpoint.`
    );
    return;
  }

  try {
    const response = await api(
      "POST",
      "/subscriptionGroupSubmissions",
      {
        data: {
          type: "subscriptionGroupSubmissions",
          relationships: {
            subscriptionGroup: rel("subscriptionGroups", groupId),
          },
        },
      }
    );
    console.log(
      `Created subscription group submission ${response?.data?.id} for group ${groupId}`
    );
  } catch (error) {
    if (!isSubmissionAlreadyInProgress(error)) throw error;
    console.log(`Subscription group ${groupId} already submitted or not in a directly submit-able state`);
  }
}

async function getReviewSubmissions() {
  const response = await api(
    "GET",
    `/apps/${APP.appleId}/reviewSubmissions${query({
      limit: 50,
      include: "items,appStoreVersionForReview",
    })}`
  );
  return response.data || [];
}

async function printReviewSubmissions() {
  const response = await api(
    "GET",
    `/apps/${APP.appleId}/reviewSubmissions${query({
      limit: 50,
      "limit[items]": 50,
      include: "items,appStoreVersionForReview",
    })}`
  );
  console.log(JSON.stringify(response, null, 2));
}

async function getOrCreateDraftReviewSubmission(versionId) {
  const submissions = await getReviewSubmissions();
  const activeSubmissions = submissions.filter(
    (submission) => submission.relationships?.appStoreVersionForReview?.data?.id
  );
  const detachedDrafts = submissions.filter(
    (submission) =>
      submission.attributes?.state === "READY_FOR_REVIEW" &&
      !submission.relationships?.appStoreVersionForReview?.data?.id
  );
  if (detachedDrafts.length > 0) {
    console.log(
      `Ignoring ${detachedDrafts.length} detached READY_FOR_REVIEW review submission draft(s); Apple does not allow deleting reviewSubmissions through the API.`
    );
  }

  const unresolved = activeSubmissions.find(
    (submission) =>
      submission.attributes?.state === "UNRESOLVED_ISSUES" &&
      submission.relationships?.appStoreVersionForReview?.data?.id === versionId
  );
  if (unresolved?.id) {
    console.log(`Using unresolved review submission ${unresolved.id} for updated review`);
    return unresolved;
  }

  const draft = activeSubmissions.find(
    (submission) =>
      submission.attributes?.state === "READY_FOR_REVIEW" &&
      (submission.attributes?.platform === "IOS" || !submission.attributes?.platform) &&
      submission.relationships?.appStoreVersionForReview?.data?.id === versionId
  );
  if (draft?.id) {
    console.log(`Using existing review submission ${draft.id}`);
    return draft;
  }

  const staleDrafts = activeSubmissions.filter(
    (submission) =>
      submission.attributes?.state === "READY_FOR_REVIEW" &&
      (submission.attributes?.platform === "IOS" || !submission.attributes?.platform)
  );
  if (staleDrafts.length > 0) {
    for (const staleDraft of staleDrafts) {
      await deleteReviewSubmission(staleDraft.id);
    }
  }

  const response = await api(
    "POST",
    "/reviewSubmissions",
    {
      data: {
        type: "reviewSubmissions",
        attributes: {
          platform: "IOS",
        },
        relationships: {
          app: rel("apps", APP.appleId),
        },
      },
    }
  );
  console.log(`Created review submission ${response?.data?.id}`);
  return response.data;
}

async function addAppVersionToReviewSubmission(submissionId, versionId) {
  try {
    const response = await api(
      "POST",
      "/reviewSubmissionItems",
      {
        data: {
          type: "reviewSubmissionItems",
          relationships: {
            reviewSubmission: rel("reviewSubmissions", submissionId),
            appStoreVersion: rel("appStoreVersions", versionId),
          },
        },
      }
    );
    console.log(`Added iOS version ${versionId} to review submission ${submissionId} as item ${response?.data?.id}`);
  } catch (error) {
    if (!isSubmissionAlreadyInProgress(error)) throw error;
    console.log(`iOS version ${versionId} is already attached to review submission ${submissionId}`);
  }
}

async function submitReviewSubmission(submissionId) {
  const response = await api(
    "PATCH",
    `/reviewSubmissions/${submissionId}`,
    {
      data: {
        type: "reviewSubmissions",
        id: submissionId,
        attributes: {
          submitted: true,
        },
      },
    }
  );
  console.log(
    `Submitted review submission ${submissionId}; state=${response?.data?.attributes?.state || "unknown"}`
  );
}

async function submitIosAppReview() {
  const version = await getLatestIosVersion();
  const state = version.attributes?.appStoreState;
  if (state !== "PREPARE_FOR_SUBMISSION" && state !== "READY_FOR_REVIEW") {
    console.log(
      `iOS version ${version.attributes?.versionString} is already past submit-ready state: ${state}`
    );
    return;
  }

  const linkedBuild = await getLinkedBuild(version.id);
  const linkedBuildReadback = linkedBuild?.id ? await getBuild(linkedBuild.id) : null;
  if (linkedBuildReadback?.attributes?.version !== APP.buildVersion) {
    throw new Error(
      `Refusing to submit iOS ${version.attributes?.versionString}; linked build is ${linkedBuildReadback?.attributes?.version || "none"}, expected ${APP.buildVersion}.`
    );
  }
  if (linkedBuildReadback.attributes?.processingState !== "VALID") {
    throw new Error(
      `Refusing to submit build ${APP.buildVersion}; processingState is ${linkedBuildReadback.attributes?.processingState}.`
    );
  }
  if (linkedBuildReadback.attributes?.buildAudienceType !== "APP_STORE_ELIGIBLE") {
    throw new Error(
      `Refusing to submit build ${APP.buildVersion}; buildAudienceType is ${linkedBuildReadback.attributes?.buildAudienceType}.`
    );
  }

  const submission = await getOrCreateDraftReviewSubmission(version.id);
  if (submission.attributes?.state !== "UNRESOLVED_ISSUES") {
    await addAppVersionToReviewSubmission(submission.id, version.id);
  }
  await submitReviewSubmission(submission.id);
}

async function submitReview() {
  const confirmation = process.env.OPENBURNBAR_SUBMIT_APP_REVIEW || "";
  if (confirmation !== `ios:${APP.buildVersion}`) {
    throw new Error(
      "Refusing to submit to App Review without explicit confirmation. " +
        `Set OPENBURNBAR_SUBMIT_APP_REVIEW=\"ios:${APP.buildVersion}\" when you are ready to submit this build.`
    );
  }

  await setContentRightsDeclaration();
  await prepareReviewMetadata();
  await submitSubscriptionGroupReview();
  await submitSubscriptionReview();
  await submitIosAppReview();
  await printStatus();
}

async function getVersionLocalization(versionId) {
  const response = await api(
    "GET",
    `/appStoreVersions/${versionId}/appStoreVersionLocalizations${query({
      limit: 50,
    })}`
  );
  const localizations = response.data || [];
  const localization =
    localizations.find((item) => item.attributes?.locale === APP.locale) ||
    localizations[0];
  if (!localization) {
    throw new Error(`No localization found for appStoreVersion ${versionId}`);
  }
  return localization;
}

async function getAppInfoLocalization() {
  const response = await api(
    "GET",
    `/apps/${APP.appleId}/appInfos${query({
      include: "appInfoLocalizations",
      limit: 10,
      "limit[appInfoLocalizations]": 10,
    })}`
  );
  const localizations = (response.included || []).filter(
    (item) => item.type === "appInfoLocalizations"
  );
  const localization =
    localizations.find((item) => item.attributes?.locale === APP.locale) ||
    localizations[0];
  if (!localization) {
    throw new Error(`No app info localization found for app ${APP.appleId}`);
  }
  return localization;
}

async function getReviewDetail(versionId) {
  try {
    const response = await api("GET", `/appStoreVersions/${versionId}/appStoreReviewDetail`);
    return response.data || null;
  } catch (error) {
    if (!String(error.message).includes("(404)")) throw error;
    return null;
  }
}

async function upsertReviewDetail() {
  const version = await getLatestIosVersion();
  const reviewDetail = await getReviewDetail(version.id);
  const reviewPassword = APP_REVIEW.password.trim();
  const hasPassword = reviewPassword.length > 0;
  const passwordFitsAppleLimit = reviewPassword.length <= 100;
  if (!hasPassword && !reviewDetail?.id) {
    throw new Error(
      "OPENBURNBAR_REVIEW_PASSWORD or APP_STORE_REVIEW_PASSWORD is required to create App Review login details"
    );
  }
  if (hasPassword && !passwordFitsAppleLimit && !reviewDetail?.id) {
    throw new Error(
      "App Review demo password must be 100 characters or fewer to create App Review login details"
    );
  }

  const attributes = {
    contactFirstName: APP_REVIEW.contactFirstName,
    contactLastName: APP_REVIEW.contactLastName,
    contactEmail: APP_REVIEW.contactEmail,
    contactPhone: APP_REVIEW.contactPhone,
    demoAccountRequired: true,
    demoAccountName: APP_REVIEW.email,
    notes: APP_REVIEW.notes,
  };
  if (hasPassword && passwordFitsAppleLimit) {
    attributes.demoAccountPassword = reviewPassword;
  }

  if (reviewDetail?.id) {
    await api(
      "PATCH",
      `/appStoreReviewDetails/${reviewDetail.id}`,
      data("appStoreReviewDetails", attributes, undefined, reviewDetail.id)
    );
    if (!hasPassword) {
      console.log("Retained existing App Review demo password");
    } else if (!passwordFitsAppleLimit) {
      console.log(
        "Retained existing App Review demo password because supplied secret exceeds Apple's 100-character limit"
      );
    }
    console.log(`Updated App Review details ${reviewDetail.id}`);
    return;
  }

  const response = await api(
    "POST",
    "/appStoreReviewDetails",
    data(
      "appStoreReviewDetails",
      attributes,
      { appStoreVersion: rel("appStoreVersions", version.id) }
    )
  );
  console.log(`Created App Review details ${response.data?.id}`);
}

async function getRequiredReviewDetail(versionId) {
  const reviewDetail = await getReviewDetail(versionId);
  if (!reviewDetail?.id) {
    throw new Error(
      `No App Review detail exists for iOS version ${versionId}; run fix-review-rejection first.`
    );
  }
  return reviewDetail;
}

async function uploadReviewAttachment() {
  const rawFilePath = process.argv[3];
  if (!rawFilePath) {
    throw new Error(
      "Missing attachment path. Usage: npm --prefix tools/app-store-connect run upload-review-attachment -- /path/to/account-deletion-recording.mov"
    );
  }

  const filePath = path.resolve(rawFilePath);
  if (!fs.existsSync(filePath)) {
    throw new Error(`Missing App Review attachment file: ${filePath}`);
  }

  const version = await getLatestIosVersion();
  const reviewDetail = await getRequiredReviewDetail(version.id);
  const response = await api(
    "POST",
    "/appStoreReviewAttachments",
    data(
      "appStoreReviewAttachments",
      {
        fileName: path.basename(filePath),
        fileSize: fileSize(filePath),
      },
      { appStoreReviewDetail: rel("appStoreReviewDetails", reviewDetail.id) }
    )
  );
  const attachment = response.data;
  await uploadOperations(filePath, attachment.attributes?.uploadOperations);
  await api(
    "PATCH",
    `/appStoreReviewAttachments/${attachment.id}`,
    data(
      "appStoreReviewAttachments",
      { uploaded: true, sourceFileChecksum: md5(filePath) },
      undefined,
      attachment.id
    )
  );

  console.log(
    JSON.stringify(
      {
        uploaded: true,
        appStoreVersionId: version.id,
        appReviewDetailId: reviewDetail.id,
        appReviewAttachmentId: attachment.id,
        fileName: path.basename(filePath),
      },
      null,
      2
    )
  );
}

async function updateAppInfoLocalization() {
  const localization = await getAppInfoLocalization();
  await api(
    "PATCH",
    `/appInfoLocalizations/${localization.id}`,
    data(
      "appInfoLocalizations",
      { privacyPolicyUrl: LEGAL_URLS.privacy },
      undefined,
      localization.id
    )
  );
  console.log(`Updated app info privacy policy URL ${localization.id}`);
}

async function updateIosMetadata(localizationId) {
  try {
    await api(
      "PATCH",
      `/appStoreVersionLocalizations/${localizationId}`,
      data("appStoreVersionLocalizations", IOS_METADATA, undefined, localizationId)
    );
  } catch (error) {
    if (!String(error.message).includes("whatsNew")) throw error;
    const { whatsNew, ...initialVersionMetadata } = IOS_METADATA;
    await api(
      "PATCH",
      `/appStoreVersionLocalizations/${localizationId}`,
      data(
        "appStoreVersionLocalizations",
        initialVersionMetadata,
        undefined,
        localizationId
      )
    );
    console.log("Skipped whatsNew because App Store Connect disallows it for this version state");
  }
  console.log(`Updated iOS metadata localization ${localizationId}`);
}

async function getScreenshotSets(localizationId) {
  const response = await api(
    "GET",
    `/appStoreVersionLocalizations/${localizationId}/appScreenshotSets${query({
      limit: 50,
    })}`
  );
  return response.data || [];
}

async function deleteScreenshotSet(setId) {
  const screenshotsResponse = await api(
    "GET",
    `/appScreenshotSets/${setId}/appScreenshots${query({ limit: 200 })}`
  );
  for (const screenshot of screenshotsResponse.data || []) {
    await api("DELETE", `/appScreenshots/${screenshot.id}`);
  }
  await api("DELETE", `/appScreenshotSets/${setId}`);
}

async function createScreenshotSet(localizationId, displayType) {
  const response = await api(
    "POST",
    "/appScreenshotSets",
    data(
      "appScreenshotSets",
      { screenshotDisplayType: displayType },
      {
        appStoreVersionLocalization: rel(
          "appStoreVersionLocalizations",
          localizationId
        ),
      }
    )
  );
  return response.data;
}

function fileSize(filePath) {
  return fs.statSync(filePath).size;
}

function md5(filePath) {
  return crypto.createHash("md5").update(fs.readFileSync(filePath)).digest("hex");
}

function screenshotPath(fileName) {
  const baseDir = path.resolve(APP.screenshotDir);
  const resolved = path.resolve(baseDir, fileName);
  const relative = path.relative(baseDir, resolved);
  if (relative.startsWith("..") || path.isAbsolute(relative)) {
    throw new Error(`Screenshot path escapes configured directory: ${fileName}`);
  }
  return resolved;
}

function verifiedUploadURL(rawURL) {
  const parsed = new URL(rawURL);
  if (parsed.protocol !== "https:") {
    throw new Error("App Store upload URL must use HTTPS.");
  }
  const hostname = parsed.hostname.toLowerCase();
  if (
    hostname !== "api.appstoreconnect.apple.com" &&
    !hostname.endsWith(".appstoreconnect.apple.com") &&
    hostname !== "iosapps-ssl.itunes.apple.com" &&
    !hostname.endsWith(".iosapps-ssl.itunes.apple.com") &&
    !hostname.endsWith(".object-storage.apple.com")
  ) {
    throw new Error(`Unexpected App Store upload host: ${parsed.hostname}`);
  }
  return parsed;
}

async function uploadOperations(filePath, operations) {
  const handle = fs.openSync(filePath, "r");
  try {
    for (const operation of operations || []) {
      const length = operation.length ?? fileSize(filePath);
      const offset = operation.offset ?? 0;
      const chunk = Buffer.alloc(length);
      fs.readSync(handle, chunk, 0, length, offset);
      const headers = {};
      for (const header of operation.requestHeaders || []) {
        headers[header.name] = header.value;
      }
      const uploadResponse = await fetch(verifiedUploadURL(operation.url), {
        method: operation.method || "PUT",
        headers,
        body: chunk,
      });
      if (!uploadResponse.ok) {
        const text = await uploadResponse.text();
        throw new Error(
          `Upload operation failed for ${path.basename(filePath)} (${uploadResponse.status}): ${text}`
        );
      }
    }
  } finally {
    fs.closeSync(handle);
  }
}

async function uploadAppScreenshot(setId, filePath) {
  const response = await api(
    "POST",
    "/appScreenshots",
    data(
      "appScreenshots",
      {
        fileName: path.basename(filePath),
        fileSize: fileSize(filePath),
      },
      { appScreenshotSet: rel("appScreenshotSets", setId) }
    )
  );
  const screenshot = response.data;
  await uploadOperations(filePath, screenshot.attributes?.uploadOperations);
  await api(
    "PATCH",
    `/appScreenshots/${screenshot.id}`,
    data(
      "appScreenshots",
      { uploaded: true, sourceFileChecksum: md5(filePath) },
      undefined,
      screenshot.id
    )
  );
  console.log(`Uploaded app screenshot ${path.basename(filePath)} -> ${screenshot.id}`);
}

async function replaceScreenshots(localizationId) {
  const existingSets = await getScreenshotSets(localizationId);
  for (const plan of SCREENSHOT_PLAN) {
    const plannedPaths = plan.files.map((file) => screenshotPath(file));
    for (const filePath of plannedPaths) {
      if (!fs.existsSync(filePath)) {
        throw new Error(`Missing screenshot file: ${filePath}`);
      }
    }

    for (const existing of existingSets.filter(
      (set) => set.attributes?.screenshotDisplayType === plan.displayType
    )) {
      await deleteScreenshotSet(existing.id);
      console.log(`Deleted prior ${plan.displayType} screenshot set ${existing.id}`);
    }

    const createdSet = await createScreenshotSet(localizationId, plan.displayType);
    console.log(`Created ${plan.displayType} screenshot set ${createdSet.id}`);
    for (const filePath of plannedPaths) {
      await uploadAppScreenshot(createdSet.id, filePath);
    }
  }
}

async function getSubscription() {
  try {
    return await api(
      "GET",
      `/subscriptions/${APP.subscriptionId}${query({
        include: "appStoreReviewScreenshot,subscriptionLocalizations,prices,group",
      })}`
    );
  } catch (error) {
    const message = error instanceof Error ? error.message : String(error);
    if (!message.includes("UNEXPECTED_ERROR")) throw error;
    console.log(
      "Apple returned an unexpected error when including the subscription group; retrying subscription status without that include."
    );
    return api(
      "GET",
      `/subscriptions/${APP.subscriptionId}${query({
        include: "appStoreReviewScreenshot,subscriptionLocalizations,prices",
      })}`
    );
  }
}

const SUBSCRIPTION_LOCALIZATION = {
  name: "Hosted Quota Sync Monthly",
  description: "Hosted Codex quota refresh for OpenBurnBar Cloud.",
};

async function getSubscriptionLocalizations() {
  const response = await api(
    "GET",
    `/subscriptions/${APP.subscriptionId}/subscriptionLocalizations${query({
      limit: 200,
    })}`
  );
  return response.data || [];
}

async function createSubscriptionLocalization(locale) {
  const response = await api(
    "POST",
    "/subscriptionLocalizations",
    data(
      "subscriptionLocalizations",
      {
        locale,
        name: SUBSCRIPTION_LOCALIZATION.name,
        description: SUBSCRIPTION_LOCALIZATION.description,
      },
      { subscription: rel("subscriptions", APP.subscriptionId) }
    )
  );
  console.log(
    `Created subscription localization ${response.data?.id} (${locale})`
  );
  return response.data;
}

async function deleteSubscriptionLocalization(localization) {
  await api("DELETE", `/subscriptionLocalizations/${localization.id}`);
  console.log(
    `Deleted subscription localization ${localization.id} (${localization.attributes?.locale})`
  );
}

async function repairSubscriptionLocalization() {
  const targetLocale = APP.locale;
  const temporaryLocale =
    process.env.OPENBURNBAR_TEMP_SUBSCRIPTION_LOCALE || "en-GB";
  if (temporaryLocale === targetLocale) {
    throw new Error("Temporary subscription locale must differ from APP.locale");
  }

  let localizations = await getSubscriptionLocalizations();
  const target = localizations.find(
    (item) => item.attributes?.locale === targetLocale
  );
  const targetNeedsReplacement =
    target?.attributes?.state === "REJECTED" ||
    target?.attributes?.name !== SUBSCRIPTION_LOCALIZATION.name ||
    target?.attributes?.description !== SUBSCRIPTION_LOCALIZATION.description;

  if (!targetNeedsReplacement) {
    console.log(
      `Subscription localization ${targetLocale} is already clean (${target?.id || "missing"})`
    );
    return;
  }

  let temporary = localizations.find(
    (item) => item.attributes?.locale === temporaryLocale
  );
  if (!temporary) {
    temporary = await createSubscriptionLocalization(temporaryLocale);
  }

  if (target) {
    await deleteSubscriptionLocalization(target);
  }

  localizations = await getSubscriptionLocalizations();
  const recreatedTarget = localizations.find(
    (item) => item.attributes?.locale === targetLocale
  );
  if (!recreatedTarget) {
    await createSubscriptionLocalization(targetLocale);
  }

  localizations = await getSubscriptionLocalizations();
  temporary = localizations.find(
    (item) => item.attributes?.locale === temporaryLocale
  );
  const currentTarget = localizations.find(
    (item) => item.attributes?.locale === targetLocale
  );
  if (temporary && currentTarget) {
    await deleteSubscriptionLocalization(temporary);
  }

  const finalLocalizations = await getSubscriptionLocalizations();
  console.log(
    JSON.stringify(
      {
        subscriptionId: APP.subscriptionId,
        localizations: finalLocalizations.map((item) => ({
          id: item.id,
          locale: item.attributes?.locale,
          name: item.attributes?.name,
          description: item.attributes?.description,
          state: item.attributes?.state,
        })),
      },
      null,
      2
    )
  );
}

async function cleanupTemporarySubscriptionLocalization() {
  const temporaryLocale =
    process.env.OPENBURNBAR_TEMP_SUBSCRIPTION_LOCALE || "en-GB";
  const localizations = await getSubscriptionLocalizations();
  const temporary = localizations.find(
    (item) => item.attributes?.locale === temporaryLocale
  );
  const target = localizations.find((item) => item.attributes?.locale === APP.locale);
  if (!temporary) {
    console.log(`No temporary subscription localization ${temporaryLocale} found`);
    return;
  }
  if (!target) {
    throw new Error(
      `Refusing to delete temporary localization ${temporaryLocale}; ${APP.locale} is missing`
    );
  }
  await deleteSubscriptionLocalization(temporary);
  const finalLocalizations = await getSubscriptionLocalizations();
  console.log(
    JSON.stringify(
      {
        subscriptionId: APP.subscriptionId,
        localizations: finalLocalizations.map((item) => ({
          id: item.id,
          locale: item.attributes?.locale,
          name: item.attributes?.name,
          description: item.attributes?.description,
          state: item.attributes?.state,
        })),
      },
      null,
      2
    )
  );
}

async function deleteSubscriptionReviewScreenshot(subscriptionResponse) {
  const included = subscriptionResponse.included || [];
  for (const item of included.filter(
    (entry) => entry.type === "subscriptionAppStoreReviewScreenshots"
  )) {
    await api("DELETE", `/subscriptionAppStoreReviewScreenshots/${item.id}`);
    console.log(`Deleted prior subscription review screenshot ${item.id}`);
  }
}

async function uploadSubscriptionReviewScreenshot() {
  const filePath = screenshotPath("ipad-pro13-providers.png");
  if (!fs.existsSync(filePath)) {
    throw new Error(`Missing subscription review screenshot file: ${filePath}`);
  }

  const subscription = await getSubscription();
  await deleteSubscriptionReviewScreenshot(subscription);
  const response = await api(
    "POST",
    "/subscriptionAppStoreReviewScreenshots",
    data(
      "subscriptionAppStoreReviewScreenshots",
      {
        fileName: path.basename(filePath),
        fileSize: fileSize(filePath),
      },
      { subscription: rel("subscriptions", APP.subscriptionId) }
    )
  );
  const screenshot = response.data;
  await uploadOperations(filePath, screenshot.attributes?.uploadOperations);
  await api(
    "PATCH",
    `/subscriptionAppStoreReviewScreenshots/${screenshot.id}`,
    data(
      "subscriptionAppStoreReviewScreenshots",
      { uploaded: true, sourceFileChecksum: md5(filePath) },
      undefined,
      screenshot.id
    )
  );
  console.log(`Uploaded subscription review screenshot ${screenshot.id}`);
}

async function printStatus() {
  const version = await getLatestIosVersion();
  const localization = await getVersionLocalization(version.id);
  const screenshots = await getScreenshotSets(localization.id);
  const subscription = await getSubscription();
  const linkedBuild = await getLinkedBuild(version.id);
  const linkedBuildReadback = linkedBuild?.id ? await getBuild(linkedBuild.id) : null;
  const reviewDetail = await getReviewDetail(version.id);
  const hasReviewNotes = Boolean(reviewDetail?.attributes?.notes);

  console.log(
    JSON.stringify(
      {
        app: APP.appleId,
        bundleId: APP.bundleId,
        iosVersion: {
          id: version.id,
          versionString: version.attributes?.versionString,
          state: version.attributes?.appStoreState,
          platform: version.attributes?.platform,
          releaseType: version.attributes?.releaseType,
          usesIdfa: version.attributes?.usesIdfa,
        },
        localization: {
          id: localization.id,
          locale: localization.attributes?.locale,
        },
        screenshotSets: screenshots.map((set) => ({
          id: set.id,
          displayType: set.attributes?.screenshotDisplayType,
        })),
        linkedBuild: linkedBuild
          ? {
              id: linkedBuild.id,
              version: linkedBuildReadback?.attributes?.version,
              processingState: linkedBuildReadback?.attributes?.processingState,
              buildAudienceType: linkedBuildReadback?.attributes?.buildAudienceType,
              uploadedDate: linkedBuildReadback?.attributes?.uploadedDate,
              usesNonExemptEncryption:
                linkedBuildReadback?.attributes?.usesNonExemptEncryption,
            }
          : null,
        appReviewDetail: reviewDetail
          ? {
              id: reviewDetail.id,
              demoAccountRequired: reviewDetail.attributes?.demoAccountRequired,
              demoAccountName: reviewDetail.attributes?.demoAccountName,
              hasNotes: hasReviewNotes,
            }
          : null,
        subscription: {
          id: subscription.data?.id,
          productId: subscription.data?.attributes?.productId,
          name: subscription.data?.attributes?.name,
          state: subscription.data?.attributes?.state,
          groupId: subscription.data?.relationships?.group?.data?.id,
          hasReviewScreenshot: (subscription.included || []).some(
            (entry) => entry.type === "subscriptionAppStoreReviewScreenshots"
          ),
        },
      },
      null,
      2
    )
  );
}

function notificationEnvironmentFromArg(arg) {
  const value = (arg || "sandbox").toLowerCase();
  if (value === "production" || value === "prod") return ["Production"];
  if (value === "sandbox") return ["Sandbox"];
  if (value === "both" || value === "all") return ["Sandbox", "Production"];
  throw new Error(
    `Unknown notification test environment "${arg}". Use sandbox, production, or both.`
  );
}

function summarizeNotificationStatus(payload) {
  const attempts = Array.isArray(payload?.sendAttempts)
    ? payload.sendAttempts
    : [];
  const sanitizedAttempts = attempts.map((attempt) => ({
    attemptDate: attempt.attemptDate,
    sendAttemptResult: attempt.sendAttemptResult,
  }));
  return {
    firstSendAttemptResult: payload?.firstSendAttemptResult || null,
    sendAttempts: sanitizedAttempts,
    delivered: sanitizedAttempts.some(
      (attempt) => attempt.sendAttemptResult === "SUCCESS"
    ),
  };
}

async function requestServerNotificationTest(environment) {
  const request = await storeKitApi(
    environment,
    "POST",
    "/inApps/v1/notifications/test"
  );
  const result = {
    environment,
    requestStatus: request.status,
    requestOk: request.ok,
    hasToken: false,
    delivered: false,
  };
  if (!request.ok) {
    return {
      ...result,
      error: request.payload || "empty response body",
    };
  }

  const testNotificationToken = request.payload?.testNotificationToken;
  result.hasToken =
    typeof testNotificationToken === "string" &&
    testNotificationToken.length > 0;
  if (!result.hasToken) {
    return {
      ...result,
      error: "Apple accepted the request but did not return testNotificationToken",
    };
  }

  for (let attempt = 1; attempt <= 10; attempt += 1) {
    await new Promise((resolve) =>
      setTimeout(resolve, attempt === 1 ? 1500 : 3000)
    );
    const status = await storeKitApi(
      environment,
      "GET",
      `/inApps/v1/notifications/test/${encodeURIComponent(testNotificationToken)}`
    );
    result.statusStatus = status.status;
    result.statusOk = status.ok;
    if (!status.ok) {
      result.error = status.payload || "empty response body";
      continue;
    }
    const summary = summarizeNotificationStatus(status.payload);
    result.firstSendAttemptResult = summary.firstSendAttemptResult;
    result.sendAttempts = summary.sendAttempts;
    result.delivered = summary.delivered;
    delete result.error;
    if (result.delivered) break;
  }

  return result;
}

async function testServerNotifications() {
  const environments = notificationEnvironmentFromArg(process.argv[3]);
  const results = [];
  for (const environment of environments) {
    results.push(await requestServerNotificationTest(environment));
  }
  const ok = results.every((result) => result.delivered);
  console.log(
    JSON.stringify(
      {
        generatedAt: new Date().toISOString(),
        app: APP.appleId,
        bundleId: APP.bundleId,
        ok,
        results,
      },
      null,
      2
    )
  );
  if (!ok) process.exitCode = 1;
}

async function prepareIos() {
  const version = await getLatestIosVersion();
  const localization = await getVersionLocalization(version.id);
  console.log(
    `Preparing iOS version ${version.attributes?.versionString} (${version.id}), localization ${localization.id}`
  );
  await updateAppInfoLocalization();
  await updateIosMetadata(localization.id);
  await replaceScreenshots(localization.id);
  await uploadSubscriptionReviewScreenshot();
  await printStatus();
}

async function prepareReviewMetadata() {
  const version = await getLatestIosVersion();
  const localization = await getVersionLocalization(version.id);
  await updateAppInfoLocalization();
  await updateIosMetadata(localization.id);
  await setLinkedBuildCompliance();
  await setNoAdvertisingIdentifier();
  await setManualRelease();
  await upsertReviewDetail();
  await printStatus();
}

async function main() {
  const command = process.argv[2] || "status";
  if (command === "status") return printStatus();
  if (command === "prepare-ios") return prepareIos();
  if (command === "attach-build") return attachBuildToVersion();
  if (command === "attach-internal-testflight") return attachBuildToInternalTestFlightGroups();
  if (command === "beta-groups") return printBetaGroups();
  if (command === "set-build-compliance") return setLinkedBuildCompliance();
  if (command === "set-no-advertising-identifier") return setNoAdvertisingIdentifier();
  if (command === "set-manual-release") return setManualRelease();
  if (command === "release-approved-ios") return releaseApprovedIos();
  if (command === "submit-subscription-review") return submitSubscriptionReview();
  if (command === "submit-subscription-group-review") return submitSubscriptionGroupReview({ force: true });
  if (command === "submit-review") return submitReview();
  if (command === "review-submissions") return printReviewSubmissions();
  if (command === "repair-subscription-localization") return repairSubscriptionLocalization();
  if (command === "cleanup-temp-subscription-localization") return cleanupTemporarySubscriptionLocalization();
  if (command === "upload-subscription-review-screenshot") return uploadSubscriptionReviewScreenshot();
  if (command === "test-server-notifications") return testServerNotifications();
  if (command === "review-details") return upsertReviewDetail();
  if (command === "upload-review-attachment") return uploadReviewAttachment();
  if (command === "prepare-review-metadata") return prepareReviewMetadata();
  if (command === "fix-review-rejection") return prepareReviewMetadata();
  throw new Error(`Unknown command: ${command}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
