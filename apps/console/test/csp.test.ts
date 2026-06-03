import { describe, expect, it } from "vitest";
import firebaseJson from "../../../firebase.json";
import { readFileSync } from "node:fs";

type Header = { key: string; value: string };
type HostingTarget = {
  target: string;
  headers?: Array<{ source: string; headers: Header[] }>;
};

const requiredConsoleCsp = {
  "script-src": [
    "https://apis.google.com",
    "https://www.google.com/recaptcha/",
    "https://www.gstatic.com/recaptcha/",
  ],
  "connect-src": [
    "https://apis.google.com",
    "https://*.googleapis.com",
    "https://identitytoolkit.googleapis.com",
    "https://securetoken.googleapis.com",
    "https://firebaseinstallations.googleapis.com",
    "https://firebaseappcheck.googleapis.com",
    "https://content-firebaseappcheck.googleapis.com",
    "https://www.google.com",
    "https://www.gstatic.com",
  ],
  "frame-src": [
    "https://*.firebaseapp.com",
    "https://accounts.google.com",
    "https://appleid.apple.com",
    "https://www.google.com/recaptcha/",
  ],
};

function parseCsp(csp: string): Map<string, Set<string>> {
  return new Map(
    csp.split(";").map((directive) => {
      const [name, ...sources] = directive.trim().split(/\s+/);
      return [name, new Set(sources)];
    }),
  );
}

function consoleHostingHeaders(): Header[] {
  const consoleTarget = (firebaseJson.hosting as HostingTarget[]).find(
    (target) => target.target === "console",
  );
  const globalHeaders = consoleTarget?.headers?.find((entry) => entry.source === "**");
  expect(globalHeaders?.headers).toBeTruthy();
  return globalHeaders!.headers;
}

function consoleHostingCsp(): string {
  const csp = consoleHostingHeaders().find((header) => header.key === "Content-Security-Policy");
  expect(csp?.value).toBeTruthy();
  return csp!.value;
}

describe("console CSP", () => {
  it("allows the Firebase Auth popup bridge and App Check reCAPTCHA Enterprise runtime", () => {
    const directives = parseCsp(consoleHostingCsp());

    for (const [directive, sources] of Object.entries(requiredConsoleCsp)) {
      for (const source of sources) {
        expect(directives.get(directive), `${directive} should include ${source}`).toContain(
          source,
        );
      }
    }
  });

  it("keeps next.config and Firebase Hosting in sync for auth/App Check origins", () => {
    const nextConfig = readFileSync(new URL("../next.config.mjs", import.meta.url), "utf8");
    const hostingCsp = consoleHostingCsp();

    for (const sources of Object.values(requiredConsoleCsp)) {
      for (const source of sources) {
        expect(nextConfig, `next.config should include ${source}`).toContain(source);
        expect(hostingCsp, `firebase.json should include ${source}`).toContain(source);
      }
    }
  });

  it("allows Firebase Auth popups to communicate with the opener", () => {
    expect(consoleHostingHeaders()).toContainEqual({
      key: "Cross-Origin-Opener-Policy",
      value: "same-origin-allow-popups",
    });
  });
});

describe("console auth domain", () => {
  it("documents the registered Firebase Auth handler domain used by production OAuth", () => {
    const envExample = readFileSync(new URL("../.env.example", import.meta.url), "utf8");
    const firebaseClient = readFileSync(new URL("../lib/firebaseClient.ts", import.meta.url), "utf8");

    expect(envExample).toContain("NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN=app.burnbar.ai");
    expect(envExample).toContain("NEXT_PUBLIC_ENABLE_APPLE_AUTH=false");
    expect(firebaseClient).toContain(
      'authDomain: process.env.NEXT_PUBLIC_FIREBASE_AUTH_DOMAIN || "app.burnbar.ai"',
    );
  });
});
