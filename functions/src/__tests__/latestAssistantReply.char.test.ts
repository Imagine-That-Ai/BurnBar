/**
 * Characterization pin for `latestAssistantReply` (U12 complexity refactor).
 *
 * Records the CURRENT observable behavior of `latestAssistantReply` across the
 * sealed-payload fast path, the messages-array reverse scan, and the
 * no-match / undefined-input cases. The refactor extracts cohesive helpers; this
 * test guarantees the relocations are pure (identical inputs -> identical output).
 *
 * `latestAssistantReply` is a pure, exported function with no Firestore /
 * messaging side-effects, so it is imported directly. The firebase-admin modules
 * are still mocked because importing `../agentNotifications.js` registers the
 * onSchedule / onDocumentWritten triggers at module load.
 */

import { describe, expect, it, vi } from "vitest";

vi.mock("firebase-admin/firestore", async () => {
  const actual = await vi.importActual<typeof import("firebase-admin/firestore")>("firebase-admin/firestore");
  return { ...actual, getFirestore: vi.fn() };
});
vi.mock("firebase-admin/messaging", () => ({ getMessaging: () => ({ send: vi.fn() }) }));

import { latestAssistantReply } from "../agentNotifications.js";

describe("latestAssistantReply characterization (U12)", () => {
  it("returns the sealed assistant reply via the sealed fast path", () => {
    const result = latestAssistantReply({
      contentSealed: true,
      lastMessageRole: "assistant",
      lastAssistantMessageID: "msg-sealed-1",
      updatedAt: 1_700_000_000_000,
      updatedAtMillis: 1_700_000_000_999,
    });

    expect(result).toEqual({
      id: "msg-sealed-1",
      role: "assistant",
      timestamp: 1_700_000_000_000,
      isError: false,
    });
  });

  it("uses sealedPayload presence (not contentSealed) and falls back to updatedAtMillis for timestamp", () => {
    const result = latestAssistantReply({
      sealedPayload: { sealedBoxBase64: "abc" },
      lastMessageRole: "assistant",
      lastAssistantMessageID: "msg-sealed-2",
      updatedAtMillis: 42,
    });

    expect(result).toEqual({
      id: "msg-sealed-2",
      role: "assistant",
      timestamp: 42,
      isError: false,
    });
  });

  it("returns the last assistant message from the messages array, reading content when text is absent", () => {
    const result = latestAssistantReply({
      messages: [
        { id: "u-1", role: "user", text: "hi" },
        { id: "a-1", role: "assistant", text: "first reply" },
        { id: "a-2", role: "assistant", content: "  newest reply  ", timestamp: 99, isError: true },
      ],
    });

    expect(result).toEqual({
      id: "a-2",
      role: "assistant",
      text: "newest reply",
      timestamp: 99,
      isError: true,
    });
  });

  it("skips assistant messages missing a non-empty id or text and keeps scanning backward", () => {
    const result = latestAssistantReply({
      messages: [
        { id: "a-keep", role: "assistant", text: "kept reply" },
        { id: "", role: "assistant", text: "no id" },
        { id: "a-empty", role: "assistant", text: "   " },
      ],
    });

    expect(result).toEqual({
      id: "a-keep",
      role: "assistant",
      text: "kept reply",
      timestamp: undefined,
      isError: false,
    });
  });

  it("returns undefined when no assistant message qualifies", () => {
    expect(
      latestAssistantReply({
        messages: [
          { id: "u-1", role: "user", text: "only a user message" },
          { id: "s-1", role: "system", text: "system note" },
        ],
      }),
    ).toBeUndefined();
  });

  it("returns undefined for undefined input and for an empty record", () => {
    expect(latestAssistantReply(undefined)).toBeUndefined();
    expect(latestAssistantReply({})).toBeUndefined();
  });

  it("ignores the sealed fast path when the sealed role is not assistant", () => {
    const result = latestAssistantReply({
      contentSealed: true,
      lastMessageRole: "user",
      lastAssistantMessageID: "msg-x",
      messages: [{ id: "a-9", role: "assistant", text: "real reply" }],
    });

    expect(result).toEqual({
      id: "a-9",
      role: "assistant",
      text: "real reply",
      timestamp: undefined,
      isError: false,
    });
  });
});
