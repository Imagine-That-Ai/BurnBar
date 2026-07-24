import assert from "node:assert/strict";
import crypto from "node:crypto";
import fs from "node:fs";
import path from "node:path";
import test from "node:test";
import vm from "node:vm";
import zlib from "node:zlib";
import { captureP36VisualPolishProof } from "./capture-p36-visual-polish-proof.mjs";
import { pngCrc32 } from "./lib/installed-ui-proof.mjs";
import {
  canonicalJsonBytes,
  createInstalledManifest,
  signInstalledManifest,
} from "./lib/linux-installed-manifest.mjs";
import {
  validateP36InstalledSession,
  validateP36Proof,
} from "./lib/p36-visual-polish-proof.mjs";
import { materializeP36VisualPolishSession } from "./materialize-p36-visual-polish-session.mjs";
import {
  P36_LAYOUT_SCRIPT,
  P36_THEME_SCRIPT,
  runP36VisualPolishWorkflow,
} from "./run-p36-native-visual-polish-probes.mjs";
const HEAD = "1".repeat(40);
const RUN = "363636";
const DIGEST = `sha256:${"2".repeat(64)}`;
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-x86_64";
const VERSION = "1.2.3";
const TEMP_ROOT = path.join(process.cwd(), ".tmp/p36-proof-tests");
fs.mkdirSync(TEMP_ROOT, { recursive: true });
test.after(() => fs.rmSync(TEMP_ROOT, { recursive: true, force: true }));
function hash(bytes) {
  return crypto.createHash("sha256").update(bytes).digest("hex");
}
function write(file, bytes, mode = 0o600) {
  fs.mkdirSync(path.dirname(file), { recursive: true });
  fs.writeFileSync(file, bytes);
  fs.chmodSync(file, mode);
  return file;
}
function json(file, value) {
  return write(file, `${JSON.stringify(value, null, 2)}\n`);
}
function record(root, file) {
  const bytes = fs.readFileSync(file);
  return {
    path: path.relative(root, file).split(path.sep).join("/"),
    sha256: hash(bytes),
    size: bytes.length,
  };
}
function chunk(type, data) {
  const name = Buffer.from(type);
  const output = Buffer.alloc(data.length + 12);
  output.writeUInt32BE(data.length);
  name.copy(output, 4);
  data.copy(output, 8);
  output.writeUInt32BE(pngCrc32(Buffer.concat([name, data])), data.length + 8);
  return output;
}
const PNG_CACHE = new Map();
function png(width, height, seed) {
  const cacheKey = `${width}x${height}:${seed}`;
  if (PNG_CACHE.has(cacheKey)) return PNG_CACHE.get(cacheKey);
  const header = Buffer.alloc(13);
  header.writeUInt32BE(width);
  header.writeUInt32BE(height, 4);
  header[8] = 8;
  header[9] = 2;
  const raw = Buffer.alloc((width * 3 + 1) * height);
  for (let y = 0; y < height; y += 1)
    for (let x = 0; x < width; x += 1) {
      const at = y * (width * 3 + 1) + 1 + x * 3;
      raw[at] = (x + seed * 19) % 256;
      raw[at + 1] = (y + seed * 31) % 256;
      raw[at + 2] = (x + y + seed * 43) % 256;
    }
  const bytes = Buffer.concat([
    Buffer.from([137, 80, 78, 71, 13, 10, 26, 10]),
    chunk("IHDR", header),
    chunk("IDAT", zlib.deflateSync(raw, { level: 6 })),
    chunk("IEND", Buffer.alloc(0)),
  ]);
  PNG_CACHE.set(cacheKey, bytes);
  return bytes;
}
function attestation(root, directory) {
  const { privateKey, publicKey } = crypto.generateKeyPairSync("ed25519");
  const privatePem = privateKey.export({ type: "pkcs8", format: "pem" });
  const publicPem = publicKey.export({ type: "spki", format: "pem" });
  write(
    path.join(root, "packaging/linux/openburnbar-linux-ed25519.pub.pem"),
    publicPem,
  );
  const item = (installedPath, bytes, mode) => ({
    path: installedPath,
    type: "file",
    sha256: hash(bytes),
    size: bytes.length,
    mode,
    uid: 0,
    gid: 0,
  });
  const manifest = canonicalJsonBytes(
    createInstalledManifest({
      files: [
        item("/usr/bin/openburnbar-daemon", Buffer.from("daemon"), "0755"),
        item(
          "/usr/bin/openburnbar-linux-desktop",
          Buffer.from("desktop"),
          "0755",
        ),
        item(
          "/usr/share/openburnbar/attestation/release-ed25519.pub.pem",
          publicPem,
          "0644",
        ),
      ],
      packageVersion: VERSION,
      gitCommit: HEAD,
      packageArchitecture: "x86_64",
      packageFormat: "deb",
      firebaseAppId: "1:2:web:3",
    }),
  );
  const signature = signInstalledManifest(manifest, privatePem, publicPem);
  return {
    manifestPath: write(
      path.join(directory, "installed-manifest.json"),
      manifest,
    ),
    signaturePath: write(
      path.join(directory, "installed-manifest.json.sig"),
      signature,
    ),
    manifestSha256: hash(manifest),
    manifestSignatureSha256: hash(signature),
  };
}
function options(root, overrides = {}) {
  return {
    rawOutputDir: path.join(root, "live/raw"),
    stateHome: path.join(root, "live/home"),
    environmentId: ENVIRONMENT,
    targetHead: HEAD,
    candidateRunId: RUN,
    candidateArtifactDigest: DIGEST,
    packageVersion: VERSION,
    manifestSha256: "0".repeat(64),
    manifestSignatureSha256: "0".repeat(64),
    architecture: "x86_64",
    packageFormat: "deb",
    compositor: "Mutter",
    desktop: "GNOME",
    displayServer: "X11",
    ...overrides,
  };
}
function interactionReceipt(overrides = {}) {
  return {
    keyboardOnly: true,
    distinctFocusTargets: 6,
    focusVisible: true,
    overflowOpened: true,
    arrowNavigation: true,
    escapeRestoredFocus: true,
    ...overrides,
  };
}
function fakeDependencies(overrides = {}) {
  let daemon = false;
  let motion = false;
  let restored = 0;
  let size = [1180, 820];
  const dimensions = {
    compact: [720, 900],
    standard: [1180, 820],
    wide: [1600, 900],
  };
  const names = {
    compact: "More actions",
    standard: "More actions",
    wide: "More actions",
    reduced: "Open command palette",
    overflow: "Appearance",
  };
  const layout = (density) => ({
    viewportWidth: size[0],
    viewportHeight: size[1],
    density,
    horizontalOverflow: 0,
    documentScrollWidth: size[0],
    clippedCount: 0,
    overlappingControls: 0,
    interactiveCount: 20,
    minControlHeight: 32,
  });
  return {
    platform: "linux",
    desktopSession: true,
    installedVerifier() {},
    marker: "p36-0123456789abcdef",
    nonce: "3".repeat(32),
    identity: () => ({
      packageManager: "dpkg",
      packageName: "open-burn-bar",
      packageOwned: true,
    }),
    daemonActive: () => daemon,
    async setDaemonActive(value) {
      daemon = value;
    },
    desktopPids: () => [],
    motionPreference: () => motion,
    async setMotionPreference(value) {
      motion = value;
    },
    async launch() {},
    async terminate() {},
    async resize(width, height) {
      size = [width, height];
    },
    async layout(density) {
      assert.deepEqual(size, dimensions[density]);
      return layout(density);
    },
    async theme(mode) {
      return {
        appearance: mode,
        contrastRatio: 7.2,
        nativeControlCount: 2,
        nativeControlScheme: mode,
        persisted: true,
      };
    },
    async motion() {
      return {
        mediaQuery: "(prefers-reduced-motion: reduce)",
        reduced: motion,
        animatedElements: 0,
        transitioningElements: 0,
      };
    },
    async interaction() {
      return interactionReceipt();
    },
    async capture(state, expected, accessibility, image) {
      assert.equal(expected, names[state]);
      const screenshotSize = {
        compact: [720, 900],
        standard: [1180, 820],
        wide: [1600, 900],
        reduced: [1600, 900],
        overflow: [1600, 900],
      }[state];
      write(
        image,
        png(
          screenshotSize[0],
          screenshotSize[1],
          { compact: 1, standard: 2, wide: 3, reduced: 4, overflow: 5 }[state],
        ),
      );
      json(accessibility, {
        schemaVersion: 1,
        producer: "openburnbar-p36-atspi-live-v1",
        proofState: state,
        capturedAt: new Date().toISOString(),
        application: "OpenBurnBar",
        route: "overview",
        viewport: { width: screenshotSize[0], height: screenshotSize[1] },
        theme: state === "compact" ? "light" : "dark",
        reducedMotion: state === "reduced" || state === "overflow",
        menuOpen: state === "overflow",
        expectedName: expected,
        expectedNamePresent: true,
        nodeCount: 30,
        namedNodeCount: 15,
        actionableNodeCount: 5,
        focusableNodeCount: 5,
        focusedNodes: [],
        roleCounts: { button: 5 },
        namedSamples: [],
        actionableSamples: [],
        truncated: false,
        minimums: { nodes: 12, named: 6, actionable: 3 },
        pass: true,
        failures: [],
        readinessAttempts:
          ["compact", "standard", "wide", "reduced", "overflow"].indexOf(
            state,
          ) + 1,
      });
    },
    async restart() {},
    themeState: async () => ({ appearance: "dark", persisted: "dark" }),
    async restoreState() {
      restored += 1;
    },
    restored: () => restored,
    ...overrides,
  };
}
async function fixture() {
  const root = fs.mkdtempSync(path.join(TEMP_ROOT, "case-"));
  const opts = options(root);
  const identity = attestation(root, path.join(root, "attestation"));
  Object.assign(opts, identity);
  const deps = fakeDependencies();
  const result = await runP36VisualPolishWorkflow(opts, deps);
  const input = path.join(
    root,
    "docs/linux-port/evidence/product-parity-inputs/P-36",
    ENVIRONMENT,
  );
  fs.mkdirSync(input, { recursive: true });
  const materialized = materializeP36VisualPolishSession(
    {
      ...opts,
      repoRoot: root,
      outputRoot: input,
      rawEvidenceDir: result.rawOutputDir,
    },
    {
      installedVerifier() {},
      manifestPath: identity.manifestPath,
      signaturePath: identity.signaturePath,
    },
  );
  return {
    root,
    opts,
    deps,
    input,
    session: materialized.document,
    sessionFile: materialized.output,
  };
}
function binding(value) {
  return { ...value.opts, repoRoot: value.root, candidateRunId: RUN };
}
function refresh(value, field, file) {
  value.session.evidence[field] = record(value.root, file);
}
function domElement(rect, style = {}, parentElement = null) {
  const element = {
    parentElement,
    disabled: false,
    style: {
      display: "block",
      visibility: "visible",
      opacity: "1",
      overflow: "visible",
      overflowX: "visible",
      overflowY: "visible",
      color: "rgb(0, 0, 0)",
      backgroundColor: "rgba(0, 0, 0, 0)",
      colorScheme: "normal",
      ...style,
    },
    getBoundingClientRect: () => ({ ...rect }),
    getAttribute: () => null,
    contains(candidate) {
      for (let current = candidate; current; current = current.parentElement)
        if (current === element) return true;
      return false;
    },
  };
  return element;
}
function executeDomScript(script, controls, {
  width = 720,
  height = 900,
  scrollWidth = width,
  appearance = "light",
  persisted = appearance,
} = {}, args = []) {
  const root = domElement(
    { left: 0, top: 0, right: width, bottom: height, width, height },
    { colorScheme: appearance, backgroundColor: appearance === "dark" ? "rgb(0, 0, 0)" : "rgb(255, 255, 255)" },
  );
  root.dataset = { appearance };
  root.scrollWidth = scrollWidth;
  const document = {
    documentElement: root,
    body: { scrollWidth },
    querySelectorAll: () => controls,
  };
  const context = {
    __args: args,
    document,
    window: { innerWidth: width, innerHeight: height },
    getComputedStyle: (element) => element.style,
    localStorage: { getItem: () => persisted },
  };
  return vm.runInNewContext(
    `(function () { ${script} }).apply(null, __args)`,
    context,
  );
}

test("P-36 DOM probes detect real overlap, clipping, contrast, and persistence failures", () => {
  const first = domElement({ left: 10, top: 10, right: 110, bottom: 50, width: 100, height: 40 });
  const second = domElement({ left: 120, top: 10, right: 220, bottom: 50, width: 100, height: 40 });
  const clean = executeDomScript(P36_LAYOUT_SCRIPT, [first, second], {}, ["compact"]);
  assert.deepEqual(
    { overlap: clean.overlappingControls, clipped: clean.clippedCount, overflow: clean.horizontalOverflow },
    { overlap: 0, clipped: 0, overflow: 0 },
  );
  const overlapping = domElement({ left: 80, top: 20, right: 180, bottom: 60, width: 100, height: 40 });
  assert.equal(executeDomScript(P36_LAYOUT_SCRIPT, [first, overlapping], {}, ["compact"]).overlappingControls, 1);
  const clipParent = domElement(
    { left: 0, top: 0, right: 100, bottom: 100, width: 100, height: 100 },
    { overflow: "hidden", overflowX: "hidden" },
  );
  const clipped = domElement({ left: 20, top: 10, right: 140, bottom: 50, width: 120, height: 40 }, {}, clipParent);
  assert.equal(executeDomScript(P36_LAYOUT_SCRIPT, [clipped], {}, ["compact"]).clippedCount, 1);

  const lightBackground = domElement(
    { left: 0, top: 0, right: 300, bottom: 200, width: 300, height: 200 },
    { backgroundColor: "rgb(255, 255, 255)" },
  );
  const highContrast = domElement({ left: 10, top: 10, right: 110, bottom: 50, width: 100, height: 40 }, { color: "rgb(0, 0, 0)" }, lightBackground);
  const theme = executeDomScript(P36_THEME_SCRIPT, [highContrast], { appearance: "light", persisted: "light" }, ["light"]);
  assert.equal(theme.contrastRatio, 21);
  assert.equal(theme.persisted, true);
  assert.equal(theme.nativeControlScheme, "light");
  const lowContrast = domElement({ left: 10, top: 60, right: 110, bottom: 100, width: 100, height: 40 }, { color: "rgb(190, 190, 190)" }, lightBackground);
  assert.ok(executeDomScript(P36_THEME_SCRIPT, [lowContrast], { appearance: "light" }, ["light"]).contrastRatio < 4.5);
  assert.equal(executeDomScript(P36_THEME_SCRIPT, [highContrast], { appearance: "light", persisted: "dark" }, ["light"]).persisted, false);
});

test("P-36 production source pins exact viewport convergence and isolated motion state", () => {
  const source = fs.readFileSync(path.join(process.cwd(), "scripts/linux-port/run-p36-native-visual-polish-probes.mjs"), "utf8");
  assert.match(source, /for \(let attempt = 0; attempt < 5; attempt \+= 1\)/u);
  assert.match(source, /window\.innerWidth,height:window\.innerHeight/u);
  assert.match(source, /outerWidth \+= width - measured\.width/u);
  assert.match(source, /could not establish \$\{width\}x\$\{height\} DOM viewport/u);
  assert.match(source, /GSETTINGS_BACKEND: "keyfile"/u);
  assert.match(source, /org\.gnome\.desktop\.interface/u);
  assert.match(source, /themeState: \(\) =>[\s\S]*persisted:localStorage\.getItem/u);
});

test("P-36 reduced-motion workflow is desktop-neutral for KDE and Sway", async () => {
  const environments = [
    { environmentId: "fedora-kde-wayland-x86_64", packageFormat: "rpm", desktop: "KDE Plasma", displayServer: "Wayland", compositor: "KWin", manager: "rpm", packageName: "open-burn-bar" },
    { environmentId: "arch-sway-wayland-x86_64", packageFormat: "arch", desktop: "Sway/wlroots", displayServer: "Wayland", compositor: "Sway/wlroots", manager: "pacman", packageName: "openburnbar" },
  ];
  for (const row of environments) {
    const root = fs.mkdtempSync(path.join(TEMP_ROOT, "non-gnome-"));
    try {
      const opts = options(root, row);
      const result = await runP36VisualPolishWorkflow(opts, fakeDependencies({
        identity: () => ({ packageManager: row.manager, packageName: row.packageName, packageOwned: true }),
      }));
      assert.equal(result.transcript.packageFacts.desktop, row.desktop);
      assert.equal(result.transcript.motion.reduced, true);
      assert.equal(result.transcript.motion.preferenceRestored, true);
      assert.equal(result.transcript.restoration.motionPreferenceAfter, false);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
});

test("P-36 workflow rejects every incomplete keyboard overflow receipt before evidence is written", async () => {
  const mutations = [
    { keyboardOnly: false }, { distinctFocusTargets: 2 }, { focusVisible: false },
    { overflowOpened: false }, { arrowNavigation: false }, { escapeRestoredFocus: false },
  ];
  for (const mutation of mutations) {
    const root = fs.mkdtempSync(path.join(TEMP_ROOT, "keyboard-"));
    try {
      await assert.rejects(
        runP36VisualPolishWorkflow(options(root), fakeDependencies({ async interaction() { return interactionReceipt(mutation); } })),
        /keyboard overflow interaction failed/u,
      );
      assert.equal(fs.existsSync(path.join(options(root).rawOutputDir, "visual-native-transcript.json")), false);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
});

test("P-36 workflow rejects dishonest theme persistence before evidence is written", async () => {
  const cases = [
    {
      async theme(mode) {
        return { appearance: mode, contrastRatio: 7.2, nativeControlCount: 2, nativeControlScheme: mode, persisted: mode !== "light" };
      },
    },
    { themeState: async () => ({ appearance: "dark", persisted: "light" }) },
  ];
  for (const overrides of cases) {
    const root = fs.mkdtempSync(path.join(TEMP_ROOT, "theme-"));
    try {
      await assert.rejects(
        runP36VisualPolishWorkflow(options(root), fakeDependencies(overrides)),
        /live theme failed|did not survive installed restart/u,
      );
      assert.equal(fs.existsSync(path.join(options(root).rawOutputDir, "visual-native-transcript.json")), false);
    } finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
});
test("P-36 production contract proves responsive polish, themes, motion, keyboard, restart, and restoration", async () => {
  const value = await fixture();
  try {
    assert.equal(value.deps.restored(), 1);
    assert.equal(
      validateP36InstalledSession(value.session, binding(value)).document
        .requirementId,
      "P-36",
    );
    const captured = captureP36VisualPolishProof(
      {
        ...binding(value),
        inputRoot: value.input,
        sessionReport: value.sessionFile,
      },
      { resolveHead: () => HEAD, now: () => new Date() },
    );
    assert.equal(captured.document.claim.responsiveLayouts, true);
    validateP36Proof({
      ...binding(value),
      snapshot: { bytes: fs.readFileSync(captured.output) },
    });
    assert.throws(
      () =>
        validateP36Proof({
          ...binding(value),
          manifestSha256: "f".repeat(64),
          snapshot: { bytes: fs.readFileSync(captured.output) },
        }),
      /P-36/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
test("P-36 rejects overflow, overlap, weak contrast, dishonest theme/motion, broken focus/restart, replay, provenance, and restoration", async () => {
  const mutations = [
    (_v, n) => {
      n.layouts.compact.horizontalOverflow = 12;
    },
    (_v, n) => {
      n.layouts.standard.overlappingControls = 1;
    },
    (_v, n) => {
      n.themes.light.contrastRatio = 2.1;
    },
    (_v, n) => {
      n.themes.light.nativeControlScheme = "dark";
    },
    (_v, n) => {
      n.motion.animatedElements = 1;
    },
    (_v, n) => {
      n.interaction.escapeRestoredFocus = false;
    },
    (_v, n) => {
      n.restart.appearancePersisted = false;
    },
    (v, n) => {
      v.session.marker.challenge = "f".repeat(64);
      n.challenge = v.session.marker.challenge;
    },
    (v) => {
      v.session.marker.package.format = "rpm";
    },
    (_v, n) => {
      n.restoration.motionPreferenceAfter = true;
    },
  ];
  for (const mutate of mutations) {
    const value = await fixture();
    try {
      const nativeFile = path.join(
        value.root,
        value.session.evidence.nativeTranscript.path,
      );
      const native = JSON.parse(fs.readFileSync(nativeFile));
      mutate(value, native);
      json(nativeFile, native);
      refresh(value, "nativeTranscript", nativeFile);
      assert.throws(
        () => validateP36InstalledSession(value.session, binding(value)),
        /P-36/u,
      );
    } finally {
      fs.rmSync(value.root, { recursive: true, force: true });
    }
  }
});
test("P-36 rejects a screenshot that does not match its exact DPR-1 CSS viewport", async () => {
  const value = await fixture();
  try {
    const compactFile = path.join(
      value.root,
      value.session.evidence.compactLightScreenshot.path,
    );
    write(compactFile, png(719, 900, 91));
    refresh(value, "compactLightScreenshot", compactFile);
    assert.throws(
      () => validateP36InstalledSession(value.session, binding(value)),
      /P-36.*720x900|dimensions/u,
    );
  } finally {
    fs.rmSync(value.root, { recursive: true, force: true });
  }
});
test("P-36 workflow aggregates primary and restoration failures", async () => {
  const root = fs.mkdtempSync(path.join(TEMP_ROOT, "workflow-"));
  const opts = options(root);
  try {
    const deps = fakeDependencies({
      async layout(density) {
        if (density === "compact") throw new Error("forced layout failure");
        return {};
      },
      async restoreState() {
        throw new Error("forced restoration failure");
      },
    });
    await assert.rejects(
      () => runP36VisualPolishWorkflow(opts, deps),
      (error) => error instanceof AggregateError && error.errors.length === 2,
    );
  } finally {
    fs.rmSync(root, { recursive: true, force: true });
  }
});
test("P-36 workflow fails on cleanup-only errors and restored-topology drift", async () => {
  const cleanupRoot = fs.mkdtempSync(path.join(TEMP_ROOT, "cleanup-"));
  try {
    await assert.rejects(
      runP36VisualPolishWorkflow(options(cleanupRoot), fakeDependencies({
        async terminate() { throw new Error("forced driver cleanup failure"); },
      })),
      (error) => error instanceof AggregateError && error.errors.length === 1 && /cleanup/u.test(error.errors[0].message),
    );
  } finally { fs.rmSync(cleanupRoot, { recursive: true, force: true }); }

  const topologyRoot = fs.mkdtempSync(path.join(TEMP_ROOT, "topology-"));
  let inspections = 0;
  try {
    await assert.rejects(
      runP36VisualPolishWorkflow(options(topologyRoot), fakeDependencies({
        desktopPids() { inspections += 1; return inspections === 1 ? [] : [4242]; },
      })),
      (error) => error instanceof AggregateError && error.errors.some((entry) => /exact restoration failed/u.test(entry.message)),
    );
  } finally { fs.rmSync(topologyRoot, { recursive: true, force: true }); }

  const stateRoot = fs.mkdtempSync(path.join(TEMP_ROOT, "state-"));
  const stateOptions = options(stateRoot);
  try {
    await assert.rejects(
      runP36VisualPolishWorkflow(stateOptions, fakeDependencies({
        async launch() { write(path.join(stateOptions.stateHome, "leaked-state"), "not restored\n"); },
        async restoreState() {},
      })),
      (error) => error instanceof AggregateError && error.errors.some((entry) => /exact restoration failed/u.test(entry.message)),
    );
  } finally { fs.rmSync(stateRoot, { recursive: true, force: true }); }
});
