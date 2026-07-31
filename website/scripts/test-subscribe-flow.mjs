#!/usr/bin/env node
import assert from "node:assert/strict";
import { readFile } from "node:fs/promises";
import path from "node:path";
import { fileURLToPath } from "node:url";

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "..");
const read = (relativePath) => readFile(path.join(root, relativePath), "utf8");

const [subscribe, layout, consent] = await Promise.all([
  read("src/pages/subscribe.astro"),
  read("src/layouts/BaseLayout.astro"),
  read("src/components/ConsentBanner.astro")
]);

assert.match(
  subscribe,
  /<BaseLayout[\s\S]*\btransactional\b[\s\S]*>/,
  "subscribe must mark itself as a transactional page"
);
assert.match(
  layout,
  /<body data-transactional-page=\{transactional \? "" : undefined\}>/,
  "transactional layouts must expose a body marker"
);
assert.match(
  consent,
  /document\.body\.hasAttribute\("data-transactional-page"\)/,
  "consent banner must detect transactional pages"
);
assert.match(
  consent,
  /else if \(!suppressInitialPrompt\) \{\s*show\(\);/,
  "first-visit consent must stay hidden on transactional pages"
);
assert.match(
  consent,
  /document\.querySelectorAll\("\[data-analytics-manage\]"\)[\s\S]*show\(true\)/,
  "explicit analytics management must still reopen the banner"
);

for (const token of [
  "--checkout-text-bright",
  "--checkout-text-base",
  "--checkout-text-mute",
  "--checkout-text-dim",
  "--checkout-line"
]) {
  assert.match(subscribe, new RegExp(token), `${token} must be defined for the dark checkout panel`);
}
assert.match(
  subscribe,
  /\.plan-summary h2,[\s\S]*color: var\(--checkout-text-bright\)/,
  "plan and state headings must use explicit dark-panel text"
);
assert.match(
  subscribe,
  /\.plan-summary p,[\s\S]*color: var\(--checkout-text-mute\)/,
  "plan and state copy must use explicit dark-panel text"
);
assert.match(
  subscribe,
  /\.checkout-trust \{[\s\S]*color: var\(--checkout-text-dim\)/,
  "trust copy must stay readable in either site theme"
);

console.log("subscribe-flow: transactional consent and dark-panel contrast assertions passed");
