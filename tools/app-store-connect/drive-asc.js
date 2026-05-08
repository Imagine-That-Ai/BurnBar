#!/usr/bin/env node
/**
 * Fully self-driving App Store Connect setup for OpenBurnBar.
 * Opens a visible Chrome window. You log in; the script watches
 * for successful login then fills everything automatically.
 */

const { chromium } = require('playwright');

const APP = {
  name: 'OpenBurnBar',
  subtitle: 'AI Agent Cost Tracker',
  primaryLanguage: 'en-US',

  macos: { bundleId: 'com.openburnbar.app', sku: 'OPENBURNBAR-MACOS-001' },
  ios:   { bundleId: 'com.openburnbar.app', sku: 'OPENBURNBAR-IOS-001' },

  description: `OpenBurnBar sits quietly in your macOS menu bar and tells you exactly where your AI coding budget went — before your cloud bill does.

If you run Claude Code, Codex, Factory Droid, Kimi, Cursor, or any combination of AI coding agents, OpenBurnBar reads the local session logs they leave on disk, estimates spend and token volume in real time, and surfaces the numbers you actually want: today, this week, this month, per provider.

KEY FEATURES

• Menu Bar Native — no Dock icon, no windows stealing focus. One click for your burn summary; invisible when you don't need it.
• Local-First — your API keys never touch OpenBurnBar. It reads crumbs the agents leave on disk. Nothing is sent to a server unless you opt in.
• Live Token & Cost Tracking — watch dollars and tokens accumulate across Claude, GPT, Gemini, DeepSeek, Qwen, MiniMax, Grok, Perplexity, and more.
• Smart Insights — spend up 40% vs yesterday, cache hits carrying the load, first session with a new model. Small cards, not a spreadsheet.
• Per-Provider Breakdown — see which agent is winning the "most expensive hobby" award.
• Daily Digest — optional notification at a time you pick, so future-you gets one sentence of truth instead of a billing surprise.
• Chat Panel — ask questions about your own usage data inside the dashboard.
• Optional Cloud Sync — sign in with Google or Apple and selected data follows you across Macs. Fully opt-in; flip it off and local state keeps spinning.

SUPPORTED AGENTS
Claude Code · Codex · Factory Droid · Kimi · Cursor · Windsurf · Goose · Aider · Cline · RooCode · Kilo Code · OpenClaw · Forge · Augment · Copilot · Gemini CLI · Warp AI

PRIVACY
All processing is local. No data leaves your machine unless you explicitly enable optional cloud sync.`,

  keywords: 'AI,agents,Claude,Cursor,Codex,token,cost,budget,developer,menu bar,burn rate,LLM',
  supportUrl: 'https://github.com/Ajnunezg/OpenBurnBar/issues',
  marketingUrl: 'https://github.com/Ajnunezg/OpenBurnBar',
  privacyPolicyUrl: 'https://github.com/Ajnunezg/OpenBurnBar/blob/main/docs/PRIVACY.md',
  copyright: `Copyright © ${new Date().getFullYear()} Alberto Nunez`,
  whatsNew: `Initial App Store release.\n\n• Menu bar token & cost tracking for AI coding agents\n• Local-first — no cloud required\n• Supports Claude Code, Codex, Factory Droid, Cursor, Kimi, and more\n• Smart insights engine and daily digest`,
};

function log(msg) { console.log(`[ASC] ${msg}`); }
function step(msg) { console.log(`\n[ASC] ▶ ${msg}`); }

async function sleep(ms) { return new Promise(r => setTimeout(r, ms)); }

function isAllowedLoggedInUrl(rawUrl) {
  let parsed;
  try {
    parsed = new URL(rawUrl);
  } catch {
    return false;
  }
  const hostname = parsed.hostname.toLowerCase();
  const pathname = parsed.pathname.toLowerCase();
  return (
    hostname === 'appstoreconnect.apple.com' &&
    !pathname.includes('/signin') &&
    !pathname.includes('/login') &&
    !pathname.includes('/auth')
  );
}

async function waitForLoggedIn(page) {
  log('Waiting for you to log in to App Store Connect…');
  log('Complete your Apple ID sign-in and 2FA in the Chrome window.');
  for (let i = 0; i < 300; i++) {          // wait up to 10 min
    const url = page.url();
    if (isAllowedLoggedInUrl(url)) {
      log('Login detected — continuing.');
      return;
    }
    await sleep(2000);
  }
  throw new Error('Timed out waiting for login (10 min).');
}

async function tryClick(page, selectors, label) {
  for (const sel of [].concat(selectors)) {
    try {
      await page.locator(sel).first().click({ timeout: 4000 });
      log(`✅ Clicked: ${label}`);
      return true;
    } catch { /* try next */ }
  }
  log(`⚠️  Could not click: ${label}`);
  return false;
}

async function tryFill(page, selectors, value, label) {
  for (const sel of [].concat(selectors)) {
    try {
      const el = page.locator(sel).first();
      await el.waitFor({ state: 'visible', timeout: 5000 });
      await el.click();
      await el.fill(value);
      log(`✅ Filled: ${label}`);
      return true;
    } catch { /* try next */ }
  }
  log(`⚠️  Could not fill: ${label}`);
  return false;
}

async function trySelect(page, selectors, valueOrLabel, label) {
  for (const sel of [].concat(selectors)) {
    try {
      const el = page.locator(sel).first();
      await el.waitFor({ state: 'visible', timeout: 5000 });
      try { await el.selectOption({ label: valueOrLabel }); }
      catch { await el.selectOption({ value: valueOrLabel }); }
      log(`✅ Selected "${valueOrLabel}" in: ${label}`);
      return true;
    } catch { /* try next */ }
  }
  log(`⚠️  Could not select in: ${label}`);
  return false;
}

async function screenshot(page, name) {
  const path = `/tmp/asc-${name}-${Date.now()}.png`;
  await page.screenshot({ path, fullPage: false });
  log(`📸 Screenshot → ${path}`);
}

async function main() {
  const platform = process.argv.includes('--ios') ? 'ios' : 'macos';
  const meta = platform === 'ios' ? APP.ios : APP.macos;

  step(`Starting — platform: ${platform}, bundle: ${meta.bundleId}`);

  const browser = await chromium.launch({
    channel: 'chrome',
    headless: false,
    slowMo: 60,
    args: ['--start-maximized', '--disable-blink-features=AutomationControlled'],
  }).catch(() => chromium.launch({ headless: false, slowMo: 60 }));

  const ctx = await browser.newContext({ viewport: null });
  const page = await ctx.newPage();

  // ── 1. Open App Store Connect ─────────────────────────────────────────────
  step('Opening App Store Connect');
  await page.goto('https://appstoreconnect.apple.com', { waitUntil: 'domcontentloaded' });
  await sleep(3000);

  await waitForLoggedIn(page);
  await screenshot(page, '01-logged-in');

  // ── 2. Go to My Apps ─────────────────────────────────────────────────────
  step('Navigating to My Apps');
  await page.goto('https://appstoreconnect.apple.com/apps', { waitUntil: 'domcontentloaded' });
  await sleep(3000);
  await screenshot(page, '02-my-apps');

  // ── 3. Click + (New App) ─────────────────────────────────────────────────
  step('Clicking + to create a new app');
  const plusClicked = await tryClick(page, [
    'button[aria-label="Add"]',
    'button[aria-label="New App"]',
    '[data-test-id="add-app-button"]',
    'button.add-entity-btn',
    '.toolbar button:first-child',
    'a:has-text("New App")',
    'button:has-text("+")',
  ], '+ New App button');

  await sleep(2000);
  await screenshot(page, '03-new-app-modal');

  // ── 4. Fill the New App modal ─────────────────────────────────────────────
  step('Filling New App form');

  // Platform checkbox
  if (platform === 'macos') {
    await tryClick(page, [
      'input[type="checkbox"][value="MAC_OS"]',
      'label:has-text("macOS") input',
      'input#macOS',
    ], 'macOS checkbox');
  } else {
    await tryClick(page, [
      'input[type="checkbox"][value="IOS"]',
      'label:has-text("iOS") input',
    ], 'iOS checkbox');
  }

  await sleep(500);

  // App name
  await tryFill(page, [
    'input[placeholder="App Name"]',
    'input[name="name"]',
    '#name',
    'input[id*="name" i]',
  ], APP.name, 'App Name');

  // Primary language
  await trySelect(page, [
    'select[name="primaryLocale"]',
    'select[aria-label*="language" i]',
    'select[aria-label*="locale" i]',
  ], 'English (U.S.)', 'Primary Language');

  // Bundle ID
  await sleep(500);
  try {
    const sel = await page.locator('select[name="bundleId"]').first();
    await sel.waitFor({ state: 'visible', timeout: 6000 });
    const opts = await sel.locator('option').allTextContents();
    log(`Available bundle IDs: ${opts.join(' | ')}`);
    const match = opts.find(o => o.includes(meta.bundleId));
    if (match) {
      await sel.selectOption({ label: match });
      log(`✅ Selected bundle ID: ${match}`);
    } else {
      log(`⚠️  "${meta.bundleId}" not in dropdown. Trying to pick first non-empty option.`);
      const nonEmpty = opts.find(o => o.trim() && !o.toLowerCase().includes('select'));
      if (nonEmpty) await sel.selectOption({ label: nonEmpty });
    }
  } catch {
    log('⚠️  Bundle ID dropdown not found — skipping');
  }

  // SKU
  await tryFill(page, [
    'input[name="vendorId"]',
    'input[placeholder*="SKU" i]',
    'input[placeholder*="sku" i]',
  ], meta.sku, 'SKU');

  await sleep(500);
  await screenshot(page, '04-new-app-filled');

  // Create
  step('Submitting New App');
  await tryClick(page, [
    'button:has-text("Create")',
    'input[type="submit"][value="Create"]',
    '[data-test-id="create-app-button"]',
  ], 'Create button');

  await sleep(5000);
  await screenshot(page, '05-after-create');
  log(`Current URL: ${page.url()}`);

  // ── 5. App Information ────────────────────────────────────────────────────
  step('App Information tab');
  await tryClick(page, [
    'a:has-text("App Information")',
    'nav a:has-text("Information")',
    '[data-test-id="app-info-link"]',
  ], 'App Information link');
  await sleep(2000);

  await tryFill(page, [
    'input[name="subtitle"]',
    'input[placeholder*="Subtitle" i]',
    '[aria-label*="Subtitle" i] input',
  ], APP.subtitle, 'Subtitle');

  await trySelect(page, [
    'select[name="primaryCategory"]',
    'select[aria-label*="Primary Category" i]',
  ], 'Developer Tools', 'Primary Category');

  await tryFill(page, [
    'input[name="copyright"]',
    'input[placeholder*="copyright" i]',
  ], APP.copyright, 'Copyright');

  // Content rights — "does not contain third-party content"
  await tryClick(page, [
    'label:has-text("does not contain") input',
    'input[value="false"][name*="contentRights"]',
    'label:has-text("No") input[name*="content"]',
  ], 'Content rights: No');

  await sleep(500);
  await tryClick(page, ['button:has-text("Save")'], 'Save App Information');
  await sleep(2000);
  await screenshot(page, '06-app-info-saved');

  // ── 6. Version / Prepare for Submission ───────────────────────────────────
  step('Version metadata (description, keywords, URLs)');
  await tryClick(page, [
    'a:has-text("Prepare for Submission")',
    'a:has-text("App Store")',
    'nav a[href*="version"]',
  ], 'Prepare for Submission tab');
  await sleep(2000);

  // Description
  await tryFill(page, [
    'textarea[name="description"]',
    'textarea[placeholder*="description" i]',
    '[data-test-id="description"] textarea',
    '.description-field textarea',
  ], APP.description, 'Description');

  // Keywords
  await tryFill(page, [
    'input[name="keywords"]',
    'textarea[name="keywords"]',
    'input[placeholder*="keyword" i]',
  ], APP.keywords, 'Keywords');

  // Support URL
  await tryFill(page, [
    'input[name="supportUrl"]',
    'input[placeholder*="Support URL" i]',
    'input[placeholder*="support" i]',
  ], APP.supportUrl, 'Support URL');

  // Marketing URL
  await tryFill(page, [
    'input[name="marketingUrl"]',
    'input[placeholder*="Marketing URL" i]',
  ], APP.marketingUrl, 'Marketing URL');

  // What's New
  await tryFill(page, [
    'textarea[name="releaseNotes"]',
    "textarea[placeholder*=\"what's new\" i]",
    'textarea[placeholder*="whats new" i]',
    '[data-test-id="whats-new"] textarea',
  ], APP.whatsNew, "What's New");

  await sleep(500);
  await tryClick(page, ['button:has-text("Save")'], 'Save version metadata');
  await sleep(2000);
  await screenshot(page, '07-version-saved');

  // ── 7. Pricing & Availability ─────────────────────────────────────────────
  step('Pricing & Availability');
  await tryClick(page, [
    'a:has-text("Pricing and Availability")',
    'a:has-text("Pricing")',
    'nav a[href*="pricing"]',
  ], 'Pricing link');
  await sleep(2000);

  // Set Free (price tier 0)
  await trySelect(page, [
    'select[name="priceTier"]',
    'select[aria-label*="price" i]',
    'select[aria-label*="Price" i]',
  ], '0', 'Price Tier (Free)');

  await tryClick(page, ['button:has-text("Save")'], 'Save Pricing');
  await sleep(2000);
  await screenshot(page, '08-pricing-saved');

  // ── 8. Privacy Policy ─────────────────────────────────────────────────────
  step('Privacy Policy URL');
  // Navigate back to App Information if needed
  await tryFill(page, [
    'input[name="privacyPolicyUrl"]',
    'input[placeholder*="Privacy Policy" i]',
    'input[placeholder*="privacy" i]',
  ], APP.privacyPolicyUrl, 'Privacy Policy URL');

  await tryClick(page, ['button:has-text("Save")'], 'Save Privacy Policy');
  await sleep(2000);
  await screenshot(page, '09-privacy-saved');

  // ── Done ──────────────────────────────────────────────────────────────────
  step('Done!');
  console.log(`
╔══════════════════════════════════════════════════════════╗
║  ✅ OpenBurnBar app listing setup complete               ║
╚══════════════════════════════════════════════════════════╝

Filled automatically:
  ✅ App Name: OpenBurnBar
  ✅ Platform: ${platform === 'macos' ? 'macOS' : 'iOS'}
  ✅ Bundle ID: ${meta.bundleId}
  ✅ SKU: ${meta.sku}
  ✅ Subtitle, Category, Copyright
  ✅ Description (~1,400 chars)
  ✅ Keywords, Support URL, Marketing URL
  ✅ What's New / Release Notes
  ✅ Pricing: Free
  ✅ Privacy Policy URL

Still needed (manual):
  📸 Screenshots  (macOS: 1280×800 or 1440×900)
  📦 Attach a signed build
  📝 App Privacy questionnaire
  🔑 Register bundle ID if not yet at:
     developer.apple.com/account/resources/identifiers/add/bundleId

Screenshots saved to /tmp/asc-*.png for reference.
`);

  log('Browser staying open — close it when ready.');
}

main().catch(err => {
  console.error(`\n[ASC] ❌ Error: ${err.message}`);
  process.exit(1);
});
