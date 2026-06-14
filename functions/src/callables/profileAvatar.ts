/**
 * @fileoverview Owner-scoped profile avatar signed URL issuance.
 */

import { getStorage } from "firebase-admin/storage";
import { HttpsError, onCall, type CallableRequest } from "firebase-functions/v2/https";

import { enforceAuthAndAppCheck } from "../auth.js";
import { getConfig } from "../config.js";
import { wrapCallableHandler } from "../logging.js";
import { FUNCTIONS_REGION } from "../runtimeOptions.js";

export const PROFILE_AVATAR_SIGNED_URL_TTL_MS = 24 * 60 * 60 * 1000;

type ProfileAvatarSignedUrlResponse = {
  ok: true;
  downloadURL: string;
  expiresAt: string;
  storagePath: string;
  ttlSeconds: number;
};

function profileAvatarStoragePath(uid: string): string {
  return `avatars/${uid}/profile.jpg`;
}

export async function signedProfileAvatarUrlForUid(
  uid: string,
  now: Date = new Date(),
): Promise<ProfileAvatarSignedUrlResponse> {
  const storagePath = profileAvatarStoragePath(uid);
  const file = getStorage().bucket().file(storagePath);
  const [exists] = await file.exists();
  if (!exists) {
    throw new HttpsError("not-found", "Profile avatar does not exist.");
  }

  const expiresAt = new Date(now.getTime() + PROFILE_AVATAR_SIGNED_URL_TTL_MS);
  const [downloadURL] = await file.getSignedUrl({
    version: "v4",
    action: "read",
    expires: expiresAt,
  });

  return {
    ok: true,
    downloadURL,
    expiresAt: expiresAt.toISOString(),
    storagePath,
    ttlSeconds: Math.floor(PROFILE_AVATAR_SIGNED_URL_TTL_MS / 1000),
  };
}

export const getProfileAvatarDownloadUrl = onCall(
  {
    region: FUNCTIONS_REGION,
    enforceAppCheck: getConfig().enforceAppCheck,
    maxInstances: 50,
  },
  wrapCallableHandler("getProfileAvatarDownloadUrl", async (request: CallableRequest) => {
    const uid = request.auth?.uid;
    if (!uid) {
      throw new HttpsError("unauthenticated", "Request must be authenticated.");
    }
    enforceAuthAndAppCheck(request, uid);
    return signedProfileAvatarUrlForUid(uid);
  }),
);
