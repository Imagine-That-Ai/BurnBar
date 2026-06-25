#!/usr/bin/env node
/**
 * Public marketing mockups must use synthetic telemetry. This gate keeps
 * real-looking session names, large burn totals, and live-capture claims out
 * of source and built HTML without storing private source examples here.
 */

import assert from "node:assert/strict";
import { existsSync, readFileSync } from "node:fs";
import { dirname, join, relative } from "node:path";
import { fileURLToPath } from "node:url";

const HERE = dirname(fileURLToPath(import.meta.url));
const ROOT = join(HERE, "..");
const DIST = join(ROOT, "dist");

const SOURCE_FILES = [
  "src/components/BarMockup.astro",
  "src/components/DeviceShowcase.astro",
  "src/components/RealDashboard.astro",
  "src/pages/index.astro",
  "src/pages/product.astro",
];

const BUILT_SECTIONS = [
  {
    page: "index.html",
    sections: [
      {
        label: "home menu-bar mockup",
        start: 'class="bar-mockup"',
        end: "</figure>",
        markers: [/synthetic demo data/i, /Demo Workspace/i],
      },
      {
        label: "home dashboard mockup",
        start: 'class="dashshow"',
        end: "</section>",
        markers: [/synthetic demo data/i],
      },
      {
        label: "home device showcase",
        start: 'class="devices"',
        end: "</section>",
        markers: [/synthetic/i, /sample/i],
      },
    ],
  },
  {
    page: "product/index.html",
    sections: [
      {
        label: "product dashboard mockups",
        start: 'class="container container--wide prodshots"',
        end: "</section>",
        markers: [/synthetic demo data/i],
      },
    ],
  },
];

const SYNTHETIC_MARKERS = new Map([
  ["src/components/BarMockup.astro", [/Synthetic demo/i, /Demo Workspace/i]],
  ["src/components/DeviceShowcase.astro", [/synthetic/i, /sample/i]],
  ["src/components/RealDashboard.astro", [/synthetic demo data/i]],
  ["src/pages/index.astro", [/synthetic demo data/i]],
  ["src/pages/product.astro", [/synthetic demo data/i]],
]);

const LIVE_CAPTURE_CLAIMS = [
  String.raw`captured\s+live\s+from\s+the\s+installed\s+app`,
  String.raw`live\s+data\s+captured`,
  String.raw`real\s+quota\s+windows`,
  String.raw`real\s+burn\s+telemetry`,
  String.raw`real\s+iPadOS\s+capture`,
  String.raw`streaming\s+live\s+from\s+your\s+Mac`,
  String.raw`captured\s+\d{4}-\d{2}-\d{2}`,
  String.raw`actual\s+iPadOS\s+app`,
].join("|");

const BANNED = [
  [/\$\d{1,3},\d{3}(?:\.\d{2})?|\$\d{4,}(?:\.\d{2})?/, "large public currency total"],
  [/\b\d{1,3},\d{3}\b/, "comma-formatted public telemetry count"],
  [/\b\d+(?:\.\d+)?B(?:\s+(?:tokens?|requests?)|\b)/i, "billion-scale public telemetry total"],
  [new RegExp(LIVE_CAPTURE_CLAIMS, "i"), "live-capture or real-data claim"],
];

function checkText(label, text) {
  for (const [pattern, reason] of BANNED) {
    const match = text.match(pattern);
    assert.ok(!match, `${label} contains ${reason}: ${JSON.stringify(match?.[0])}`);
  }
}

function extractSection(pageLabel, html, section) {
  const start = html.indexOf(section.start);
  assert.ok(start >= 0, `${pageLabel} must render ${section.label}`);
  const end = html.indexOf(section.end, start);
  assert.ok(end > start, `${pageLabel} must close ${section.label}`);
  return html.slice(start, end + section.end.length);
}

for (const rel of SOURCE_FILES) {
  const file = join(ROOT, rel);
  assert.ok(existsSync(file), `${rel} must exist`);
  const text = readFileSync(file, "utf8");
  checkText(rel, text);

  for (const marker of SYNTHETIC_MARKERS.get(rel) ?? []) {
    assert.ok(marker.test(text), `${rel} must explicitly mark public telemetry as demo/synthetic`);
  }
}

let builtFiles = 0;
if (existsSync(DIST)) {
  for (const page of BUILT_SECTIONS) {
    const file = join(DIST, page.page);
    assert.ok(existsSync(file), `expected built page ${relative(ROOT, file)}`);
    builtFiles++;
    const html = readFileSync(file, "utf8");
    for (const section of page.sections) {
      const text = extractSection(page.page, html, section);
      checkText(`${page.page} ${section.label}`, text);
      for (const marker of section.markers) {
        assert.ok(marker.test(text), `${page.page} ${section.label} must render synthetic/demo copy`);
      }
    }
  }
}

console.log(
  `✓ public demo telemetry copy: ${SOURCE_FILES.length} source files clean${
    builtFiles ? `, ${builtFiles} built HTML files clean` : ""
  }.`
);
