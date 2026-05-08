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

const API_BASE = "https://api.appstoreconnect.apple.com/v1";

const APP = {
  appleId: process.env.APP_STORE_APPLE_APP_ID || "6766366964",
  bundleId: process.env.APP_STORE_BUNDLE_ID || "com.openburnbar.app",
  buildVersion: process.env.APP_STORE_BUILD_VERSION || "1",
  subscriptionId:
    process.env.OPENBURNBAR_HOSTED_QUOTA_SUBSCRIPTION_ID || "6766395166",
  locale: process.env.APP_STORE_LOCALE || "en-US",
  screenshotDir:
    process.env.OPENBURNBAR_SCREENSHOT_DIR ||
    "/tmp/openburnbar-appstore-screenshots",
};

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
5. In quota/provider setup, Codex supports Hosted Quota Sync after subscription. Claude Code uses a self-hosted runner; OpenBurnBar does not collect hosted Claude Code OAuth/session tokens.`,
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

MAC, IPHONE, AND IPAD
Your Mac remains the local-first source for private CLI logs. iPhone and iPad provide a clean cockpit for burn, quota, connected devices, and provider status.

LOCAL-FIRST PRIVACY
OpenBurnBar does not collect analytics by default. Local session logs stay on your Mac unless you explicitly enable sync. API keys are not required for the core tracker.

SUPPORTED AGENTS
Claude Code, Codex, Cursor, Factory Droid, Kimi, Windsurf, Goose, Aider, Cline, RooCode, Kilo Code, OpenClaw, Forge, Augment, Copilot, Gemini CLI, Warp AI, and Hermes.`,
  keywords:
    "AI,Claude,Codex,Cursor,quota,tokens,cost,budget,developer,LLM,agent,tracker",
  marketingUrl: "https://github.com/Ajnunezg/OpenBurnBar",
  promotionalText:
    "Track AI agent spend and quota pressure across Mac, iPhone, and iPad.",
  supportUrl: "https://github.com/Ajnunezg/OpenBurnBar/issues",
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

async function getAppStoreVersionWithBuild(versionId) {
  return api(
    "GET",
    `/appStoreVersions/${versionId}${query({
      include: "build",
    })}`
  );
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
  await api(
    "PATCH",
    `/appStoreVersions/${version.id}`,
    data("appStoreVersions", { releaseType: "MANUAL" }, undefined, version.id)
  );
  console.log(`Set iOS version ${version.id} releaseType=MANUAL`);
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
  if (!APP_REVIEW.password.trim()) {
    throw new Error(
      "OPENBURNBAR_REVIEW_PASSWORD or APP_STORE_REVIEW_PASSWORD is required to update App Review login details"
    );
  }

  const attributes = {
    contactFirstName: APP_REVIEW.contactFirstName,
    contactLastName: APP_REVIEW.contactLastName,
    contactEmail: APP_REVIEW.contactEmail,
    contactPhone: APP_REVIEW.contactPhone,
    demoAccountRequired: true,
    demoAccountName: APP_REVIEW.email,
    demoAccountPassword: APP_REVIEW.password,
    notes: APP_REVIEW.notes,
  };

  if (reviewDetail?.id) {
    await api(
      "PATCH",
      `/appStoreReviewDetails/${reviewDetail.id}`,
      data("appStoreReviewDetails", attributes, undefined, reviewDetail.id)
    );
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
      const uploadResponse = await fetch(operation.url, {
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
    const plannedPaths = plan.files.map((file) => path.join(APP.screenshotDir, file));
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
  const response = await api(
    "GET",
    `/subscriptions/${APP.subscriptionId}${query({
      include: "appStoreReviewScreenshot,subscriptionLocalizations,prices",
    })}`
  );
  return response;
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
  const filePath = path.join(APP.screenshotDir, "ipad-pro13-providers.png");
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
              hasDemoAccountPassword: Boolean(
                reviewDetail.attributes?.demoAccountPassword
              ),
              hasNotes: Boolean(reviewDetail.attributes?.notes),
            }
          : null,
        subscription: {
          id: subscription.data?.id,
          productId: subscription.data?.attributes?.productId,
          name: subscription.data?.attributes?.name,
          state: subscription.data?.attributes?.state,
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

async function prepareIos() {
  const version = await getLatestIosVersion();
  const localization = await getVersionLocalization(version.id);
  console.log(
    `Preparing iOS version ${version.attributes?.versionString} (${version.id}), localization ${localization.id}`
  );
  await updateIosMetadata(localization.id);
  await replaceScreenshots(localization.id);
  await uploadSubscriptionReviewScreenshot();
  await printStatus();
}

async function prepareReviewMetadata() {
  await setLinkedBuildCompliance();
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
  if (command === "set-manual-release") return setManualRelease();
  if (command === "review-details") return upsertReviewDetail();
  if (command === "prepare-review-metadata") return prepareReviewMetadata();
  throw new Error(`Unknown command: ${command}`);
}

main().catch((error) => {
  console.error(error.message);
  process.exitCode = 1;
});
