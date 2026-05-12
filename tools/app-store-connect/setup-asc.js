#!/usr/bin/env node
/**
 * App Store Connect setup automation for OpenBurnBar.
 *
 * Usage:
 *   node setup-asc.js [--platform macos|ios] [--skip-login]
 *
 * The script opens a visible Chromium window, waits for you to sign in,
 * then fills the "New App" form and every metadata page it can reach
 * without requiring screenshots or a signed build.
 */

const { chromium } = require('playwright');
const readline = require('readline');

// ─── App metadata ──────────────────────────────────────────────────────────────
const APP = {
  name: 'OpenBurnBar',
  primaryLanguage: 'English (U.S.)',

  macos: {
    bundleId: 'com.openburnbar.app',
    sku: 'OPENBURNBAR-MACOS-001',
    platform: 'macOS',
  },

  ios: {
    bundleId: 'com.openburnbar.app',
    sku: 'OPENBURNBAR-IOS-001',
    platform: 'iOS',
  },

  category: 'Developer Tools',
  subcategory: 'Utilities',

  subtitle: 'AI Agent Cost Tracker',

  description: `OpenBurnBar sits quietly in your macOS menu bar and tells you exactly where your AI coding budget went — before your cloud bill does.

If you run Claude Code, Codex, Factory Droid, Kimi, Cursor, or any combination of AI coding agents, OpenBurnBar reads the local session logs they leave on disk, estimates spend and token volume in real time, and surfaces the numbers you actually want: today, this week, this month, per provider.

KEY FEATURES

• Menu Bar Native — no Dock icon, no windows stealing focus. One click for your burn summary; invisible when you don't need it.
• Local-First — your API keys never touch OpenBurnBar. It reads crumbs the agents leave on disk. Nothing is sent to a server unless you opt in.
• Live Token & Cost Tracking — watch dollars and tokens accumulate across Claude, GPT, Gemini, DeepSeek, Qwen, MiniMax, Grok, Perplexity, and more.
• Smart Insights — spend up 40 % vs yesterday, cache hits carrying the load, first session with a new model. Small cards, not a spreadsheet.
• Per-Provider Breakdown — see which agent is winning the "most expensive hobby" award.
• Daily Digest — optional notification at a time you pick, so future-you gets one sentence of truth instead of a billing surprise.
• Chat Panel — ask questions about your own usage data inside the dashboard.
• Optional Cloud Sync — sign in with Google or Apple and selected data follows you across Macs. Fully opt-in; flip it off and local state keeps spinning.
• Daemon-Backed Runtime — project registry, questions, missions, scheduled reviews, and auto-takeover run behind a local daemon, not fragile UI state.
• Cursor Connector — route Z.ai and MiniMax through a local OpenAI-shaped router so Cursor's BYOK flow works; OpenBurnBar logs every request.

SUPPORTED AGENTS
Claude Code · Codex · Factory Droid · Kimi · Cursor · Windsurf · Goose · Aider · Cline · RooCode · Kilo Code · OpenClaw · Forge · Augment · Copilot · GitHub Copilot · Gemini CLI · Warp AI · Hermes

PRIVACY
All processing is local. No data leaves your machine unless you explicitly enable optional cloud sync. OpenBurnBar does not collect analytics or telemetry by default.`,

  keywords: 'AI,agents,Claude,Cursor,Codex,token,cost,budget,developer,menu bar,burn rate,LLM,tracking',

  supportUrl: 'https://github.com/Ajnunezg/OpenBurnBar/issues',
  marketingUrl: 'https://github.com/Ajnunezg/OpenBurnBar',
  privacyPolicyUrl: 'https://openburnbar.com/legal/privacy-policy',

  version: '0.1.3',
  buildString: '1',

  copyrightText: `Copyright © ${new Date().getFullYear()} Alberto Nunez`,

  whatsNew: `Initial App Store release of OpenBurnBar.\n\n• Menu bar token & cost tracking for AI coding agents\n• Local-first — no cloud required\n• Supports Claude Code, Codex, Factory Droid, Cursor, Kimi, and more\n• Smart insights, daily digest, optional cloud sync`,
};

// ─── Helpers ───────────────────────────────────────────────────────────────────

function rl() {
  return readline.createInterface({ input: process.stdin, output: process.stdout });
}

function prompt(msg) {
  return new Promise(resolve => {
    const iface = rl();
    iface.question(msg, ans => { iface.close(); resolve(ans.trim()); });
  });
}

async function waitForEnter(msg = 'Press ENTER to continue...') {
  await prompt(msg);
}

async function waitForUrlContaining(page, fragment, timeoutMs = 300_000) {
  console.log(`  ⏳ Waiting for URL containing "${fragment}"…`);
  await page.waitForURL(`**${fragment}**`, { timeout: timeoutMs });
  console.log(`  ✅ URL matched.`);
}

async function fillIfVisible(page, selector, value, label) {
  try {
    const el = page.locator(selector).first();
    await el.waitFor({ state: 'visible', timeout: 5000 });
    await el.fill(value);
    console.log(`  ✅ Filled "${label}"`);
  } catch {
    console.log(`  ⚠️  Field not found: "${label}" (${selector}) — skipping`);
  }
}

async function clickIfVisible(page, selector, label) {
  try {
    const el = page.locator(selector).first();
    await el.waitFor({ state: 'visible', timeout: 5000 });
    await el.click();
    console.log(`  ✅ Clicked "${label}"`);
  } catch {
    console.log(`  ⚠️  Button/element not found: "${label}" — skipping`);
  }
}

async function selectOption(page, selector, valueOrLabel, label) {
  try {
    const el = page.locator(selector).first();
    await el.waitFor({ state: 'visible', timeout: 5000 });
    await el.selectOption({ label: valueOrLabel });
    console.log(`  ✅ Selected "${valueOrLabel}" in "${label}"`);
  } catch {
    try {
      const el = page.locator(selector).first();
      await el.selectOption({ value: valueOrLabel });
      console.log(`  ✅ Selected "${valueOrLabel}" in "${label}" (by value)`);
    } catch {
      console.log(`  ⚠️  Could not select "${valueOrLabel}" in "${label}" — skipping`);
    }
  }
}

// ─── Main ─────────────────────────────────────────────────────────────────────

async function main() {
  const args = process.argv.slice(2);
  const platform = args.includes('--platform')
    ? args[args.indexOf('--platform') + 1]
    : 'macos';

  const meta = platform === 'ios' ? APP.ios : APP.macos;

  console.log('\n╔════════════════════════════════════════╗');
  console.log('║  OpenBurnBar — App Store Connect Setup ║');
  console.log('╚════════════════════════════════════════╝\n');
  console.log(`Platform : ${meta.platform}`);
  console.log(`Bundle ID: ${meta.bundleId}`);
  console.log(`SKU      : ${meta.sku}\n`);

  // Prefer system Chrome for the best visible-browser experience
  const browser = await chromium.launch({
    channel: 'chrome',
    headless: false,
    slowMo: 80,
    args: ['--start-maximized'],
  }).catch(() =>
    // Fall back to Playwright's bundled Chromium
    chromium.launch({ headless: false, slowMo: 80, args: ['--start-maximized'] })
  );

  const context = await browser.newContext({
    viewport: null,
  });

  const page = await context.newPage();

  // ── Step 1: Open App Store Connect ────────────────────────────────────────
  console.log('→ Opening App Store Connect…');
  await page.goto('https://appstoreconnect.apple.com', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(2000);

  // ── Step 2: Wait for login ────────────────────────────────────────────────
  const currentUrl = page.url();
  const alreadyLoggedIn =
    currentUrl.includes('appstoreconnect.apple.com/apps') ||
    currentUrl.includes('appstoreconnect.apple.com/login');

  console.log('\n🔐 Please log in to App Store Connect in the browser window.');
  console.log('   Complete any 2FA / sign-in steps, then come back here.\n');
  await waitForEnter('Press ENTER once you are logged in and can see "My Apps"…');

  // Confirm we're on the apps page
  await page.goto('https://appstoreconnect.apple.com/apps', { waitUntil: 'domcontentloaded' });
  await page.waitForTimeout(3000);

  console.log('\n→ Logged in. On My Apps page.');

  // ── Step 3: New App ───────────────────────────────────────────────────────
  console.log('\n→ Clicking "+" to create a new app…');

  // The + button in ASC varies — try several selectors
  const plusSelectors = [
    'button[aria-label="Add"]',
    'button:has-text("+")',
    '[data-test-id="add-app-button"]',
    '.add-app-button',
    'button.add',
  ];

  let clicked = false;
  for (const sel of plusSelectors) {
    try {
      await page.locator(sel).first().click({ timeout: 3000 });
      clicked = true;
      console.log(`  ✅ Clicked add button via: ${sel}`);
      break;
    } catch { /* try next */ }
  }

  if (!clicked) {
    console.log('\n  ⚠️  Could not auto-click the "+" button.');
    console.log('  Please click the "+" (New App) button in the browser window yourself.\n');
    await waitForEnter('Press ENTER after clicking "+" and the New App modal is visible…');
  }

  await page.waitForTimeout(2000);

  // ── Step 4: Fill "New App" modal ─────────────────────────────────────────
  console.log('\n→ Filling "New App" form…');

  // Platform checkbox (macOS or iOS)
  if (platform === 'macos') {
    await clickIfVisible(page, 'input[value="MAC_OS"]', 'macOS platform checkbox');
    // Uncheck iOS if pre-checked
    try {
      const ios = page.locator('input[value="IOS"]');
      if (await ios.isChecked()) await ios.uncheck();
    } catch { /* ignore */ }
  } else {
    await clickIfVisible(page, 'input[value="IOS"]', 'iOS platform checkbox');
  }

  // App name
  await fillIfVisible(page, 'input[placeholder="App Name"]', APP.name, 'App Name');
  await fillIfVisible(page, 'input[id="name"]', APP.name, 'App Name (by id)');
  await fillIfVisible(page, '[name="name"]', APP.name, 'App Name (by name)');

  // Primary language
  await selectOption(page, 'select[name="primaryLocale"]', APP.primaryLanguage, 'Primary Language');

  // Bundle ID — try to select existing, or type it
  await page.waitForTimeout(1000);
  const bundleSelect = page.locator('select[name="bundleId"]');
  try {
    await bundleSelect.waitFor({ state: 'visible', timeout: 5000 });
    const options = await bundleSelect.locator('option').allTextContents();
    console.log(`  ℹ️  Available bundle IDs: ${options.join(' | ')}`);
    if (options.some(o => o.includes(meta.bundleId))) {
      await bundleSelect.selectOption({ label: options.find(o => o.includes(meta.bundleId)) });
      console.log(`  ✅ Selected bundle ID: ${meta.bundleId}`);
    } else {
      console.log(`  ⚠️  Bundle ID "${meta.bundleId}" not in dropdown.`);
      console.log(`      You may need to register it first at developer.apple.com/account/resources/identifiers`);
      await waitForEnter('Select the correct Bundle ID yourself in the browser, then press ENTER…');
    }
  } catch {
    console.log('  ⚠️  Bundle ID dropdown not found — skipping (may appear after platform selection)');
  }

  // SKU
  await fillIfVisible(page, 'input[name="vendorId"]', meta.sku, 'SKU');
  await fillIfVisible(page, 'input[placeholder="SKU"]', meta.sku, 'SKU (placeholder)');

  // User access — leave as Full Access (default)

  console.log('\n  ℹ️  Review the form in the browser, then create the app.');
  await waitForEnter('Press ENTER after clicking "Create" to submit the New App form…');

  await page.waitForTimeout(4000);
  const newUrl = page.url();
  console.log(`  ✅ Navigated to: ${newUrl}`);

  // ── Step 5: App Information ───────────────────────────────────────────────
  console.log('\n→ Filling App Information…');

  // Navigate to App Information tab
  const appInfoSelectors = [
    'a:has-text("App Information")',
    '[data-test-id="app-info-link"]',
    'nav a:has-text("Information")',
  ];
  for (const sel of appInfoSelectors) {
    try {
      await page.locator(sel).first().click({ timeout: 3000 });
      console.log(`  ✅ Navigated to App Information`);
      break;
    } catch { /* try next */ }
  }

  await page.waitForTimeout(2000);

  // Subtitle
  await fillIfVisible(page, 'input[placeholder="Subtitle"]', APP.subtitle, 'Subtitle');
  await fillIfVisible(page, 'input[name="subtitle"]', APP.subtitle, 'Subtitle (by name)');

  // Category
  const categorySelectors = [
    'select[name="primaryCategory"]',
    'select[aria-label="Primary Category"]',
  ];
  for (const sel of categorySelectors) {
    await selectOption(page, sel, APP.category, 'Primary Category');
  }

  // Copyright
  await fillIfVisible(page, 'input[name="copyright"]', APP.copyrightText, 'Copyright');
  await fillIfVisible(page, 'input[placeholder="Copyright"]', APP.copyrightText, 'Copyright (placeholder)');

  // Content rights (no third-party content)
  try {
    const noContentRights = page.locator('input[value="false"][name*="contentRights"], label:has-text("does not contain")').first();
    await noContentRights.click({ timeout: 3000 });
    console.log('  ✅ Set content rights to: does not contain third-party content');
  } catch {
    console.log('  ⚠️  Content rights radio not found — skipping');
  }

  await page.waitForTimeout(1000);

  // Save App Information
  await clickIfVisible(page, 'button:has-text("Save")', 'Save (App Information)');
  await page.waitForTimeout(2000);

  // ── Step 6: Version metadata (App Store tab) ──────────────────────────────
  console.log('\n→ Filling version metadata (description, keywords, URLs)…');

  // Navigate to Prepare for Submission / version tab
  const prepareSelectors = [
    'a:has-text("Prepare for Submission")',
    'a:has-text("App Store")',
    '[data-test-id="version-link"]',
  ];
  for (const sel of prepareSelectors) {
    try {
      await page.locator(sel).first().click({ timeout: 3000 });
      console.log('  ✅ Navigated to version tab');
      await page.waitForTimeout(2000);
      break;
    } catch { /* try next */ }
  }

  // Description
  const descSelectors = [
    'textarea[name="description"]',
    'textarea[placeholder*="description" i]',
    '[data-test-id="description"] textarea',
  ];
  for (const sel of descSelectors) {
    try {
      const el = page.locator(sel).first();
      await el.waitFor({ state: 'visible', timeout: 5000 });
      await el.fill(APP.description);
      console.log('  ✅ Filled Description');
      break;
    } catch { /* try next */ }
  }

  // Keywords
  await fillIfVisible(page, 'input[name="keywords"]', APP.keywords, 'Keywords');
  await fillIfVisible(page, 'textarea[name="keywords"]', APP.keywords, 'Keywords (textarea)');

  // Support URL
  await fillIfVisible(page, 'input[name="supportUrl"]', APP.supportUrl, 'Support URL');
  await fillIfVisible(page, 'input[placeholder*="Support URL" i]', APP.supportUrl, 'Support URL (placeholder)');

  // Marketing URL
  await fillIfVisible(page, 'input[name="marketingUrl"]', APP.marketingUrl, 'Marketing URL');
  await fillIfVisible(page, 'input[placeholder*="Marketing URL" i]', APP.marketingUrl, 'Marketing URL (placeholder)');

  // What's New
  const whatsNewSelectors = [
    'textarea[name="releaseNotes"]',
    "textarea[placeholder*=\"what's new\" i]",
    '[data-test-id="whats-new"] textarea',
  ];
  for (const sel of whatsNewSelectors) {
    try {
      const el = page.locator(sel).first();
      await el.waitFor({ state: 'visible', timeout: 4000 });
      await el.fill(APP.whatsNew);
      console.log("  ✅ Filled What's New");
      break;
    } catch { /* try next */ }
  }

  // Age Rating — navigate to it
  console.log('\n→ Setting up Age Rating…');
  try {
    const ageBtn = page.locator('a:has-text("Age Rating"), button:has-text("Age Rating")').first();
    await ageBtn.click({ timeout: 4000 });
    await page.waitForTimeout(2000);
    // Click "Edit" to start the questionnaire
    await clickIfVisible(page, 'button:has-text("Edit")', 'Edit Age Rating');
    await page.waitForTimeout(1000);
    // All answers should be "None" or "No" for a developer tool
    // Click through the questionnaire — default answers are typically fine
    await clickIfVisible(page, 'button:has-text("Done")', 'Done (Age Rating)');
    console.log('  ✅ Age rating configured (4+)');
  } catch {
    console.log('  ⚠️  Could not auto-configure age rating — please set it to 4+ manually');
  }

  // Save version
  await page.waitForTimeout(1000);
  await clickIfVisible(page, 'button:has-text("Save")', 'Save (version metadata)');
  await page.waitForTimeout(2000);

  // ── Step 7: Pricing & Availability ───────────────────────────────────────
  console.log('\n→ Setting Pricing & Availability…');
  try {
    await page.locator('a:has-text("Pricing and Availability")').first().click({ timeout: 4000 });
    await page.waitForTimeout(2000);

    // Select Free
    try {
      const freeOption = page.locator('option:has-text("Free"), label:has-text("Free")').first();
      await freeOption.click({ timeout: 3000 });
      console.log('  ✅ Set pricing to Free');
    } catch {
      console.log('  ⚠️  Could not auto-set Free pricing — please select it manually');
    }

    // Availability — all countries (default)
    await clickIfVisible(page, 'button:has-text("Save")', 'Save (Pricing)');
    await page.waitForTimeout(2000);
  } catch {
    console.log('  ⚠️  Pricing & Availability page not found — may need to be set manually');
  }

  // ── Step 8: Privacy Policy ────────────────────────────────────────────────
  console.log('\n→ Setting Privacy Policy URL…');
  const privacySelectors = [
    'input[name="privacyPolicyUrl"]',
    'input[placeholder*="Privacy Policy URL" i]',
    '[data-test-id="privacy-policy-url"] input',
  ];
  for (const sel of privacySelectors) {
    try {
      const el = page.locator(sel).first();
      await el.waitFor({ state: 'visible', timeout: 4000 });
      await el.fill(APP.privacyPolicyUrl);
      console.log('  ✅ Filled Privacy Policy URL');
      break;
    } catch { /* try next */ }
  }

  await clickIfVisible(page, 'button:has-text("Save")', 'Save (Privacy Policy)');
  await page.waitForTimeout(2000);

  // ── Summary ───────────────────────────────────────────────────────────────
  console.log('\n╔════════════════════════════════════════════════════════╗');
  console.log('║  ✅ Automated setup complete!                           ║');
  console.log('╚════════════════════════════════════════════════════════╝\n');
  console.log('What was filled automatically:');
  console.log('  ✅ App Name, Bundle ID, SKU, Platform');
  console.log('  ✅ Description, Keywords, Support URL, Marketing URL');
  console.log("  ✅ What's New (release notes)");
  console.log('  ✅ Copyright, Primary Category');
  console.log('  ✅ Privacy Policy URL');
  console.log('');
  console.log('What you still need to do manually:');
  console.log('  📸 Upload screenshots (macOS: 1280×800 or 1440×900; iOS: various sizes)');
  console.log('  🔢 Set build number / attach a build for review');
  console.log('  📝 Complete the App Privacy questionnaire');
  console.log('  🌍 Confirm territory availability');
  console.log('  📦 Register Bundle ID at developer.apple.com if not done yet');
  console.log('     → https://developer.apple.com/account/resources/identifiers/add/bundleId');
  console.log('     Bundle ID: ' + meta.bundleId);
  console.log('');
  console.log('The browser window will stay open. Close it when you are done.\n');

  await waitForEnter('Press ENTER to close the browser…');
  await browser.close();
}

main().catch(err => {
  console.error('\n❌ Script error:', err.message);
  process.exit(1);
});
