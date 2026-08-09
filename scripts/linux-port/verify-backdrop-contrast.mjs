#!/usr/bin/env node

import { mkdir, writeFile } from "node:fs/promises";
import { createRequire } from "node:module";
import { dirname, join, resolve } from "node:path";
import { fileURLToPath } from "node:url";
import {
  BACKDROP_CANVAS_SELECTOR,
  BACKDROP_CSS_SELECTOR,
  DEFAULT_READINESS_TIMEOUT_MS,
  KERNEL_SWITCHER_PANEL_SELECTOR,
  KERNEL_SWITCHER_TRIGGER_SELECTOR,
  SHELL_READY_SELECTOR,
  withReadinessRetry,
} from "./lib/shell-readiness.mjs";

const root = resolve(dirname(fileURLToPath(import.meta.url)), "../..");
const require = createRequire(join(root, "apps/linux-desktop/package.json"));
const { chromium } = require("playwright");
const baseURL = process.env.OPENBURNBAR_CONTRAST_AUDIT_URL ?? "http://127.0.0.1:4178/";
const evidenceDir = resolve(
  root,
  process.env.OPENBURNBAR_CONTRAST_EVIDENCE_DIR ??
    "docs/linux-port/evidence/adaptive-foreground",
);
const timelineMs = [250, 750, 1_250];
const skins = ["editorial", "aurora"];
const screenshotKernels = new Set(["mesh", "origami", "storm-signal", "retro-plasma"]);
const headless = process.env.OPENBURNBAR_CONTRAST_HEADLESS === "1" || process.env.CI === "true";
let exitCode = 0;

function percentile(values, quantile) {
  if (values.length === 0) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  return sorted[Math.min(sorted.length - 1, Math.ceil(sorted.length * quantile) - 1)];
}

function parseDiagnostic(value) {
  const [tone, source, ratio, minimum, maximum, scrim, samplingDuration] = value.split(":");
  return {
    tone,
    source,
    contrastRatio: Number(ratio),
    minLuminance: Number(minimum),
    maxLuminance: Number(maximum),
    scrimOpacity: Number(scrim),
    samplingDurationMs: Number(samplingDuration),
  };
}

async function preparePage(browser, skin, viewport) {
  const page = await browser.newPage({ viewport });
  await page.addInitScript((selectedSkin) => {
    localStorage.setItem("openburnbar.linux.skin.v1", selectedSkin);
    localStorage.removeItem("openburnbar.linux.backdrop.mode.v1");
  }, skin);
  await page.goto(baseURL, { waitUntil: "networkidle" });
  await page.evaluate(async () => {
    const { useShellStore } = await import("/src/state/shellStore.ts");
    useShellStore.setState({
      route: "overview",
      bridgeReady: true,
      fixtureMode: true,
      capabilityError: null,
      runtimeCapabilities: null,
    });
  });
  // Wait for the shell's own readiness contract before touching any control:
  // the canvas backdrop must be live AND the shell must have published a
  // readability profile. Only then is the kernel switcher trigger reliably
  // interactable — polling `.kernel-switcher-trigger` directly used to time
  // out on slow boots before the chrome mounted.
  await page.waitForSelector(BACKDROP_CANVAS_SELECTOR, { timeout: DEFAULT_READINESS_TIMEOUT_MS });
  await page.waitForSelector(SHELL_READY_SELECTOR, { timeout: DEFAULT_READINESS_TIMEOUT_MS });
  await page.waitForSelector(KERNEL_SWITCHER_TRIGGER_SELECTOR, { timeout: DEFAULT_READINESS_TIMEOUT_MS });
  await page.waitForTimeout(650);
  return page;
}

async function openKernelPanel(page) {
  await page.locator(KERNEL_SWITCHER_TRIGGER_SELECTOR).click();
  await page.waitForSelector(KERNEL_SWITCHER_PANEL_SELECTOR, { timeout: DEFAULT_READINESS_TIMEOUT_MS });
}

async function kernelIds(page) {
  const { recovered } = await withReadinessRetry(async () => {
    await openKernelPanel(page);
  }, { onRetry: async () => page.keyboard.press("Escape") });
  if (recovered) recoveries.push("kernel-panel:open");
  const ids = await page.locator("[data-kernel-id]").evaluateAll((nodes) =>
    nodes.map((node) => node.getAttribute("data-kernel-id")).filter(Boolean),
  );
  await page.keyboard.press("Escape");
  return ids;
}

async function selectKernel(page, id) {
  const { recovered } = await withReadinessRetry(async () => {
    await openKernelPanel(page);
    await page.locator(`[data-kernel-id='${id}']`).evaluate((element) => element.click());
    await page.waitForFunction(
      (kernelId) => document.querySelector(".kernel-backdrop")?.getAttribute("data-kernel") === kernelId,
      id,
      { timeout: DEFAULT_READINESS_TIMEOUT_MS },
    );
  }, { onRetry: async () => page.keyboard.press("Escape") });
  if (recovered) recoveries.push(`kernel-select:${id}`);
}

await mkdir(evidenceDir, { recursive: true });
const browser = await chromium.launch({ headless });
const results = [];
const screenshots = [];
const interactionStates = [];
const consoleErrors = [];
const recoveries = [];

try {
  for (const skin of skins) {
    const page = await preparePage(browser, skin, { width: 1_440, height: 900 });
    page.on("console", (message) => {
      if (message.type() === "error") consoleErrors.push(`${skin}: ${message.text()}`);
    });
    const ids = await kernelIds(page);
    if (ids.length < 32) throw new Error(`registry audit found ${ids.length} kernels; expected at least 32`);

    for (const id of ids) {
      await selectKernel(page, id);
      let elapsed = 0;
      for (const timestampMs of timelineMs) {
        await page.waitForTimeout(timestampMs - elapsed);
        elapsed = timestampMs;
        const raw = await page.locator(".shell").getAttribute("data-readability");
        if (!raw) throw new Error(`${skin}/${id}/${timestampMs}: missing readability profile`);
        const profile = parseDiagnostic(raw);
        if (profile.source !== "canvas") {
          throw new Error(`${skin}/${id}/${timestampMs}: expected canvas profile, got ${profile.source}`);
        }
        if (profile.contrastRatio < 4.5) {
          throw new Error(`${skin}/${id}/${timestampMs}: ${profile.contrastRatio}:1 contrast`);
        }
        results.push({ skin, kernel: id, timestampMs, ...profile });
      }

      if (screenshotKernels.has(id)) {
        const path = join(evidenceDir, `${skin}-${id}-desktop.jpg`);
        await page.screenshot({ path, type: "jpeg", quality: 82 });
        screenshots.push(path.slice(root.length + 1));
      }
    }

    if (skin === "aurora") {
      await selectKernel(page, "mesh");
      await page.waitForTimeout(1_250);
      await openKernelPanel(page);
      const focusedOption = page.locator("[data-kernel-id='retro-plasma']");
      await focusedOption.hover();
      await focusedOption.focus();
      const menuPath = join(evidenceDir, "aurora-mesh-kernel-menu-desktop.jpg");
      await page.screenshot({ path: menuPath, type: "jpeg", quality: 82 });
      screenshots.push(menuPath.slice(root.length + 1));
      interactionStates.push("kernel-menu:hover+focus+selected");
      await page.keyboard.press("Escape");

      await page.getByRole("button", { name: "Open command palette" }).click();
      await page.getByRole("dialog", { name: "Command palette" }).waitFor();
      await page.locator(".command-palette-row").nth(1).hover();
      const palettePath = join(evidenceDir, "aurora-mesh-command-palette-desktop.jpg");
      await page.screenshot({ path: palettePath, type: "jpeg", quality: 82 });
      screenshots.push(palettePath.slice(root.length + 1));
      interactionStates.push("command-palette:modal+focus+hover+selected+muted");
      await page.keyboard.press("Escape");
    }
    await page.close();

    const compact = await preparePage(browser, skin, { width: 760, height: 720 });
    await selectKernel(compact, "mesh");
    await compact.waitForTimeout(1_250);
    const compactPath = join(evidenceDir, `${skin}-mesh-compact.jpg`);
    await compact.screenshot({ path: compactPath, type: "jpeg", quality: 82 });
    screenshots.push(compactPath.slice(root.length + 1));
    await compact.close();
  }

  const fallback = await browser.newPage({ viewport: { width: 1_024, height: 768 } });
  await fallback.addInitScript(() => {
    localStorage.setItem("openburnbar.linux.backdrop.mode.v1", "css");
  });
  await fallback.goto(baseURL, { waitUntil: "networkidle" });
  await fallback.waitForSelector(BACKDROP_CSS_SELECTOR, { timeout: DEFAULT_READINESS_TIMEOUT_MS });
  await fallback.waitForSelector(SHELL_READY_SELECTOR, { timeout: DEFAULT_READINESS_TIMEOUT_MS });
  const fallbackRaw = await fallback.locator(".shell").getAttribute("data-readability");
  const fallbackProfile = parseDiagnostic(fallbackRaw ?? "");
  if (fallbackProfile.source !== "css-fallback" || fallbackProfile.contrastRatio < 4.5) {
    throw new Error(`emergency CSS fallback failed: ${fallbackRaw}`);
  }
  await fallback.close();

  const samplingDurations = results.map((result) => result.samplingDurationMs);
  const report = {
    generatedAt: new Date().toISOString(),
    baseURL,
    browserMode: headless ? "headless" : "headed",
    kernels: [...new Set(results.map((result) => result.kernel))],
    skins,
    timestampsMs: timelineMs,
    sampleCount: results.length,
    toneCounts: Object.fromEntries(
      ["light", "dark"].map((tone) => [tone, results.filter((result) => result.tone === tone).length]),
    ),
    minimumContrastRatio: Math.min(...results.map((result) => result.contrastRatio)),
    samplingDurationMs: {
      p50: percentile(samplingDurations, 0.5),
      p95: percentile(samplingDurations, 0.95),
      maximum: Math.max(...samplingDurations),
    },
    fallback: fallbackProfile,
    screenshots,
    interactionStates,
    consoleErrors,
    recoveries,
    passed: consoleErrors.length === 0,
  };
  await writeFile(join(evidenceDir, "contrast-audit.json"), `${JSON.stringify(report, null, 2)}\n`);
  console.log(JSON.stringify(report, null, 2));
  if (!report.passed) exitCode = 1;
} finally {
  await browser.close();
}
process.exit(exitCode);
