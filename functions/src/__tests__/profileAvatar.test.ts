import { beforeEach, describe, expect, it, vi } from "vitest";

const exists = vi.fn();
const getSignedUrl = vi.fn();
const file = vi.fn(() => ({ exists, getSignedUrl }));
const bucket = vi.fn(() => ({ file }));

vi.mock("firebase-admin/storage", () => ({
  getStorage: () => ({ bucket }),
}));

vi.mock("../config.js", () => ({
  getConfig: () => ({ enforceAppCheck: false }),
}));

describe("profile avatar signed URLs", () => {
  beforeEach(() => {
    vi.clearAllMocks();
  });

  it("issues a bounded owner avatar read URL", async () => {
    exists.mockResolvedValueOnce([true]);
    getSignedUrl.mockResolvedValueOnce(["https://storage.example/avatar?signature=ok"]);

    const { PROFILE_AVATAR_SIGNED_URL_TTL_MS, signedProfileAvatarUrlForUid } =
      await import("../callables/profileAvatar.js");
    const now = new Date("2026-06-14T12:00:00.000Z");

    const result = await signedProfileAvatarUrlForUid("user-123", now);

    expect(file).toHaveBeenCalledWith("avatars/user-123/profile.jpg");
    expect(getSignedUrl).toHaveBeenCalledWith({
      version: "v4",
      action: "read",
      expires: new Date(now.getTime() + PROFILE_AVATAR_SIGNED_URL_TTL_MS),
    });
    expect(result).toEqual({
      ok: true,
      downloadURL: "https://storage.example/avatar?signature=ok",
      expiresAt: "2026-06-15T12:00:00.000Z",
      storagePath: "avatars/user-123/profile.jpg",
      ttlSeconds: 86_400,
    });
  });

  it("fails closed when the owner has no avatar object", async () => {
    exists.mockResolvedValueOnce([false]);

    const { signedProfileAvatarUrlForUid } = await import("../callables/profileAvatar.js");

    await expect(signedProfileAvatarUrlForUid("missing-user")).rejects.toMatchObject({
      code: "not-found",
    });
    expect(getSignedUrl).not.toHaveBeenCalled();
  });
});
