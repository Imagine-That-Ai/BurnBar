import { describe, expect, it } from "vitest";
import { Agent } from "undici";

import { ssrfHardenedAgent, ssrfHardenedFetch } from "../ssrfAgent.js";

describe("ssrfHardenedAgent", () => {
  it("is a redirect-disabled undici Agent reused as a singleton", () => {
    const a = ssrfHardenedAgent();
    const b = ssrfHardenedAgent();
    expect(a).toBeInstanceOf(Agent);
    expect(a).toBe(b); // singleton — connection pool is shared
  });
});

describe("ssrfHardenedFetch", () => {
  it("runs the synchronous SSRF string gate before any network I/O", async () => {
    // Metadata + private hosts are rejected by the string gate, so no socket is
    // ever opened (the DNS-pin lookup would also catch a rebind, but we never
    // get that far).
    await expect(ssrfHardenedFetch("http://169.254.169.254/")).rejects.toThrow(/SSRF guard/);
    await expect(ssrfHardenedFetch("http://metadata.google.internal/")).rejects.toThrow(/SSRF guard/);
    await expect(ssrfHardenedFetch("http://10.0.0.1/")).rejects.toThrow(/SSRF guard/);
    await expect(ssrfHardenedFetch("http://[::ffff:169.254.169.254]/")).rejects.toThrow(/SSRF guard/);
    await expect(ssrfHardenedFetch("file:///etc/passwd")).rejects.toThrow(/SSRF guard/);
  });
});
