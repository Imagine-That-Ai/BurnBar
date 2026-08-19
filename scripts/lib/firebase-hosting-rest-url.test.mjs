import assert from "node:assert/strict";
import test from "node:test";

import {
  firebaseHostingApiUrl,
  firebaseHostingReleaseName,
  firebaseHostingUploadUrl,
  firebaseHostingVersionName,
} from "./firebase-hosting-rest-url.mjs";

const HASH = "a".repeat(64);

test("accepts only the exact Firebase Hosting REST endpoint shapes", () => {
  assert.equal(
    firebaseHostingApiUrl("POST", "/projects/-/sites/burnbar/versions").href,
    "https://firebasehosting.googleapis.com/v1beta1/projects/-/sites/burnbar/versions",
  );
  assert.equal(
    firebaseHostingApiUrl(
      "POST",
      "/sites/burnbar/versions/version_1:populateFiles",
    ).pathname,
    "/v1beta1/sites/burnbar/versions/version_1:populateFiles",
  );
  assert.equal(
    firebaseHostingApiUrl(
      "PATCH",
      "/projects/-/sites/burnbar-console/versions/version_2?updateMask=status,config",
    ).searchParams.get("updateMask"),
    "status,config",
  );
  assert.equal(
    firebaseHostingApiUrl(
      "POST",
      "/projects/-/sites/burnbar/channels/live/releases?versionName=sites%2Fburnbar%2Fversions%2Fversion_1",
    ).origin,
    "https://firebasehosting.googleapis.com",
  );
});

test("rejects alternate origins, ports, methods, sites, paths, and query keys", () => {
  for (const [method, path] of [
    ["POST", "//evil.example/projects/-/sites/burnbar/versions"],
    ["POST", "/projects/-/sites/attacker/versions"],
    ["DELETE", "/projects/-/sites/burnbar/versions"],
    ["POST", "/projects/-/sites/burnbar/versions?next=https://evil.example"],
    [
      "PATCH",
      "/projects/-/sites/burnbar/versions/v1?updateMask=status&extra=config",
    ],
    [
      "POST",
      "/projects/-/sites/burnbar/channels/live/releases?versionName=sites%2Fattacker%2Fversions%2Fv1",
    ],
  ]) {
    assert.throws(
      () => firebaseHostingApiUrl(method, path),
      /Firebase Hosting/u,
    );
  }
});

test("pins uploads to the exact upload origin, site path, and SHA-256 object", () => {
  const base =
    "https://upload-firebasehosting.googleapis.com/upload/sites/burnbar/versions/v1/files";
  assert.equal(
    firebaseHostingUploadUrl(base, "burnbar", HASH).href,
    `${base}/${HASH}`,
  );

  for (const hostile of [
    "https://upload-firebasehosting.googleapis.com.evil.example/upload/sites/burnbar/versions/v1/files",
    "https://evil.example/?next=https://upload-firebasehosting.googleapis.com/upload/sites/burnbar/versions/v1/files",
    "https://upload-firebasehosting.googleapis.com:444/upload/sites/burnbar/versions/v1/files",
    "https://user@upload-firebasehosting.googleapis.com/upload/sites/burnbar/versions/v1/files",
    "https://upload-firebasehosting.googleapis.com/upload/sites/burnbar-console/versions/v1/files",
    "https://upload-firebasehosting.googleapis.com/upload/sites/burnbar/versions/v1/files?token=attacker",
  ]) {
    assert.throws(
      () => firebaseHostingUploadUrl(hostile, "burnbar", HASH),
      /Firebase Hosting/u,
    );
  }
  assert.throws(
    () => firebaseHostingUploadUrl(base, "burnbar", "not-a-hash"),
    /Firebase Hosting/u,
  );
});

test("accepts only exact immutable version and release resource names", () => {
  assert.equal(
    firebaseHostingVersionName("sites/burnbar/versions/v1", "burnbar"),
    "sites/burnbar/versions/v1",
  );
  assert.equal(
    firebaseHostingReleaseName(
      "sites/burnbar-console/channels/live/releases/r1",
      "burnbar-console",
    ),
    "sites/burnbar-console/channels/live/releases/r1",
  );
  assert.throws(
    () =>
      firebaseHostingVersionName("sites/burnbar/versions/v1/extra", "burnbar"),
    /exact version name/u,
  );
  assert.throws(
    () =>
      firebaseHostingReleaseName(
        "sites/attacker/channels/live/releases/r1",
        "burnbar",
      ),
    /exact release name/u,
  );
});

test("project-qualified resource names normalize to the bare request path", () => {
  // The Hosting API may answer a `projects/-/sites/...` create with either the
  // bare or the project-qualified name. Both must resolve to the bare form,
  // because that is what gets pasted back into :populateFiles and :finalize.
  assert.equal(
    firebaseHostingVersionName(
      "projects/openburnbar/sites/burnbar/versions/v1",
      "burnbar",
    ),
    "sites/burnbar/versions/v1",
  );
  assert.equal(
    firebaseHostingReleaseName(
      "projects/openburnbar/sites/burnbar-console/channels/live/releases/r1",
      "burnbar-console",
    ),
    "sites/burnbar-console/channels/live/releases/r1",
  );
  // Qualifying the name must not smuggle in a site outside the allowlist.
  assert.throws(
    () =>
      firebaseHostingVersionName(
        "projects/openburnbar/sites/attacker/versions/v1",
        "burnbar",
      ),
    /exact version name/u,
  );
  // A nested project segment must not let a second `sites/` slip through.
  assert.throws(
    () =>
      firebaseHostingVersionName(
        "projects/a/sites/evil/sites/burnbar/versions/v1",
        "burnbar",
      ),
    /exact version name/u,
  );
  // The failure names what actually came back, so the next outage is one read.
  assert.throws(
    () => firebaseHostingVersionName(undefined, "burnbar"),
    /got undefined/u,
  );
});
