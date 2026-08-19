const API_ORIGIN = "https://firebasehosting.googleapis.com";
const API_PREFIX = "/v1beta1";
const UPLOAD_ORIGIN = "https://upload-firebasehosting.googleapis.com";
const SITE = "(?:burnbar|burnbar-console)";
const VERSION = "[A-Za-z0-9_-]{1,128}";
const SHA256 = /^[0-9a-f]{64}$/u;

const CREATE_VERSION = new RegExp(
  `^${API_PREFIX}/projects/-/sites/(${SITE})/versions$`,
  "u",
);
const POPULATE_FILES = new RegExp(
  `^${API_PREFIX}/sites/(${SITE})/versions/(${VERSION}):populateFiles$`,
  "u",
);
const FINALIZE_VERSION = new RegExp(
  `^${API_PREFIX}/projects/-/sites/(${SITE})/versions/(${VERSION})$`,
  "u",
);
const CREATE_RELEASE = new RegExp(
  `^${API_PREFIX}/projects/-/sites/(${SITE})/channels/live/releases$`,
  "u",
);
const UPLOAD_FILES = new RegExp(
  `^/upload/sites/(${SITE})/versions/(${VERSION})/files/?$`,
  "u",
);

function allowedSite(site) {
  return site === "burnbar" || site === "burnbar-console";
}

function exactOrigin(url, expected) {
  return (
    url.protocol === "https:" &&
    url.origin === expected &&
    url.username === "" &&
    url.password === "" &&
    url.port === "" &&
    url.hash === ""
  );
}

function noSearch(url) {
  return url.search === "";
}

function exactQuery(url, key) {
  const entries = [...url.searchParams.entries()];
  return entries.length === 1 && entries[0][0] === key
    ? entries[0][1]
    : undefined;
}

export function firebaseHostingApiUrl(method, path) {
  if (
    typeof path !== "string" ||
    !path.startsWith("/") ||
    path.startsWith("//") ||
    path.includes("\\")
  ) {
    throw new Error(
      "Firebase Hosting API path must be an absolute resource path",
    );
  }
  const url = new URL(`${API_PREFIX}${path}`, API_ORIGIN);
  if (!exactOrigin(url, API_ORIGIN)) {
    throw new Error(
      "Firebase Hosting API URL must use the exact allowlisted origin",
    );
  }

  const create = url.pathname.match(CREATE_VERSION);
  if (method === "POST" && create && noSearch(url)) return url;

  const populate = url.pathname.match(POPULATE_FILES);
  if (method === "POST" && populate && noSearch(url)) return url;

  const finalize = url.pathname.match(FINALIZE_VERSION);
  if (
    method === "PATCH" &&
    finalize &&
    exactQuery(url, "updateMask") === "status,config"
  )
    return url;

  const release = url.pathname.match(CREATE_RELEASE);
  const versionName = exactQuery(url, "versionName");
  if (
    method === "POST" &&
    release &&
    versionName ===
      `sites/${release[1]}/versions/${versionName?.split("/").at(-1)}` &&
    new RegExp(`^sites/${release[1]}/versions/${VERSION}$`, "u").test(
      versionName,
    )
  ) {
    return url;
  }

  throw new Error(
    `Refusing unsupported Firebase Hosting API endpoint: ${method} ${url.pathname}`,
  );
}

export function firebaseHostingUploadUrl(uploadUrl, expectedSite, hash) {
  if (!allowedSite(expectedSite) || !SHA256.test(hash)) {
    throw new Error("Firebase Hosting upload site or hash is invalid");
  }
  let base;
  try {
    base = new URL(uploadUrl);
  } catch {
    throw new Error("Firebase Hosting upload URL is invalid");
  }
  const match = base.pathname.match(UPLOAD_FILES);
  if (
    !exactOrigin(base, UPLOAD_ORIGIN) ||
    !noSearch(base) ||
    !match ||
    match[1] !== expectedSite
  ) {
    throw new Error(
      "Firebase Hosting upload URL must use the exact allowlisted origin and path",
    );
  }
  const url = new URL(
    `${base.pathname.replace(/\/$/u, "")}/${hash}`,
    UPLOAD_ORIGIN,
  );
  if (!exactOrigin(url, UPLOAD_ORIGIN) || !noSearch(url)) {
    throw new Error(
      "Firebase Hosting upload URL escaped the allowlisted origin",
    );
  }
  return url;
}

// The create/finalize calls address `projects/-/sites/<site>/...`, and the
// Hosting API answers with either the bare `sites/...` resource name or the
// project-qualified `projects/<project>/sites/...` form. Both name the same
// resource; only the bare form may be pasted back into a request path, so
// accept either and return the bare one. The site segment stays pinned to the
// allowlist in both shapes, so this widens the accepted spelling without
// widening which site can be addressed.
function bareResourceName(value, expectedSite, suffixPattern) {
  if (!allowedSite(expectedSite) || typeof value !== "string") return undefined;
  const bare = `sites/${expectedSite}/${suffixPattern}`;
  if (new RegExp(`^${bare}$`, "u").test(value)) return value;
  const qualified = new RegExp(`^projects/[A-Za-z0-9_-]{1,128}/(${bare})$`, "u");
  return qualified.exec(value)?.[1];
}

function describeName(value) {
  return typeof value === "string" ? `"${value}"` : typeof value;
}

export function firebaseHostingVersionName(value, expectedSite) {
  const name = bareResourceName(value, expectedSite, `versions/${VERSION}`);
  if (name === undefined) {
    throw new Error(
      `Hosting API did not return an exact version name for site ${expectedSite} (got ${describeName(value)})`,
    );
  }
  return name;
}

export function firebaseHostingReleaseName(value, expectedSite) {
  const name = bareResourceName(
    value,
    expectedSite,
    `channels/live/releases/${VERSION}`,
  );
  if (name === undefined) {
    throw new Error(
      `Hosting API did not return an exact release name for site ${expectedSite} (got ${describeName(value)})`,
    );
  }
  return name;
}
