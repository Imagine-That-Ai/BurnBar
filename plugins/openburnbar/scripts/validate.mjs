#!/usr/bin/env node
/**
 * validate.mjs — fail-closed structural validator for the OpenBurnBar
 * Cursor Marketplace plugin package (plugins/openburnbar/).
 *
 * Plugin-root resolution (copy-aware):
 *   - Default: the plugin root is the parent of this script's own directory
 *     (scripts/), derived from import.meta.url. A full copy of the package
 *     anywhere (for example a /tmp mutation tree) therefore validates
 *     itself without depending on the caller's cwd.
 *   - Optional: pass the plugin root as the first positional argument to
 *     point the validator at a specific tree, e.g.
 *     `node scripts/validate.mjs /tmp/copy/plugins/openburnbar`.
 *
 * Node standard library only (node:fs, node:path, node:url, node:process).
 * No package.json, no node_modules, no runtime dependencies.
 *
 * Exit 0 when the package is intact; exit 1 (fail-closed) and list every
 * problem found otherwise. This script is the cheap local + CI gate:
 * `node plugins/openburnbar/scripts/validate.mjs` from the worktree root.
 */
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const SCRIPT_DIR = path.dirname(fileURLToPath(import.meta.url));
const DEFAULT_ROOT = path.resolve(SCRIPT_DIR, '..');
const root = process.argv[2] ? path.resolve(process.argv[2]) : DEFAULT_ROOT;

const failures = [];
const fail = (msg) => failures.push(msg);

const HOSTED_MCP_URL = 'https://mcp.burnbar.ai/mcp';
const BEARER_PLACEHOLDER = 'Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}';
const TOKEN_VAR = 'OPENBURNBAR_MCP_ACCESS_TOKEN';
const REQUIRED_KEYWORDS = ['openburnbar', 'burnbar', 'mcp', 'spend', 'sessions', 'memory', 'resume'];
const ALLOWED_EXTENSIONS = new Set(['md', 'mdc', 'json', 'js', 'mjs', 'sh', 'svg', 'png', 'txt']);
const PROBE_PLACEHOLDER = 'not-a-real-openburnbar-token'; // documented probe-only placeholder
const CLONE_PATH_TOKENS = ['/Users/', '/home/', '~/', 'BurnBar-cursor-plugin', 'tools/openburnbar-mcp', '.git'];
const KEBAB = /^[a-z0-9]+(-[a-z0-9]+)*$/;
const SECRET_SHAPES = [
  { re: /\bsk-[A-Za-z0-9-]{8,}/, name: 'sk- secret shape' },
  { re: /\bghp_[A-Za-z0-9]{20,}/, name: 'ghp_ token shape' },
  { re: /\bnpm_[A-Za-z0-9]{20,}/, name: 'npm_ token shape' },
  { re: /\bAKIA[0-9A-Z]{16}\b/, name: 'AWS access key shape' },
  { re: /\beyJ[A-Za-z0-9_-]{20,}\./, name: 'JWT shape' },
  { re: /-----BEGIN [A-Z ]*PRIVATE KEY-----/, name: 'private key block' },
];
// Trailing prose/markdown punctuation allowed after the placeholder value
// (sentence `.` `,` `;`, code-span backtick, quotes, closing bracket).
// Note `}` is deliberately NOT stripped: the placeholder itself ends with
// `}` and must keep matching.
const STRIP_BEARER_PUNCT_RE = /[`"'.,;\]]+$/;
// Bare `Bearer <value>` phrase anywhere in a file (not just after
// `Authorization:`). WWW-Authenticate params carry `=`/`://` and are not
// credentials; the scan's caller filters those.
const BARE_BEARER_RE = /\bBearer\s+(\S+)/g;

// ---------------------------------------------------------------------------
// helpers
// ---------------------------------------------------------------------------

function readJson(rel) {
  const p = path.join(root, rel);
  if (!fs.existsSync(p)) {
    fail(`missing ${rel}`);
    return null;
  }
  try {
    return JSON.parse(fs.readFileSync(p, 'utf8'));
  } catch (e) {
    fail(`${rel} does not parse as JSON: ${e.message}`);
    return null;
  }
}

function parseFrontmatter(text) {
  const m = text.match(/^---\r?\n([\s\S]*?)\r?\n---/);
  if (!m) return null;
  const fm = {};
  for (const line of m[1].split(/\r?\n/)) {
    const kv = line.match(/^([A-Za-z0-9_-]+):\s*(.*)$/);
    if (kv) {
      let v = kv[2].trim();
      if (v === 'true') v = true;
      else if (v === 'false') v = false;
      fm[kv[1]] = v;
    }
  }
  return fm;
}

/** Recursively list files under root (includes dot-directories).
 *
 * Symlinks are resolved with realpath and classified by their target, so a
 * symlinked node_modules (or any symlinked forbidden tree) is never skipped
 * as an opaque symlink entry: the entry is recorded with its resolved target
 * and the tree scan checks both the virtual path and the real target. A
 * visited set of real directories keeps symlink cycles from recursing.
 */
const visitedRealDirs = new Set();
function walk(dir, relPrefix) {
  const out = [];
  visitedRealDirs.add(path.resolve(dir));
  let entries;
  try {
    entries = fs.readdirSync(dir, { withFileTypes: true });
  } catch (e) {
    fail(`cannot read directory ${path.join(relPrefix, path.basename(dir))}: ${e.message}`);
    return out;
  }
  for (const entry of entries) {
    const rel = path.posix.join(relPrefix, entry.name);
    const abs = path.join(dir, entry.name);
    if (entry.isSymbolicLink()) {
      let real;
      try {
        real = fs.realpathSync(abs);
      } catch (e) {
        fail(`broken symlink in plugin tree: ${rel} (${e.message})`);
        continue;
      }
      let st;
      try {
        st = fs.statSync(real);
      } catch (e) {
        fail(`cannot stat symlink target in plugin tree: ${rel} -> ${real} (${e.message})`);
        continue;
      }
      if (st.isDirectory()) {
        out.push({ rel, abs, isDir: true, symlinkTarget: real });
        if (!visitedRealDirs.has(real)) out.push(...walk(real, rel));
      } else {
        out.push({ rel, abs, isDir: false, symlinkTarget: real });
      }
    } else if (entry.isDirectory()) {
      out.push({ rel, abs, isDir: true });
      out.push(...walk(abs, rel));
    } else if (entry.isFile()) {
      out.push({ rel, abs, isDir: false });
    }
    // other entry types (sockets, fifos, devices) are ignored: not files
  }
  return out;
}

function hasTokenShape(text) {
  for (const { re, name } of SECRET_SHAPES) {
    if (re.test(text)) return name;
  }
  return null;
}

// ---------------------------------------------------------------------------
// 1. plugin.json identity
// ---------------------------------------------------------------------------

const plugin = readJson('.cursor-plugin/plugin.json');

if (fs.existsSync(path.join(root, '.cursor-plugin', 'marketplace.json'))) {
  fail('.cursor-plugin/marketplace.json must not exist (single-plugin layout)');
}

if (plugin) {
  if (plugin.name !== 'openburnbar' || !KEBAB.test(plugin.name)) {
    fail(`plugin.json name must be the kebab-case "openburnbar", got ${JSON.stringify(plugin.name)}`);
  }
  if (plugin.displayName !== 'OpenBurnBar') {
    fail(`plugin.json displayName must be "OpenBurnBar", got ${JSON.stringify(plugin.displayName)}`);
  }
  if (plugin.version !== '1.0.0') {
    fail(`plugin.json version must be "1.0.0", got ${JSON.stringify(plugin.version)}`);
  }
  if (!plugin.author || plugin.author.name !== 'OpenBurnBar / Imagine That AI') {
    fail(`plugin.json author.name must be "OpenBurnBar / Imagine That AI", got ${JSON.stringify(plugin.author?.name)}`);
  }
  const desc = plugin.description || '';
  if (
    !desc ||
    !/hosted\s+mcp/i.test(desc) ||
    !['spend', 'session', 'knowledge', 'resume', 'local preprocessing'].every((w) =>
      desc.toLowerCase().includes(w),
    )
  ) {
    fail(
      'plugin.json description must mention hosted MCP, spend, session/knowledge/resume, and the local preprocessing boundary',
    );
  }
  if (plugin.homepage !== 'https://burnbar.ai') {
    fail(`plugin.json homepage must be "https://burnbar.ai", got ${JSON.stringify(plugin.homepage)}`);
  }
  const repo =
    typeof plugin.repository === 'string'
      ? plugin.repository
      : plugin.repository && typeof plugin.repository.url === 'string'
        ? plugin.repository.url
        : null;
  if (repo !== 'https://github.com/Imagine-That-Ai/openburnbar-cursor-plugin') {
    fail(`plugin.json repository must be the thin public repo URL, got ${JSON.stringify(repo)}`);
  }
  if (plugin.license !== 'AGPL-3.0-only') {
    fail(`plugin.json license must be "AGPL-3.0-only", got ${JSON.stringify(plugin.license)}`);
  }
  if (plugin.logo !== 'assets/logo.svg') {
    fail(`plugin.json logo must be "assets/logo.svg", got ${JSON.stringify(plugin.logo)}`);
  }
  if (plugin.category !== 'integrations') {
    fail(`plugin.json category must be "integrations", got ${JSON.stringify(plugin.category)}`);
  }
  if (!Array.isArray(plugin.keywords)) {
    fail('plugin.json keywords must be an array');
  } else {
    for (const kw of REQUIRED_KEYWORDS) {
      if (!plugin.keywords.includes(kw)) fail(`plugin.json keywords missing required token "${kw}"`);
    }
  }

  const pathFields = [
    ['skills', './skills/'],
    ['commands', './commands/'],
    ['rules', './rules/'],
    ['agents', './agents/'],
    ['mcpServers', './mcp.json'],
  ];
  for (const [field, expected] of pathFields) {
    const v = plugin[field];
    if (v !== expected) {
      fail(`plugin.json ${field} must be ${JSON.stringify(expected)}, got ${JSON.stringify(v)}`);
    } else if (path.isAbsolute(v) || v.includes('..')) {
      fail(`plugin.json ${field} must be a relative in-package path, got ${JSON.stringify(v)}`);
    }
  }
  if (fs.existsSync(path.join(root, 'assets', 'logo.svg')) === false) {
    fail('assets/logo.svg must exist (plugin.json.logo points at it)');
  }

  // 2. variables: JSON Schema, exactly one required variable, no default secret
  const variables = plugin.variables;
  if (!variables || typeof variables !== 'object') {
    fail('plugin.json.variables must be a JSON Schema object');
  } else {
    if (variables.type !== 'object') {
      fail(`plugin.json.variables.type must be "object", got ${JSON.stringify(variables.type)}`);
    }
    const required = variables.required || [];
    if (JSON.stringify(required) !== JSON.stringify([TOKEN_VAR])) {
      fail(`plugin.json.variables.required must be exactly ["${TOKEN_VAR}"], got ${JSON.stringify(required)}`);
    }
    const prop = variables.properties && variables.properties[TOKEN_VAR];
    if (!prop) {
      fail(`plugin.json.variables.properties.${TOKEN_VAR} must exist`);
    } else {
      if (prop.type !== 'string') fail(`${TOKEN_VAR} variable type must be "string", got ${JSON.stringify(prop.type)}`);
      const title = prop.title || '';
      const description = prop.description || '';
      if (!title) fail(`${TOKEN_VAR} variable needs a non-empty title`);
      if (!description) fail(`${TOKEN_VAR} variable needs a non-empty description`);
      const honestTokens = ['blocked', 'copy/export', 'does not print', 'keychain', 'refresh token'];
      for (const token of honestTokens) {
        if (!description.toLowerCase().includes(token)) {
          fail(`${TOKEN_VAR} variable description must include honest setup boundary token ${JSON.stringify(token)}`);
        }
      }
      if (Object.prototype.hasOwnProperty.call(prop, 'default')) {
        fail(`${TOKEN_VAR} variable must not ship a default value (no default secret)`);
      }
      // No variable property may carry a default: a defaulted property would
      // persist a value the plugin never asked the user to provide.
      for (const propName of Object.keys(variables.properties)) {
        if (Object.prototype.hasOwnProperty.call(variables.properties[propName], 'default')) {
          fail(`plugin.json variable property ${JSON.stringify(propName)} must not declare a default value`);
        }
      }
    }
  }
}

// ---------------------------------------------------------------------------
// 3. mcp.json — exactly one HTTP server, locked URL, bearer placeholder
// ---------------------------------------------------------------------------

const mcpRaw = fs.existsSync(path.join(root, 'mcp.json'))
  ? fs.readFileSync(path.join(root, 'mcp.json'), 'utf8')
  : null;
if (mcpRaw === null) {
  fail('missing mcp.json');
} else {
  let mcp = null;
  try {
    mcp = JSON.parse(mcpRaw);
  } catch (e) {
    fail(`mcp.json does not parse as JSON: ${e.message}`);
  }
  if (mcp) {
    const servers = mcp.mcpServers || {};
    const names = Object.keys(servers);
    if (JSON.stringify(names) !== JSON.stringify(['openburnbar'])) {
      fail(`mcp.json must declare exactly one server "openburnbar", got ${JSON.stringify(names)}`);
    }
    const server = servers.openburnbar || {};
    if (server.type !== 'http') {
      fail(`mcp.json openburnbar.type must be "http", got ${JSON.stringify(server.type)}`);
    }
    if (server.url !== HOSTED_MCP_URL) {
      fail(`mcp.json openburnbar.url must be ${HOSTED_MCP_URL}, got ${JSON.stringify(server.url)}`);
    }
    // Authorization invariant (exact case): the headers object must carry an
    // exact-case `Authorization` header equal to the bearer placeholder. A
    // missing Authorization header — or a non-exact-case `authorization`-spelled
    // header key (e.g. lowercase `authorization: Basic ...`) carrying any value
    // — fails closed even when other headers exist. Property lookup is
    // case-sensitive, so a lowercase `authorization` key cannot satisfy the
    // exact-case check; the per-header loop below rejects such twins outright.
    if (!server.headers || server.headers.Authorization !== BEARER_PLACEHOLDER) {
      fail(
        `mcp.json Authorization must be exactly ${BEARER_PLACEHOLDER} (no literal credentials), got ${JSON.stringify(server.headers && server.headers.Authorization)}`,
      );
    }
    // Every header value is scanned, not just Authorization: any header may
    // smuggle a literal credential (e.g. X-Api-Key: sk-...).
    const headerEntries = server.headers ? Object.entries(server.headers) : [];
    if (headerEntries.length === 0) {
      fail('mcp.json openburnbar.headers must declare the Authorization bearer placeholder');
    }
    for (const [name, value] of headerEntries) {
      if (typeof value !== 'string' || value.trim() === '') {
        fail(`mcp.json header ${JSON.stringify(name)} must be a non-empty string, got ${JSON.stringify(value)}`);
        continue;
      }
      // Header keys are case-sensitive: a non-exact-case `authorization` twin
      // (lowercase `authorization: Basic ...`, `AUTHORIZATION`, ...) is rejected
      // even when an exact-case Authorization header is present, so a dual-header
      // tree cannot smuggle a second auth credential past the exact-case invariant.
      if (name.toLowerCase() === 'authorization' && name !== 'Authorization') {
        fail(
          `mcp.json header key must be exactly "Authorization" (case-sensitive); found ${JSON.stringify(name)} — non-exact-case authorization keys are rejected`,
        );
      }
      if (name === 'Authorization' && value !== BEARER_PLACEHOLDER) {
        fail(
          `mcp.json Authorization must be exactly ${BEARER_PLACEHOLDER} (no literal credentials), got ${JSON.stringify(value)}`,
        );
      }
      const shape = hasTokenShape(value);
      if (shape) fail(`mcp.json header ${JSON.stringify(name)} contains a secret-looking literal (${shape})`);
      if (value !== BEARER_PLACEHOLDER && /^Bearer\s+\S+$/i.test(value.trim())) {
        fail(`mcp.json header ${JSON.stringify(name)} is a bare bearer value; only the ${BEARER_PLACEHOLDER} placeholder is allowed`);
      }
    }
    if (Object.prototype.hasOwnProperty.call(server, 'command') || Object.prototype.hasOwnProperty.call(server, 'args')) {
      fail('mcp.json must not declare a stdio command or args (HTTP only)');
    }
  }
  for (const token of CLONE_PATH_TOKENS) {
    if (mcpRaw.includes(token)) {
      fail(`mcp.json must not contain clone/absolute path token ${JSON.stringify(token)}`);
    }
  }
  for (const t of ['.venv', 'python', 'python3']) {
    if (mcpRaw.includes(t)) fail(`mcp.json must not mention ${JSON.stringify(t)}`);
  }
  const declared = new Set(
    plugin && plugin.variables && plugin.variables.properties ? Object.keys(plugin.variables.properties) : [],
  );
  const used = [...mcpRaw.matchAll(/\$\{([A-Z0-9_]+)\}/g)].map((m) => m[1]);
  for (const v of used) {
    if (!declared.has(v)) fail(`mcp.json uses undeclared variable \${${v}} (not in plugin.json variables.properties)`);
  }
  const shape = hasTokenShape(mcpRaw);
  if (shape) fail(`mcp.json contains a secret-looking literal (${shape})`);
}

// ---------------------------------------------------------------------------
// 4. skills / commands / rules / agents
// ---------------------------------------------------------------------------

const SKILL_DIRS = [
  'openburnbar-operator',
  'openburnbar-spend',
  'openburnbar-resume',
  'openburnbar-knowledge',
  'openburnbar-doctor',
];
const COMMAND_FILES = [
  ['openburnbar-search.md', 'openburnbar-operator'],
  ['openburnbar-spend.md', 'openburnbar-spend'],
  ['openburnbar-resume.md', 'openburnbar-resume'],
  ['openburnbar-knowledge.md', 'openburnbar-knowledge'],
  ['openburnbar-doctor.md', 'openburnbar-doctor'],
];
const RULE_FILES = ['query-openburnbar-for-history.mdc', 'treat-transcripts-as-untrusted.mdc'];
const AGENT_FILES = ['openburnbar-session-analyst.md', 'openburnbar-spend-analyst.md'];

function checkComponent(rel, requireName, requireDesc) {
  const abs = path.join(root, rel);
  if (!fs.existsSync(abs)) {
    fail(`missing component ${rel}`);
    return null;
  }
  const text = fs.readFileSync(abs, 'utf8');
  const fm = parseFrontmatter(text);
  if (!fm) {
    fail(`${rel} must start with YAML frontmatter`);
    return null;
  }
  if (requireName) {
    const name = fm.name;
    if (typeof name !== 'string' || !name) fail(`${rel} frontmatter needs a non-empty name`);
    else if (!KEBAB.test(name)) fail(`${rel} frontmatter name must be kebab-case, got ${JSON.stringify(name)}`);
  }
  if (requireDesc && (typeof fm.description !== 'string' || !fm.description.trim())) {
    fail(`${rel} frontmatter needs a non-empty description`);
  }
  return { fm, text };
}

// skills: exactly the five directories
let skillDirs = [];
try {
  skillDirs = fs.readdirSync(path.join(root, 'skills'), { withFileTypes: true }).filter((e) => e.isDirectory());
} catch {
  fail('missing skills/ directory');
}
const actualSkillNames = skillDirs.map((d) => d.name).sort();
if (JSON.stringify(actualSkillNames) !== JSON.stringify([...SKILL_DIRS].sort())) {
  fail(`skills/ must contain exactly ${JSON.stringify(SKILL_DIRS)}, got ${JSON.stringify(actualSkillNames)}`);
} else {
  for (const dir of SKILL_DIRS) {
    const rel = `skills/${dir}/SKILL.md`;
    const checked = checkComponent(rel, true, true);
    const fm = checked ? checked.fm : null;
    if (fm && fm.name !== dir) fail(`${rel} frontmatter name must match the directory (${dir}), got ${JSON.stringify(fm.name)}`);
  }
}

// commands: exactly five files, body names the matching skill slug
let commandFiles = [];
try {
  commandFiles = fs.readdirSync(path.join(root, 'commands')).filter((f) => f.endsWith('.md'));
} catch {
  fail('missing commands/ directory');
}
const actualCommandNames = commandFiles.sort();
const expectedCommandNames = COMMAND_FILES.map(([f]) => f).sort();
if (JSON.stringify(actualCommandNames) !== JSON.stringify(expectedCommandNames)) {
  fail(`commands/ must contain exactly ${JSON.stringify(expectedCommandNames)}, got ${JSON.stringify(actualCommandNames)}`);
} else {
  for (const [file, slug] of COMMAND_FILES) {
    const rel = `commands/${file}`;
    const checked = checkComponent(rel, true, true);
    if (!checked) continue; // checkComponent already failed the missing/broken component
    const { fm, text } = checked;
    if (fm && fm.name !== file.replace(/\.md$/, '')) {
      fail(`${rel} frontmatter name must equal the filename stem, got ${JSON.stringify(fm.name)}`);
    }
    const body = text.replace(/^---\r?\n[\s\S]*?\r?\n---/, '');
    if (!body.includes(slug)) {
      fail(`${rel} body must invoke the matching skill slug ${JSON.stringify(slug)}`);
    }
  }
}

// rules: exactly two, description + alwaysApply === false
let ruleFiles = [];
try {
  ruleFiles = fs.readdirSync(path.join(root, 'rules')).filter((f) => f.endsWith('.mdc'));
} catch {
  fail('missing rules/ directory');
}
if (JSON.stringify(ruleFiles.sort()) !== JSON.stringify([...RULE_FILES].sort())) {
  fail(`rules/ must contain exactly ${JSON.stringify(RULE_FILES)}, got ${JSON.stringify(ruleFiles.sort())}`);
} else {
  for (const file of RULE_FILES) {
    const rel = `rules/${file}`;
    const checked = checkComponent(rel, false, true);
    const fm = checked ? checked.fm : null;
    if (fm && fm.alwaysApply !== false) {
      fail(`${rel} frontmatter alwaysApply must be boolean false, got ${JSON.stringify(fm.alwaysApply)}`);
    }
  }
}

// agents: exactly two, kebab name === filename stem
let agentFiles = [];
try {
  agentFiles = fs.readdirSync(path.join(root, 'agents')).filter((f) => f.endsWith('.md'));
} catch {
  fail('missing agents/ directory');
}
if (JSON.stringify(agentFiles.sort()) !== JSON.stringify([...AGENT_FILES].sort())) {
  fail(`agents/ must contain exactly ${JSON.stringify(AGENT_FILES)}, got ${JSON.stringify(agentFiles.sort())}`);
} else {
  for (const file of AGENT_FILES) {
    const rel = `agents/${file}`;
    const checked = checkComponent(rel, true, true);
    const fm = checked ? checked.fm : null;
    if (fm && fm.name !== file.replace(/\.md$/, '')) {
      fail(`${rel} frontmatter name must equal the filename stem, got ${JSON.stringify(fm.name)}`);
    }
  }
}

// ---------------------------------------------------------------------------
// 5. LICENSE / CHANGELOG / logo
// ---------------------------------------------------------------------------

const licenseAbs = path.join(root, 'LICENSE');
if (!fs.existsSync(licenseAbs)) {
  fail('missing LICENSE');
} else {
  const licenseText = fs.readFileSync(licenseAbs, 'utf8');
  if (!licenseText.includes('GNU AFFERO GENERAL PUBLIC LICENSE') || !licenseText.includes('Version 3')) {
    fail('LICENSE must be the GNU AGPL version 3 text');
  }
  if (licenseText.includes('MIT License') || licenseText.includes('Permission is hereby granted, free of charge')) {
    fail('LICENSE must be AGPL-3.0-only, not MIT');
  }
}

if (!fs.existsSync(path.join(root, 'CHANGELOG.md'))) {
  fail('missing CHANGELOG.md');
} else if (!fs.readFileSync(path.join(root, 'CHANGELOG.md'), 'utf8').includes('1.0.0')) {
  fail('CHANGELOG.md must record the 1.0.0 release');
}

const logoAbs = path.join(root, 'assets', 'logo.svg');
if (!fs.existsSync(logoAbs)) {
  fail('missing assets/logo.svg');
} else {
  const head = fs.readFileSync(logoAbs, 'utf8').slice(0, 1024);
  if (!head.includes('<svg')) fail('assets/logo.svg must be a text SVG (<svg in the first kilobyte)');
}

// ---------------------------------------------------------------------------
// 6. tree-wide tripwires
// ---------------------------------------------------------------------------

const FORBIDDEN_TREES = new Set(['node_modules', '.venv', 'venv']);
const FORBIDDEN_FILES = new Set([
  'package.json',
  'package-lock.json',
  'pnpm-lock.yaml',
  'yarn.lock',
  'bun.lock',
  'pyvenv.cfg',
  'extension.ts',
  'extension.js',
  '.vscodeignore',
  'vsc-extension-quickstart.md',
  'Package.swift',
]);
const FORBIDDEN_EXTENSIONS = new Set(['swift', 'xcodeproj', 'xcworkspace', 'pbxproj', 'vsix', 'exe', 'bin', 'dylib', 'so']);
const VSCODE_REWRITE_RE = /"engines"\s*:\s*\{\s*"vscode|activationEvents/;

let treeOk = true;
try {
  fs.readdirSync(root);
} catch {
  treeOk = false;
  fail(`plugin root does not exist or is unreadable: ${root}`);
}

if (treeOk) {
  const files = walk(root, '');
  for (const f of files) {
    if (f.isDir) {
      if (FORBIDDEN_TREES.has(f.rel.split('/').pop())) {
        fail(`forbidden tree present: ${f.rel}`);
      }
      if (f.rel.includes('/node_modules/') || f.rel.split('/').includes('.venv') || f.rel.split('/').includes('venv')) {
        fail(`forbidden dependency tree present: ${f.rel}`);
      }
      // Symlink targets are scanned like real directories: a symlinked
      // node_modules (or .venv) must be rejected even though readdir sees
      // it as a single symlink entry, not a directory.
      if (f.symlinkTarget) {
        const targetSegs = f.symlinkTarget.split(path.sep);
        if (
          targetSegs.includes('node_modules') ||
          targetSegs.includes('.venv') ||
          targetSegs.includes('venv')
        ) {
          fail(`forbidden tree reachable through symlink: ${f.rel} -> ${f.symlinkTarget}`);
        }
      }
      continue;
    }
    const base = f.rel.split('/').pop();
    if (FORBIDDEN_FILES.has(base)) {
      fail(`forbidden file present: ${f.rel} (forces full CI or is a VS Code rewrite artifact)`);
    }
    if (base.endsWith('.vsix')) fail(`forbidden VSIX artifact present: ${f.rel}`);
    const ext = f.rel.includes('.') ? f.rel.split('.').pop() : '';
    if (FORBIDDEN_EXTENSIONS.has(ext)) {
      fail(`forbidden binary/build artifact present: ${f.rel}`);
    }
    if (ext && !ALLOWED_EXTENSIONS.has(ext)) {
      fail(`unexpected file extension in plugin tree: ${f.rel}`);
    }
    const segs = f.rel.split('/');
    if (segs.includes('daemon') || segs.includes('swift')) {
      fail(`forbidden daemon/Swift path present: ${f.rel}`);
    }
    const buf = fs.readFileSync(f.abs);
    if (buf.includes(0)) {
      fail(`binary file in plugin tree: ${f.rel}`);
    }
    // The validator's own source is the gate, not package content: skip the
    // content-pattern scans for it (its regex literals would self-match).
    if (f.rel === 'scripts/validate.mjs') continue;
    const text = buf.toString('utf8');
    const shape = hasTokenShape(text);
    if (shape) fail(`secret-looking literal (${shape}) in ${f.rel}`);
    const authz = text.match(/Authorization:\s*Bearer\s+(\S+)/i);
    if (authz) {
      // Allow trailing prose/markdown punctuation around the placeholder
      // (`.`, `,`, `;`, code-span backticks, quotes) — e.g.
      // `Authorization: Bearer ${OPENBURNBAR_MCP_ACCESS_TOKEN}.` at the end
      // of a sentence — but never a literal credential.
      const value = authz[1].replace(STRIP_BEARER_PUNCT_RE, '');
      if (value !== '${' + TOKEN_VAR + '}' && !value.includes(PROBE_PLACEHOLDER)) {
        fail(`non-placeholder Authorization: Bearer value in ${f.rel}`);
      }
    }
    // Bare-bearer scan: catch `Bearer <token>` phrases anywhere in the
    // file, not only after an `Authorization:` prefix. WWW-Authenticate
    // scheme parameters (e.g. `Bearer resource_metadata="https://..."` from
    // probe transcripts) contain `=` and URLs contain `://`; those are not
    // credentials. The placeholder and the documented probe placeholder are
    // allowed with trailing prose punctuation stripped.
    for (const m of text.matchAll(BARE_BEARER_RE)) {
      const value = m[1].replace(STRIP_BEARER_PUNCT_RE, '');
      if (value === '${' + TOKEN_VAR + '}') continue;
      if (value.includes(PROBE_PLACEHOLDER)) continue;
      if (value.includes('=') || value.includes('://')) continue;
      fail(`bare Bearer credential-looking value in ${f.rel}: ${JSON.stringify(value.slice(0, 24))}...`);
    }
    if (VSCODE_REWRITE_RE.test(text)) {
      fail(`VS Code extension rewrite markers in ${f.rel}`);
    }
  }
}

for (const rel of [
  'README.md',
  'docs/local-load.md',
  'skills/openburnbar-operator/SKILL.md',
  'skills/openburnbar-knowledge/SKILL.md',
  'commands/openburnbar-search.md',
]) {
  const text = fs.readFileSync(path.join(root, rel), 'utf8');
  if (text.includes('/Users/')) {
    fail(`${rel} must not contain a developer-specific /Users install path`);
  }
}

for (const rel of [
  'README.md',
  'AUTH.md',
  'skills/openburnbar-operator/SKILL.md',
  'skills/openburnbar-knowledge/SKILL.md',
  'commands/openburnbar-search.md',
]) {
  const text = fs.readFileSync(path.join(root, rel), 'utf8').toLowerCase();
  if (!text.includes('local') || (!text.includes('preprocess') && !text.includes('shim'))) {
    fail(`${rel} must name the local preprocessing/shim boundary`);
  }
}

// ---------------------------------------------------------------------------
// 7. verdict
// ---------------------------------------------------------------------------

if (failures.length > 0) {
  console.error(`validate.mjs: plugin package at ${root} is NOT valid (${failures.length} problem(s)):`);
  for (const f of failures) console.error(`  - ${f}`);
  process.exit(1);
}
console.log(`validate.mjs: plugin package at ${root} is valid.`);
process.exit(0);
