#!/usr/bin/env node
/**
 * Phase 9 Computer Use browser scenarios.
 *
 * Spawns the production Playwright bridge, drives scenario pages, and
 * validates the RPC responses. The default `local` scenario set is CI-safe
 * and exercises every browser action shape the agent can request through
 * the bridge: goto, extract, fill, click, select, key, position-click, and
 * screenshot. `--scenario-set phase9-plan` additionally runs the master
 * plan's Browser CU smoke shape: Wikipedia search, GitHub repo navigation,
 * form fill, multi-page flow, and error recovery.
 */
'use strict';

import { spawn, execFileSync } from 'node:child_process';
import readline from 'node:readline';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const root = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '..');
const args = process.argv.slice(2);
function argValue(name, fallback) {
  const index = args.indexOf(name);
  return index >= 0 && args[index + 1] ? args[index + 1] : fallback;
}

const bridge = argValue('--bridge', process.env.OPENBURNBAR_PLAYWRIGHT_BRIDGE
  || path.join(root, 'OpenBurnBarDaemon/Resources/PlaywrightBridge/openburnbar-playwright-bridge.js'));
const runs = Number.parseInt(argValue('--runs', '5'), 10);
if (!Number.isFinite(runs) || runs < 1) {
  throw new Error('--runs must be a positive integer');
}
const scenarioSetName = argValue('--scenario-set', 'local');

function globalNodePath() {
  try {
    return execFileSync('npm', ['root', '-g'], { encoding: 'utf8' }).trim();
  } catch {
    return '';
  }
}

function dataURL(title, body) {
  return `data:text/html;charset=utf-8,${encodeURIComponent(`<!doctype html>
<html>
<head>
  <meta charset="utf-8">
  <title>${title}</title>
  <style>
    body { font-family: -apple-system, BlinkMacSystemFont, sans-serif; margin: 32px; }
    button, input, select { font: inherit; margin: 8px 0; padding: 8px 10px; }
  </style>
</head>
<body>${body}</body>
</html>`)}`;
}

class BridgeClient {
  constructor() {
    const nodePath = globalNodePath();
    const env = { ...process.env };
    if (nodePath) {
      env.NODE_PATH = env.NODE_PATH ? `${nodePath}:${env.NODE_PATH}` : nodePath;
    }
    this.child = spawn(
      process.execPath,
      [bridge, '--headless', '--session-id', 'phase9-browser-scenarios', '--per-action-timeout-ms', '15000'],
      { cwd: root, env, stdio: ['pipe', 'pipe', 'pipe'] }
    );
    this.nextId = 1;
    this.pending = new Map();
    this.stderr = [];
    this.elapsedMillis = [];

    const rl = readline.createInterface({ input: this.child.stdout });
    rl.on('line', (line) => this.handleLine(line));
    this.child.stderr.on('data', (chunk) => {
      const text = String(chunk);
      this.stderr.push(text);
      process.stderr.write(`[bridge] ${text}`);
    });
    this.child.on('exit', (code) => {
      for (const { reject } of this.pending.values()) {
        reject(new Error(`bridge exited before response, code=${code}`));
      }
      this.pending.clear();
    });
  }

  handleLine(line) {
    let response;
    try {
      response = JSON.parse(line);
    } catch (error) {
      throw new Error(`malformed bridge JSON: ${line}\n${error.message}`);
    }
    const pending = this.pending.get(response.id);
    if (!pending) return;
    this.pending.delete(response.id);
    if (typeof response.elapsedMillis === 'number') {
      this.elapsedMillis.push(response.elapsedMillis);
    }
    if (!response.ok && !pending.allowError) {
      pending.reject(new Error(response.error || `RPC ${response.id} failed`));
      return;
    }
    pending.resolve(response);
  }

  call(method, params = {}, options = {}) {
    const id = this.nextId++;
    const request = { id, method, params };
    return new Promise((resolve, reject) => {
      const timer = setTimeout(() => {
        this.pending.delete(id);
        reject(new Error(`RPC timeout: ${method}`));
      }, 20_000);
      this.pending.set(id, {
        resolve: (value) => {
          clearTimeout(timer);
          resolve(value);
        },
        reject: (error) => {
          clearTimeout(timer);
          reject(error);
        },
        allowError: !!options.allowError,
      });
      this.child.stdin.write(`${JSON.stringify(request)}\n`);
    });
  }

  async shutdown() {
    try {
      await this.call('shutdown');
    } catch {
      this.child.kill('SIGTERM');
    }
  }
}

function expectEqual(actual, expected, label) {
  if (actual !== expected) {
    throw new Error(`${label}: expected ${JSON.stringify(expected)}, got ${JSON.stringify(actual)}`);
  }
}

function expectMatch(actual, regex, label) {
  if (!regex.test(actual || '')) {
    throw new Error(`${label}: expected ${regex}, got ${JSON.stringify(actual)}`);
  }
}

function expectIncludes(actual, needle, label) {
  if (!String(actual || '').includes(needle)) {
    throw new Error(`${label}: expected text to include ${JSON.stringify(needle)}, got ${JSON.stringify(actual)}`);
  }
}

function expectAtLeast(actual, minimum, label) {
  if (!(actual >= minimum)) {
    throw new Error(`${label}: expected >= ${minimum}, got ${actual}`);
  }
}

function percentile(values, p) {
  if (!values.length) return 0;
  const sorted = [...values].sort((a, b) => a - b);
  const index = Math.min(sorted.length - 1, Math.ceil((p / 100) * sorted.length) - 1);
  return sorted[index];
}

async function expectRpcFailure(client, method, params, regex, label) {
  const response = await client.call(method, params, { allowError: true });
  if (response.ok) {
    throw new Error(`${label}: expected RPC failure for ${method}, got ok response`);
  }
  expectMatch(response.error, regex, label);
}

const localScenarios = [
  {
    name: 'navigate_extract_heading',
    async run(client, index) {
      const title = `Scenario 1 Run ${index}`;
      await client.call('goto', {
        url: dataURL(title, `<h1 id="headline">Scenario 1 Ready ${index}</h1>`),
      });
      const currentTitle = await client.call('current_title');
      expectEqual(currentTitle.result.title, title, `${this.name} title`);
      const currentURL = await client.call('current_url');
      expectMatch(currentURL.result.url, /^data:text\/html/, `${this.name} current_url`);
      const extracted = await client.call('extract', { selector: '#headline' });
      expectEqual(extracted.result.text, `Scenario 1 Ready ${index}`, this.name);
    },
  },
  {
    name: 'fill_click_submit',
    async run(client, index) {
      await client.call('goto', {
        url: dataURL('Fill Click', `
          <label>Name <input id="name" /></label>
          <button id="submit" onclick="document.querySelector('#out').textContent='Hello ' + document.querySelector('#name').value">Submit</button>
          <div id="out"></div>
        `),
      });
      await client.call('fill', { selector: '#name', text: `Hermes-${index}` });
      await client.call('click', { selector: '#submit' });
      const extracted = await client.call('extract', { selector: '#out' });
      expectEqual(extracted.result.text, `Hello Hermes-${index}`, this.name);
    },
  },
  {
    name: 'select_option',
    async run(client) {
      await client.call('goto', {
        url: dataURL('Select', `
          <select id="choice" onchange="document.querySelector('#out').textContent=this.value">
            <option value="alpha">Alpha</option>
            <option value="beta">Beta</option>
          </select>
          <div id="out">unset</div>
        `),
      });
      await client.call('select', { selector: '#choice', value: 'beta' });
      const extracted = await client.call('extract', { selector: '#out' });
      expectEqual(extracted.result.text, 'beta', this.name);
    },
  },
  {
    name: 'keyboard_enter',
    async run(client, index) {
      await client.call('goto', {
        url: dataURL('Keyboard', `
          <input id="query" onkeydown="if(event.key==='Enter'){document.querySelector('#out').textContent=this.value}" />
          <div id="out"></div>
        `),
      });
      await client.call('fill', { selector: '#query', text: `query-${index}` });
      await client.call('key', { key: 'Enter', modifiers: [] });
      const extracted = await client.call('extract', { selector: '#out' });
      expectEqual(extracted.result.text, `query-${index}`, this.name);
    },
  },
  {
    name: 'position_click_and_screenshot',
    async run(client) {
      await client.call('goto', {
        url: dataURL('Position Click', `
          <button
            id="target"
            style="position:absolute;left:40px;top:50px;width:160px;height:60px"
            onclick="document.querySelector('#out').textContent='clicked'">Target</button>
          <div id="out" style="position:absolute;left:40px;top:130px"></div>
        `),
      });
      await client.call('click', { positionX: 100, positionY: 80 });
      const extracted = await client.call('extract', { selector: '#out' });
      expectEqual(extracted.result.text, 'clicked', this.name);
      const shot = await client.call('screenshot', { fullPage: true });
      expectAtLeast(shot.result.sizeBytes, 1000, `${this.name} screenshot size`);
      expectMatch(shot.result.base64, /^[A-Za-z0-9+/=]+$/, `${this.name} screenshot base64`);
    },
  },
];

const phase9PlanScenarios = [
  {
    name: 'wikipedia_search',
    async run(client) {
      await client.call('goto', {
        url: 'https://en.wikipedia.org/w/index.php?search=Playwright+software&title=Special%3ASearch&fulltext=1&ns0=1',
        timeoutMs: 20000,
      });
      const body = await client.call('extract', { selector: 'body', timeoutMs: 20000 });
      expectMatch(body.result.text, /Playwright/i, this.name);
      const current = await client.call('current_url');
      expectMatch(current.result.url, /wikipedia\.org/, `${this.name} current_url`);
    },
  },
  {
    name: 'github_repo_navigation',
    async run(client) {
      await client.call('goto', {
        url: 'https://github.com/openai/codex',
        timeoutMs: 20000,
      });
      const body = await client.call('extract', { selector: 'body', timeoutMs: 20000 });
      expectMatch(body.result.text, /openai|codex|GitHub/i, this.name);
      const title = await client.call('current_title');
      expectMatch(title.result.title, /GitHub|codex/i, `${this.name} title`);
    },
  },
  {
    name: 'form_fill',
    async run(client, index) {
      await client.call('goto', {
        url: dataURL('Form Fill', `
          <form onsubmit="event.preventDefault();document.querySelector('#out').textContent='submitted:' + document.querySelector('#email').value">
            <input id="email" type="email" />
            <button id="submit">Submit</button>
          </form>
          <div id="out"></div>
        `),
      });
      await client.call('fill', { selector: '#email', text: `phase9-${index}@openburnbar.test` });
      await client.call('click', { selector: '#submit' });
      const out = await client.call('extract', { selector: '#out' });
      expectEqual(out.result.text, `submitted:phase9-${index}@openburnbar.test`, this.name);
    },
  },
  {
    name: 'multi_page_flow',
    async run(client) {
      await client.call('goto', {
        url: dataURL('Step One', `
          <h1>Step one</h1>
          <a id="next" href="https://example.com/">Next</a>
        `),
      });
      await client.call('click', { selector: '#next' });
      const done = await client.call('extract', { selector: 'h1', timeoutMs: 10000 });
      expectEqual(done.result.text, 'Example Domain', this.name);
      const current = await client.call('current_title');
      expectEqual(current.result.title, 'Example Domain', `${this.name} title`);
    },
  },
  {
    name: 'error_recovery',
    async run(client) {
      await client.call('goto', {
        url: dataURL('Error Recovery', `
          <h1 id="status">ready for recovery</h1>
          <button id="real" onclick="document.querySelector('#status').textContent='recovered'">Recover</button>
        `),
      });
      await expectRpcFailure(
        client,
        'click',
        { selector: '#missing-target', timeoutMs: 500 },
        /Timeout|waiting for locator|click/i,
        `${this.name} missing selector`
      );
      await client.call('click', { selector: '#real' });
      const status = await client.call('extract', { selector: '#status' });
      expectIncludes(status.result.text, 'recovered', this.name);
    },
  },
];

const scenarioSets = {
  local: localScenarios,
  'phase9-plan': phase9PlanScenarios,
};

const scenarios = scenarioSets[scenarioSetName];
if (!scenarios) {
  throw new Error(`unknown --scenario-set ${scenarioSetName}; expected one of ${Object.keys(scenarioSets).join(', ')}`);
}

async function main() {
  const client = new BridgeClient();
  const started = Date.now();
  let completed = 0;
  try {
    for (let run = 1; run <= runs; run += 1) {
      for (const scenario of scenarios) {
        await scenario.run(client, run);
        completed += 1;
        console.log(`ok scenarioSet=${scenarioSetName} run=${run}/${runs} scenario=${scenario.name}`);
      }
    }
  } finally {
    await client.shutdown();
  }
  const p95 = percentile(client.elapsedMillis, 95);
  console.log(`computer-use browser scenarios: OK scenarioSet=${scenarioSetName} scenarios=${scenarios.length} runs=${runs} total=${completed} rpcCount=${client.elapsedMillis.length} rpcP95Ms=${p95} elapsedMs=${Date.now() - started}`);
}

main().catch((error) => {
  console.error(`computer-use browser scenarios: FAILED: ${error.stack || error.message}`);
  process.exit(1);
});
