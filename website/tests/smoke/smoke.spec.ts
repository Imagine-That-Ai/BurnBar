import { test, expect, type Page, type Response } from "@playwright/test";
import { AxeBuilder } from "@axe-core/playwright";

/**
 * Public-route smoke test. Every route at two viewports in both color
 * schemes. Fails on: console errors, failed same-origin requests, broken
 * internal links, missing title/description/OG, mobile horizontal
 * overflow, and serious/critical axe violations.
 *
 * Known-issue allowlist keys entries by the BB finding id so an allowance
 * is auditable and dies with the fix.
 */

const ROUTES = [
  "/",
  "/404",
  "/bench",
  "/bench/arena",
  "/bench/arena/vote",
  "/bench/data",
  "/bench/methodology",
  "/bench/report",
  "/benefits",
  "/beta",
  "/control",
  "/download",
  "/faq",
  "/floo",
  "/hermes/connect",
  "/legal/privacy-policy",
  "/legal/source",
  "/legal/terms",
  "/link",
  "/mcp",
  "/memory",
  "/platforms",
  "/pricing",
  "/privacy",
  "/product",
  "/providers",
  "/router",
  "/router/daily",
  "/security",
  "/subscribe",
  "/support",
  "/trust",
] as const;

/**
 * axe rule ids allowed while a fix is tracked, keyed "route|rule".
 * Each entry must name its tracking finding. Enumerated per route (no
 * wildcards) so any *new* route stays fully enforced — this list is the
 * exact set that fails today, verified against a local build.
 */
const AXE_ALLOWLIST: Record<string, string> = {
  // BB-20 follow-up: light-mode colour-contrast sweep across shared
  // components (.platcard__, .ins-eyebrow, .tierbadge__, .platform__pill,
  // .ladder__num, .archcard__score, verdict footnotes). Found BY this suite
  // — tracked as one design-system pass, not per-page patches.
  "/|color-contrast": "BB-20",
  "/bench|color-contrast": "BB-20",
  "/bench/arena|color-contrast": "BB-20",
  "/bench/methodology|color-contrast": "BB-20",
  "/bench/report|color-contrast": "BB-20",
  "/control|color-contrast": "BB-20",
  "/download|color-contrast": "BB-20",
  "/faq|color-contrast": "BB-20",
  "/mcp|color-contrast": "BB-20",
  "/memory|color-contrast": "BB-20",
  "/platforms|color-contrast": "BB-20",
  "/privacy|color-contrast": "BB-20",
  "/product|color-contrast": "BB-20",
  "/router|color-contrast": "BB-20",
  "/router/daily|color-contrast": "BB-20",
  "/trust|color-contrast": "BB-20",
};

/** Console messages that are third-party noise rather than page defects. */
const CONSOLE_NOISE = [
  /Failed to load resource/i, // counted separately via requestFailed below
  /postMessage/i, // BB-33: Firebase/Google iframe internals, not repo code
  /\[Report Only\]/i, // CSP report-only noise
  /Deprecat/i,
  /downloadable font/i,
  /net::ERR_/i,
  /favicon/i,
  /requestStorageAccess/i, // storage-access API probing, not a defect
];

async function collectConsoleErrors(page: Page): Promise<string[]> {
  const errors: string[] = [];
  page.on("console", (msg) => {
    if (msg.type() !== "error") return;
    const text = msg.text();
    if (CONSOLE_NOISE.some((re) => re.test(text))) return;
    errors.push(text);
  });
  page.on("pageerror", (err) => errors.push(`pageerror: ${err.message}`));
  return errors;
}

async function failedSameOriginRequests(page: Page, requestFailed: (r: Response) => void) {
  page.on("response", (response) => {
    try {
      const url = new URL(response.url());
      const base = new URL(page.context()._options.baseURL ?? "http://localhost");
      if (url.origin !== base.origin) return;
      if (response.status() >= 400) requestFailed(response);
    } catch {
      /* opaque/chrome- url */
    }
  });
}

test.describe("public routes", () => {
  for (const route of ROUTES) {
    test(`${route}`, async ({ page, baseURL }, testInfo) => {
      const consoleErrors = await collectConsoleErrors(page);
      const failedResponses: string[] = [];
      const base = new URL(baseURL ?? "http://localhost:4322");

      page.on("response", (response) => {
        try {
          const url = new URL(response.url());
          if (url.origin === base.origin && response.status() >= 400) {
            failedResponses.push(`${response.status()} ${response.url()}`);
          }
        } catch {
          /* ignore */
        }
      });
      page.on("requestfailed", (request) => {
        try {
          const url = new URL(request.url());
          if (url.origin === base.origin) {
            failedResponses.push(`failed ${request.url()}`);
          }
        } catch {
          /* ignore */
        }
      });

      const response = await page.goto(route, { waitUntil: "domcontentloaded" });
      await page.waitForLoadState("networkidle", { timeout: 10_000 }).catch(() => {});

      // The /404 template must render; static hosts (Firebase) return a 404
      // status, the local preview server returns 200 — accept either.
      if (route === "/404") {
        expect([200, 404]).toContain(response?.status());
      } else {
        expect(response?.status(), `${route} should return 200`).toBe(200);
      }

      // Meta sanity.
      await expect(page).toHaveTitle(/.+/);
      const description = page.locator('meta[name="description"]');
      await expect(description, `${route} missing meta description`).toHaveAttribute(
        "content",
        /.+/,
      );
      const ogTitle = page.locator('meta[property="og:title"]');
      await expect(ogTitle, `${route} missing og:title`).toHaveAttribute("content", /.+/);

      // Mobile horizontal overflow.
      const overflow = await page.evaluate(() => {
        const doc = document.documentElement;
        return doc.scrollWidth - doc.clientWidth;
      });
      expect(overflow, `${route} has ${overflow}px horizontal overflow`).toBeLessThanOrEqual(0);

      // Broken internal links: every same-origin href must map to a known
      // public route or a static asset path. Route existence is also probed
      // end-to-end by this suite itself — the HEAD fetch variant flooded the
      // single-threaded preview server, so link integrity is asserted
      // structurally here (npm run links:check covers raw file targets).
      const badLinks = await page.evaluate((routes) => {
        const valid = new Set(routes);
        const assetPrefixes = [
          "/brand/",
          "/_astro/",
          "/icons/",
          "/img/",
          "/favicon",
          "/robots.txt",
          "/sitemap",
          "/.well-known/",
          "/api/",
          "/rundown/",
          "/downloads/",
          "/data/",
        ];
        const bad: string[] = [];
        for (const a of document.querySelectorAll<HTMLAnchorElement>("a[href]")) {
          const raw = a.getAttribute("href") ?? "";
          if (!raw.startsWith("/") || raw.startsWith("//")) continue;
          const path = raw.split("#")[0].split("?")[0].replace(/\/$/, "") || "/";
          if (valid.has(path)) continue;
          if (assetPrefixes.some((pre) => path.startsWith(pre))) continue;
          // dated archive routes, e.g. /router/daily/2026-06-12
          if (/^\/router\/daily\/\d{4}-\d{2}-\d{2}$/.test(path)) continue;
          bad.push(raw);
        }
        return [...new Set(bad)];
      }, [...ROUTES]);
      expect(badLinks, `${route} internal links`).toEqual([]);

      // axe: serious + critical only.
      const axe = await new AxeBuilder({ page })
        .withTags(["wcag2a", "wcag2aa", "wcag21a", "wcag21aa"])
        .analyze();
      const violations = axe.violations.filter(
        (v) =>
          (v.impact === "serious" || v.impact === "critical") &&
          !AXE_ALLOWLIST[`${route}|${v.id}`] &&
          !AXE_ALLOWLIST[`*|${v.id}`],
      );
      expect(
        violations.map((v) => `${v.id} (${v.impact}) ${v.nodes.length} nodes`),
        `${route} axe violations`,
      ).toEqual([]);

      expect(failedResponses, `${route} same-origin failures`).toEqual([]);
      expect(consoleErrors, `${route} console errors`).toEqual([]);

      // Per-route, per-project PNG under outputDir (website/test-results/smoke)
      // so the uploaded artifact carries visual evidence for every route.
      await page
        .screenshot({
          path: testInfo.outputPath(`screens/${testInfo.project.name}${route === "/" ? "/index" : route}.png`),
          fullPage: true,
        })
        .catch(() => {});
    });
  }
});

/**
 * Logged-in smoke: only when staging test-account secrets exist. Never
 * creates accounts, never points at production.
 */
const stagingEmail = process.env.BURNBAR_STAGING_TEST_EMAIL;
const stagingPassword = process.env.BURNBAR_STAGING_TEST_PASSWORD;

test.describe("logged-in smoke", () => {
  test.skip(
    !stagingEmail || !stagingPassword,
    "BURNBAR_STAGING_TEST_EMAIL/PASSWORD not set — skipped",
  );

  /**
   * Really sign in to burnbar-staging with the email/password test account
   * (REST signInWithPassword against the staging apiKey scraped from the
   * built bundle — BB-01 guarantees it is the staging key), inject the
   * session into the site's own Firebase Auth IndexedDB slot, reload, and
   * assert the signed-in surface on /subscribe. Then sign out.
   * Staging only — never points at production, never creates accounts.
   */
  test("signs in on burnbar-staging and sees the signed-in state", async ({
    page,
    baseURL,
    request,
  }) => {
    // Scrape the baked apiKey out of the served bundle.
    await page.goto("/subscribe", { waitUntil: "domcontentloaded" });
    const apiKey = await page.evaluate(async () => {
      const srcs = [...document.querySelectorAll<HTMLScriptElement>("script[src]")]
        .map((s) => s.src)
        .filter((s) => s.includes("/_astro/"));
      for (const src of srcs) {
        const text = await fetch(src).then((r) => r.text());
        const m = text.match(/apiKey["']?\s*[:=]\s*["'](AIza[\w-]{20,})["']/) ??
          text.match(/["'](AIza[\w-]{20,})["']/);
        if (m) return m[1];
      }
      return null;
    });
    expect(apiKey, "staging apiKey discoverable in bundle").toBeTruthy();

    const signIn = await request.post(
      `https://identitytoolkit.googleapis.com/v1/accounts:signInWithPassword?key=${apiKey}`,
      { data: { email: stagingEmail, password: stagingPassword, returnSecureToken: true } },
    );
    expect(signIn.ok(), "staging email/password sign-in").toBeTruthy();
    const creds = (await signIn.json()) as {
      localId: string; idToken: string; refreshToken: string; expiresIn: string;
    };

    // Seed the SDK's persistence slot, then reload so auth hydrates.
    const authUser = {
      uid: creds.localId,
      email: stagingEmail,
      emailVerified: false,
      displayName: null,
      photoURL: null,
      phoneNumber: null,
      isAnonymous: false,
      tenantId: null,
      providerData: [
        { providerId: "password", uid: stagingEmail, displayName: null, email: stagingEmail, phoneNumber: null, photoURL: null },
      ],
      stsTokenManager: {
        apiKey,
        refreshToken: creds.refreshToken,
        accessToken: creds.idToken,
        expirationTime: Date.now() + Number(creds.expiresIn) * 1000,
      },
      createdAt: String(Date.now()),
      lastLoginAt: String(Date.now()),
      apiKey,
      appName: "[DEFAULT]",
      lastRefreshAt: new Date().toISOString(),
    };
    await page.evaluate(async ({ apiKey: k, user }) => {
      await new Promise<void>((resolve, reject) => {
        const open = indexedDB.open("firebaseLocalStorageDb", 1);
        open.onupgradeneeded = () => open.result.createObjectStore("firebaseLocalStorage");
        open.onsuccess = () => {
          const tx = open.result.transaction("firebaseLocalStorage", "readwrite");
          tx.objectStore("firebaseLocalStorage").put(user, `firebase:authUser:${k}:[DEFAULT]`);
          tx.oncomplete = () => resolve();
          tx.onerror = () => reject(tx.error);
        };
        open.onerror = () => reject(open.error);
      });
    }, { apiKey, user: authUser });

    await page.goto("/subscribe", { waitUntil: "domcontentloaded" });
    const ready = page.locator("#state-ready");
    await expect(ready, "/subscribe signed-in state").toBeVisible({ timeout: 15_000 });
    await expect(page.locator("#user-email")).toContainText(String(stagingEmail));

    // Sign out and confirm the surface returns to signed-out.
    await page.locator("#btn-signout").click();
    await expect(page.locator("#state-signed-out")).toBeVisible({ timeout: 15_000 });
  });
});
