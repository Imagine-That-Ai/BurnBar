// @vitest-environment jsdom
/**
 * Component-level gate for the Pensieve Recall card.
 *
 * test/pensieveRecall.test.ts pins the AAD contract; this pins the CARD, which is
 * where the bug actually lived: hits were opened with `openText(ciphertext, key)`
 * and no AAD context, so every RR-8 path-bound (schemaVersion-2) chunk the device
 * sealed was rejected and recall surfaced an error instead of results.
 *
 * The chunk here is sealed with the real vault key through the real escrow lib —
 * only the network call, the auth session, and the embedding are stubbed — so the
 * card has to rebuild the exact AAD from the hit's own vectorId to render text.
 */
import { readFileSync } from "node:fs";
import { resolve } from "node:path";
import { act } from "react";
import { createRoot, type Root } from "react-dom/client";
import { afterEach, beforeAll, describe, expect, it, vi } from "vitest";
import { importVaultKey, sealText } from "../lib/escrow";
import { knowledgeChunkAADContext } from "../lib/recall";
import { initializeCloudVaultDomainCoreForTests } from "../lib/domainCoreCloudVault";
import { setConsoleVaultKey } from "../lib/vaultKeySession";

const UID = "console-user";
const VECTOR_ID = "b7f1c3d5e90a4c2fa1806d4e5f2b39c8";
const CHUNK_TEXT = "Pensieve remembers: the vault key never leaves the device.";

const searchKnowledge = vi.fn();

vi.mock("@/lib/api", () => ({
  searchKnowledge: (...args: unknown[]) => searchKnowledge(...args),
}));

vi.mock("@/lib/useAuth", () => ({
  useAuth: () => ({ user: { uid: UID }, loading: false }),
}));

// Keep the AAD builder real — it is the thing under test. Only the embedding
// (which needs no coverage here) is stubbed out.
vi.mock("@/lib/recall", async (importOriginal) => ({
  ...(await importOriginal<typeof import("../lib/recall")>()),
  embedAndCloakQuery: async () => ({
    embeddingModelVersion: "hashing-bow-v1",
    queryVector: new Array(384).fill(0),
  }),
}));

const { PensieveRecallCard } = await import("../components/pensieve/PensieveRecallCard");

beforeAll(() => {
  // jsdom rewrites import.meta.url to an http URL, so resolve from __dirname.
  const wasmPath = resolve(
    __dirname,
    "../vendor/openburnbar-domain-core-wasm/openburnbar_domain_core_bg.wasm",
  );
  const manifestPath = resolve(
    __dirname,
    "../../../crates/openburnbar-domain-core/union-abi-manifest.json",
  );
  const expected = JSON.parse(readFileSync(manifestPath, "utf8")) as {
    coreVersion: string;
    abiVersion: number;
    sourceSha256: string;
  };
  initializeCloudVaultDomainCoreForTests(readFileSync(wasmPath), expected);
  (globalThis as { IS_REACT_ACT_ENVIRONMENT?: boolean }).IS_REACT_ACT_ENVIRONMENT = true;
});

let container: HTMLDivElement | null = null;
let root: Root | null = null;

afterEach(async () => {
  if (root) await act(async () => root!.unmount());
  container?.remove();
  root = null;
  container = null;
  searchKnowledge.mockReset();
});

/** Seal a chunk exactly as PensieveKnowledgeChunker.prepareBatch does with a uid. */
async function sealChunkForHit(vectorId: string) {
  const raw = globalThis.crypto.getRandomValues(new Uint8Array(32));
  const key = await importVaultKey(raw);
  const ciphertext = await sealText(CHUNK_TEXT, key, {
    aadContext: knowledgeChunkAADContext(UID, vectorId),
    rawVaultKey: raw,
  });
  return { raw, key, ciphertext };
}

function hitFor(vectorId: string, ciphertext: unknown) {
  return {
    vectorId,
    ciphertext,
    sealedMetadata: null,
    sourceKind: "notes" as const,
    sourceSlug: "console-notes",
    contentHash: "",
    score: 0.91,
    decryptMode: "local_decrypt" as const,
  };
}

async function renderAndSearch() {
  container = document.createElement("div");
  document.body.append(container);
  root = createRoot(container);
  await act(async () => root!.render(<PensieveRecallCard />));

  // Drive the controlled input the way React sees a real keystroke.
  const input = container.querySelector("input")!;
  const setValue = Object.getOwnPropertyDescriptor(HTMLInputElement.prototype, "value")!.set!;
  await act(async () => {
    setValue.call(input, "what does pensieve remember");
    input.dispatchEvent(new Event("input", { bubbles: true }));
  });

  const button = container.querySelector("button")!;
  expect(button.disabled).toBe(false);
  await act(async () => {
    button.dispatchEvent(new MouseEvent("click", { bubbles: true }));
  });
  // Let the awaited search + decrypt chain settle before asserting. The WASM
  // openText is several microtask hops, so a single Promise.resolve() flush is
  // not enough on a slower runner. The wait has to happen OUTSIDE act — React
  // does not flush the `busy` state updates until the act scope exits, so
  // polling inside act never sees "Searching..." clear. Poll until `busy`
  // clears, then flush once more before asserting.
  await vi.waitFor(
    () => {
      expect(container!.textContent).not.toContain("Searching");
    },
    { timeout: 10_000 },
  );
  await act(async () => {
    await Promise.resolve();
  });
}

describe("PensieveRecallCard", () => {
  it("decrypts and renders a path-bound v2 chunk", async () => {
    const { raw, key, ciphertext } = await sealChunkForHit(VECTOR_ID);
    setConsoleVaultKey(key, raw);
    searchKnowledge.mockResolvedValue({
      ok: true,
      hits: [hitFor(VECTOR_ID, ciphertext)],
      embeddingModelVersion: "hashing-bow-v1",
    });

    await renderAndSearch();

    // Before the fix this rendered the invalid_envelope error instead.
    expect(container!.textContent).toContain(CHUNK_TEXT);
    expect(container!.textContent).not.toContain("Invalid CloudVault");
    expect(container!.textContent).toContain("console-notes");
  });

  it("still renders legacy uid-less chunks (the daemon queue writer's shape)", async () => {
    const raw = globalThis.crypto.getRandomValues(new Uint8Array(32));
    const key = await importVaultKey(raw);
    const legacy = await sealText(CHUNK_TEXT, key);
    setConsoleVaultKey(key, raw);
    searchKnowledge.mockResolvedValue({
      ok: true,
      hits: [hitFor("5c2e0918aa734bd6b0f4e73c1d8a6f20", legacy)],
      embeddingModelVersion: "hashing-bow-v1",
    });

    await renderAndSearch();

    expect(container!.textContent).toContain(CHUNK_TEXT);
  });

  it("surfaces an error when a chunk is bound to a different vectorId", async () => {
    // A chunk sealed for one doc id must not open under another — the card derives
    // the AAD from the hit it was handed, so a transplanted row stays sealed.
    const { raw, key, ciphertext } = await sealChunkForHit("some-other-vector-id");
    setConsoleVaultKey(key, raw);
    searchKnowledge.mockResolvedValue({
      ok: true,
      hits: [hitFor(VECTOR_ID, ciphertext)],
      embeddingModelVersion: "hashing-bow-v1",
    });

    await renderAndSearch();

    expect(container!.textContent).not.toContain(CHUNK_TEXT);
    expect(container!.textContent).toContain("Invalid CloudVault sealed-text AAD context.");
  });
});
