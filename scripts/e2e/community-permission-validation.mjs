#!/usr/bin/env node
import { spawnSync } from "node:child_process";
import { mkdirSync, writeFileSync } from "node:fs";
import { dirname, resolve } from "node:path";
import { fileURLToPath, pathToFileURL } from "node:url";

const DEFAULTS = Object.freeze({
  androidPackage: "com.openburnbar",
  appleBundleId: "ai.burnbar.OpenBurnBar",
  iosBundleId: "ai.burnbar.OpenBurnBarMobile",
  windowsAumid: "OpenBurnBar.App_8wekyb3d8bbwe!App",
  evidenceDir: "artifacts/community-permission-validation",
});

const PLATFORM_SET = new Set(["android", "ios", "macos", "windows", "all"]);
const MODE_SET = new Set(["denied", "granted", "unavailable", "all"]);

function usage() {
  console.log(`Usage: node scripts/e2e/community-permission-validation.mjs [options]

Builds or executes the real-device Community location-permission validation matrix.
Default mode is dry-run: it prints exact platform steps and evidence requirements without mutating devices.

Options:
  --platform <android|ios|macos|windows|all>  Platform to validate. Repeatable; default all.
  --mode <denied|granted|unavailable|all>     Permission state to validate. Repeatable; default all.
  --execute                                  Run safe automated steps where the OS allows it.
  --android-package <id>                     Android app id. Default ${DEFAULTS.androidPackage}.
  --apple-bundle-id <id>                     macOS bundle id. Default ${DEFAULTS.appleBundleId}.
  --ios-bundle-id <id>                       iOS bundle id. Default ${DEFAULTS.iosBundleId}.
  --windows-aumid <id>                       Windows app AUMID. Default ${DEFAULTS.windowsAumid}.
  --device <id>                              Android adb serial or iOS devicectl identifier.
  --evidence-dir <path>                      Screenshot/log output directory. Default ${DEFAULTS.evidenceDir}.
  --json                                     Emit JSON only.
  --help                                    Show this help.
`);
}

export function parseArgs(argv = process.argv) {
  const options = {
    platforms: [],
    modes: [],
    execute: false,
    json: false,
    androidPackage: DEFAULTS.androidPackage,
    appleBundleId: DEFAULTS.appleBundleId,
    iosBundleId: DEFAULTS.iosBundleId,
    windowsAumid: DEFAULTS.windowsAumid,
    device: "",
    evidenceDir: DEFAULTS.evidenceDir,
  };

  for (let index = 2; index < argv.length; index += 1) {
    const arg = argv[index];
    if (arg === "--help" || arg === "-h") {
      usage();
      process.exit(0);
    }
    if (arg === "--execute") {
      options.execute = true;
      continue;
    }
    if (arg === "--json") {
      options.json = true;
      continue;
    }
    if (arg === "--platform") {
      const platform = requireValue(argv, ++index, arg);
      assertOneOf(platform, PLATFORM_SET, arg);
      options.platforms.push(platform);
      continue;
    }
    if (arg === "--mode") {
      const mode = requireValue(argv, ++index, arg);
      assertOneOf(mode, MODE_SET, arg);
      options.modes.push(mode);
      continue;
    }
    if (arg === "--android-package") {
      options.androidPackage = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--apple-bundle-id") {
      options.appleBundleId = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--ios-bundle-id") {
      options.iosBundleId = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--windows-aumid") {
      options.windowsAumid = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--device") {
      options.device = requireValue(argv, ++index, arg);
      continue;
    }
    if (arg === "--evidence-dir") {
      options.evidenceDir = requireValue(argv, ++index, arg);
      continue;
    }
    throw new Error(`unknown argument: ${arg}`);
  }

  options.platforms = expandAll(options.platforms, ["android", "ios", "macos", "windows"]);
  options.modes = expandAll(options.modes, ["denied", "granted", "unavailable"]);
  options.evidenceDir = resolve(options.evidenceDir);
  return options;
}

function requireValue(argv, index, flag) {
  const value = argv[index];
  if (!value || value.startsWith("--")) throw new Error(`${flag} requires a value`);
  return value;
}

function assertOneOf(value, allowed, flag) {
  if (!allowed.has(value)) throw new Error(`${flag} must be one of ${[...allowed].join(", ")}`);
}

function expandAll(values, concrete) {
  if (values.length === 0 || values.includes("all")) return concrete;
  return [...new Set(values)];
}

function evidencePath(options, platform, mode, suffix) {
  return resolve(options.evidenceDir, `${platform}-${mode}.${suffix}`);
}

function command(label, commandName, args, notes = []) {
  return { label, command: commandName, args, notes };
}

function manual(label, instruction) {
  return { label, instruction, manual: true };
}

function androidScenario(mode, options) {
  const adbArgs = options.device ? ["-s", options.device] : [];
  const base = {
    platform: "android",
    mode,
    objective: "Exercise ACCESS_COARSE_LOCATION denial/grant while joining the Community city tier.",
    expectedTelemetry: "No raw latitude/longitude leaves the device; denied/unavailable keeps cityKey absent.",
    evidence: [
      evidencePath(options, "android", mode, "png"),
      evidencePath(options, "android", mode, "logcat.txt"),
    ],
    commands: [],
    checklist: [],
  };

  if (mode === "denied") {
    base.commands.push(
      command("reset package permission state", "adb", [...adbArgs, "shell", "pm", "reset-permissions"]),
      command("force coarse location denied", "adb", [...adbArgs, "shell", "appops", "set", options.androidPackage, "COARSE_LOCATION", "deny"]),
      command("launch Community deep link", "adb", [...adbArgs, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "burnbar://community"]),
      command("capture screenshot", "adb", [...adbArgs, "exec-out", "screencap", "-p"], [`redirect stdout to ${base.evidence[0]}`]),
      command("capture Community logcat", "adb", [...adbArgs, "logcat", "-d", "-v", "time"], [`redirect stdout to ${base.evidence[1]}`]),
    );
    base.checklist.push("Enable L2 + City tier, deny the Android approximate-location prompt, save, and verify the UI says city sharing is off while broader tiers remain available.");
  } else if (mode === "granted") {
    base.commands.push(
      command("grant coarse location", "adb", [...adbArgs, "shell", "pm", "grant", options.androidPackage, "android.permission.ACCESS_COARSE_LOCATION"], ["Some release builds require granting through the OS prompt instead."]),
      command("force app-op allow", "adb", [...adbArgs, "shell", "appops", "set", options.androidPackage, "COARSE_LOCATION", "allow"]),
      command("launch Community deep link", "adb", [...adbArgs, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "burnbar://community"]),
      command("capture screenshot", "adb", [...adbArgs, "exec-out", "screencap", "-p"], [`redirect stdout to ${base.evidence[0]}`]),
    );
    base.checklist.push("Enable L2 + City tier, grant approximate location, save, and verify the UI resolves a canonical city key without showing coordinates.");
  } else {
    base.commands.push(
      command("disable device location globally", "adb", [...adbArgs, "shell", "cmd", "location", "set-location-enabled", "false"], ["Re-enable with: adb shell cmd location set-location-enabled true"]),
      command("launch Community deep link", "adb", [...adbArgs, "shell", "am", "start", "-a", "android.intent.action.VIEW", "-d", "burnbar://community"]),
      command("capture screenshot", "adb", [...adbArgs, "exec-out", "screencap", "-p"], [`redirect stdout to ${base.evidence[0]}`]),
    );
    base.checklist.push("Attempt city join with device Location disabled and verify the unavailable state keeps cityKey absent and does not block world/country/region tiers.");
  }
  return base;
}

function iosScenario(mode, options) {
  const target = options.device ? ["--device", options.device] : [];
  const base = {
    platform: "ios",
    mode,
    objective: "Validate iPhone/iPad reduced-accuracy CoreLocation gating for the Community city tier.",
    expectedTelemetry: "The app stores only country/region/city keys; raw coordinates are never persisted or exported.",
    evidence: [evidencePath(options, "ios", mode, "png")],
    commands: [
      command("launch app on physical device", "xcrun", ["devicectl", "device", "process", "launch", ...target, options.iosBundleId], ["Use manual launch if devicectl cannot target the signed build."]),
    ],
    checklist: [],
  };
  if (mode === "denied") {
    base.checklist.push("Settings → Privacy & Security → Location Services → BurnBar → Never, then enable L2 + City and verify city remains off with explicit copy.");
  } else if (mode === "granted") {
    base.checklist.push("Settings → Privacy & Security → Location Services → BurnBar → While Using, Precise Location off, then enable L2 + City and verify approximate city copy plus resolved city key.");
  } else {
    base.checklist.push("Disable Location Services globally, open Community, enable L2 + City, and verify unavailable state falls back to broader tiers without prompting in a loop.");
  }
  return base;
}

function macosScenario(mode, options) {
  const base = {
    platform: "macos",
    mode,
    objective: "Validate macOS TCC location denial/grant around Community city tier joins.",
    expectedTelemetry: "Only canonical geo keys are sent in join payloads; no coordinate fields appear in logs or Firestore writes.",
    evidence: [evidencePath(options, "macos", mode, "png")],
    commands: [
      command("reset app location TCC", "tccutil", ["reset", "Location", options.appleBundleId]),
      command("open Community surface", "open", ["burnbar://community"]),
    ],
    checklist: [],
  };
  if (mode === "denied") {
    base.checklist.push("Deny the macOS location prompt, save city-tier consent, and verify the UI keeps city rank paused with country/region still available.");
  } else if (mode === "granted") {
    base.checklist.push("Grant approximate location when prompted, save, and verify the city-confidence copy states that only a city key is stored.");
  } else {
    base.checklist.push("Turn Location Services off in System Settings, save, and verify the unavailable copy plus no repeated prompts.");
  }
  return base;
}

function windowsScenario(mode, options) {
  const base = {
    platform: "windows",
    mode,
    objective: "Validate Windows.Devices.Geolocation denied/unavailable handling for Community city tier joins.",
    expectedTelemetry: "TryResolveCityKeyAsync returns null unless GeolocationAccessStatus.Allowed and an address with city+country is available.",
    evidence: [evidencePath(options, "windows", mode, "png")],
    commands: [
      command("open Windows location privacy settings", "powershell.exe", ["-NoProfile", "-Command", "Start-Process ms-settings:privacy-location"]),
      command("launch BurnBar", "powershell.exe", ["-NoProfile", "-Command", `Start-Process shell:AppsFolder\\${options.windowsAumid}`]),
    ],
    checklist: [],
  };
  if (mode === "denied") {
    base.checklist.push("Disable location access for OpenBurnBar only, enable L2 + City, and verify the UI reports city unavailable without inventing a city.");
  } else if (mode === "granted") {
    base.checklist.push("Enable Windows location access for OpenBurnBar, save city tier, and verify the resolved city-confidence copy appears without raw coordinates.");
  } else {
    base.checklist.push("Turn Location services off globally or run on a VM without location provider, save, and verify city tier falls back to broader boards.");
  }
  return base;
}

export function buildValidationMatrix(options) {
  const builders = { android: androidScenario, ios: iosScenario, macos: macosScenario, windows: windowsScenario };
  const scenarios = [];
  for (const platform of options.platforms) {
    for (const mode of options.modes) {
      scenarios.push(builders[platform](mode, options));
    }
  }
  return {
    generatedAt: new Date().toISOString(),
    execute: options.execute,
    evidenceDir: options.evidenceDir,
    scenarios,
  };
}

function formatCommand(step) {
  if (step.manual) return `MANUAL: ${step.instruction}`;
  const quoted = step.args.map((arg) => (/[\s"'\\]/.test(arg) ? JSON.stringify(arg) : arg)).join(" ");
  return `${step.command} ${quoted}`.trim();
}

function printMatrix(matrix) {
  console.log("Community real-device location-permission validation");
  console.log(`Evidence directory: ${matrix.evidenceDir}`);
  for (const scenario of matrix.scenarios) {
    console.log(`\n## ${scenario.platform} / ${scenario.mode}`);
    console.log(scenario.objective);
    console.log(`Expected: ${scenario.expectedTelemetry}`);
    for (const step of scenario.commands) {
      console.log(`- ${step.label}: ${formatCommand(step)}`);
      for (const note of step.notes ?? []) console.log(`  note: ${note}`);
    }
    for (const item of scenario.checklist) console.log(`- verify: ${item}`);
    for (const item of scenario.evidence) console.log(`- evidence: ${item}`);
  }
}

function executeMatrix(matrix) {
  mkdirSync(matrix.evidenceDir, { recursive: true });
  const results = [];
  for (const scenario of matrix.scenarios) {
    for (const step of scenario.commands) {
      if (step.manual) continue;
      const capturePath = step.notes?.find((note) => note.startsWith("redirect stdout to "))?.replace("redirect stdout to ", "");
      const result = spawnSync(step.command, step.args, { encoding: capturePath ? "buffer" : "utf8" });
      if (capturePath && result.stdout) {
        mkdirSync(dirname(capturePath), { recursive: true });
        writeFileSync(capturePath, result.stdout);
      }
      results.push({
        platform: scenario.platform,
        mode: scenario.mode,
        label: step.label,
        command: [step.command, ...step.args],
        status: result.status,
        signal: result.signal,
        stderr: Buffer.isBuffer(result.stderr) ? result.stderr.toString("utf8") : result.stderr,
      });
    }
  }
  return results;
}

export async function main(argv = process.argv) {
  const options = parseArgs(argv);
  const matrix = buildValidationMatrix(options);
  if (options.json) {
    console.log(JSON.stringify(matrix, null, 2));
  } else {
    printMatrix(matrix);
  }
  if (options.execute) {
    const results = executeMatrix(matrix);
    const failed = results.filter((result) => result.status !== 0);
    if (!options.json) console.log(`\nExecuted ${results.length} command(s); ${failed.length} failed.`);
    if (failed.length > 0) process.exitCode = 1;
  }
}

if (import.meta.url === pathToFileURL(process.argv[1] ?? "").href) {
  main().catch((error) => {
    console.error(error instanceof Error ? error.message : error);
    process.exit(1);
  });
}
