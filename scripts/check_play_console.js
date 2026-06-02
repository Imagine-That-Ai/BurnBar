#!/usr/bin/env node

const { chromium } = require('playwright');
const fs = require('fs');
const os = require('os');
const path = require('path');

async function main() {
  const repoRoot = path.resolve(__dirname, '..');
  const screenshotDir = path.join(repoRoot, 'output', 'playwright-screenshots');
  const explicitUserDataDir = process.env.PLAY_CONSOLE_USER_DATA_DIR || '';
  const persistProfile = process.env.PLAY_CONSOLE_PERSIST_PROFILE === '1';
  const userDataDir = explicitUserDataDir
    ? path.resolve(explicitUserDataDir)
    : fs.mkdtempSync(path.join(os.tmpdir(), 'openburnbar-play-console-profile-'));

  if (!fs.existsSync(screenshotDir)) {
    fs.mkdirSync(screenshotDir, { recursive: true });
  }
  fs.mkdirSync(userDataDir, { recursive: true, mode: 0o700 });
  fs.chmodSync(userDataDir, 0o700);

  console.log('Launching Google Chrome in headed mode with an isolated profile...');
  console.log(`Profile: ${explicitUserDataDir ? userDataDir : `${userDataDir} (temporary)`}`);
  let context;
  try {
    context = await chromium.launchPersistentContext(userDataDir, {
      headless: false,
      channel: 'chrome',
      viewport: { width: 1440, height: 900 },
    });

    const page = await context.newPage();

    console.log('Navigating to Google Play Console...');
    await page.goto('https://play.google.com/console/');

  console.log('\n==================================================');
  console.log('INSTRUCTIONS FOR ALBERTO:');
  console.log('1. A Chrome window has opened on your screen.');
  console.log('2. Log in using your Google Play Console developer account.');
  console.log('3. Navigate to: BurnBar -> Testing -> Closed testing.');
  console.log('4. The script will automatically detect when you reach the closed testing page,');
  console.log('   take a screenshot, and complete the analysis!');
  console.log('==================================================\n');

  // Let's poll the URL every 2 seconds
  let found = false;
  const timeoutMinutes = 10;
  const maxTicks = (timeoutMinutes * 60) / 2;
  let consecutiveErrors = 0;

    for (let tick = 0; tick < maxTicks; tick++) {
      try {
        const url = page.url();
        const title = await page.title();
        consecutiveErrors = 0; // Reset error count on success

        console.log(`[${new Date().toLocaleTimeString()}] Current Page: ${title} (${url.slice(0, 60)}...)`);

        if (url.includes('/testing/closed') || url.includes('/testing/tracks/closed')) {
          console.log('\nDetected Google Play Closed Testing Page!');
          console.log('Waiting 5 seconds for any final animations or tables to load...');
          await new Promise(resolve => setTimeout(resolve, 5000));

          const timestamp = new Date().toISOString().replace(/[:.]/g, '-');
          const filename = `closed-testing-${timestamp}.png`;
          const filepath = path.join(screenshotDir, filename);

          console.log(`Taking full page screenshot and saving to: ${filepath}`);
          await page.screenshot({ path: filepath, fullPage: true });

          // Save a copy as latest.png for embedding in the response.
          const latestPath = path.join(screenshotDir, 'latest.png');
          fs.copyFileSync(filepath, latestPath);

          console.log('Screenshot captured successfully!');
          found = true;
          break;
        }
      } catch (err) {
        consecutiveErrors++;
        console.log(`Browser window state error (possibly closed or loading, count=${consecutiveErrors}):`, err.message);
        if (consecutiveErrors >= 5) {
          console.log('Browser was closed or lost connection for 10 seconds. Exiting loop.');
          break;
        }
      }

      await new Promise(resolve => setTimeout(resolve, 2000));
    }

    if (!found) {
      console.log('Timeout reached (10 minutes) or browser closed before reaching the closed testing page.');
    }
  } finally {
    if (context) {
      console.log('Closing browser context...');
      await context.close();
    }
    if (!explicitUserDataDir && !persistProfile) {
      fs.rmSync(userDataDir, { recursive: true, force: true });
      console.log('Temporary Play Console browser profile deleted.');
    } else if (persistProfile) {
      console.log(`Play Console browser profile preserved by request: ${userDataDir}`);
    }
  }

  console.log('Finished.');
}

main().catch(err => {
  console.error('Fatal Playwright Error:', err);
  process.exit(1);
});
