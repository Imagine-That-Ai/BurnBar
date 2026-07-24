import assert from "node:assert/strict";
import fs from "node:fs";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const SCRIPT = path.join(ROOT, "scripts/linux-port/install-tauri-webdriver-prerequisites.sh");
const TEMP_ROOT = path.join(ROOT, ".tmp/tauri-webdriver-plan-tests");
fs.mkdirSync(TEMP_ROOT, { recursive: true });
test.after(() => fs.rmSync(TEMP_ROOT, { recursive: true, force: true }));

function fixture(id, version = "") {
  const root = fs.mkdtempSync(path.join(TEMP_ROOT, "case-"));
  fs.writeFileSync(path.join(root, "os-release"), `ID=${id}\n${version ? `VERSION_ID="${version}"\n` : ""}`);
  fs.writeFileSync(path.join(root, "Cargo.lock"), `version = 4\n\n[[package]]\nname = "tauri"\nversion = "2.11.5"\nsource = "registry"\n\n[[package]]\nname = "other"\nversion = "1.0.0"\n`);
  return root;
}
function execute(root, ...args) {
  return spawnSync("bash", [SCRIPT, ...args, "--os-release", path.join(root, "os-release"), "--cargo-lock", path.join(root, "Cargo.lock")], { cwd: ROOT, encoding: "utf8" });
}
function lines(output) { return output.trim().split("\n"); }

test("Ubuntu 24.04 plan installs the separate native driver and pinned tauri-driver", () => {
  const root = fixture("ubuntu", "24.04");
  try {
    const result = execute(root, "--print-plan");
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(lines(result.stdout), [
      "distro=ubuntu", "distro_version=24.04", "tauri_version=2.11.5", "tauri_driver_version=2.0.6", "minimum_webkit_driver_version=2.40.0",
      "root_command=apt-get update", "root_command=apt-get install -y --no-install-recommends webkit2gtk-driver",
      "user_command=cargo install tauri-driver --version 2.0.6 --locked --force", "verify_command=tauri-driver --version", "verify_command=WebKitWebDriver --version",
      "ownership_command=dpkg-query -S /usr/bin/WebKitWebDriver", "expected_webkit_owner=webkit2gtk-driver",
    ]);
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("Fedora plan installs WebKit 4.1 plus the package that owns WebKitWebDriver", () => {
  const root = fixture("fedora", "43");
  try {
    const result = execute(root, "--print-plan");
    assert.equal(result.status, 0, result.stderr);
    assert.ok(lines(result.stdout).includes("root_command=dnf install -y webkit2gtk4.1 webkitgtk6.0"));
    assert.ok(lines(result.stdout).includes("ownership_command=rpm -qf --qf %{NAME} /usr/bin/WebKitWebDriver"));
    assert.ok(lines(result.stdout).includes("expected_webkit_owner=webkitgtk6.0"));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("Arch plan performs a signed full sync before installing both WebKit packages", () => {
  const root = fixture("arch");
  try {
    const result = execute(root, "--print-plan");
    assert.equal(result.status, 0, result.stderr);
    assert.deepEqual(lines(result.stdout).filter((line) => line.startsWith("root_command=")), [
      "root_command=pacman -Syu --noconfirm",
      "root_command=pacman -S --needed --noconfirm webkit2gtk-4.1 webkitgtk-6.0",
    ]);
    assert.ok(lines(result.stdout).includes("expected_webkit_owner=webkitgtk-6.0"));
    assert.ok(lines(result.stdout).includes("ownership_command=pacman -Qoq /usr/bin/WebKitWebDriver"));
  } finally { fs.rmSync(root, { recursive: true, force: true }); }
});

test("plans fail closed for unsupported distro, Ubuntu release, Tauri major, symlink, and duplicate modes", () => {
  const cases = [
    { id: "debian", version: "13", expected: /unsupported Linux distribution/u },
    { id: "ubuntu", version: "22.04", expected: /only Ubuntu 24\.04/u },
  ];
  for (const row of cases) {
    const root = fixture(row.id, row.version);
    try { const result = execute(root, "--print-plan"); assert.notEqual(result.status, 0); assert.match(result.stderr, row.expected); }
    finally { fs.rmSync(root, { recursive: true, force: true }); }
  }
  const major = fixture("fedora", "43");
  try {
    fs.writeFileSync(path.join(major, "Cargo.lock"), '[[package]]\nname = "tauri"\nversion = "1.8.3"\n');
    const result = execute(major, "--print-plan"); assert.notEqual(result.status, 0); assert.match(result.stderr, /stable Tauri 2\.x/u);
  } finally { fs.rmSync(major, { recursive: true, force: true }); }
  const linked = fixture("arch");
  try {
    fs.renameSync(path.join(linked, "os-release"), path.join(linked, "real-release"));
    fs.symlinkSync(path.join(linked, "real-release"), path.join(linked, "os-release"));
    const result = execute(linked, "--print-plan"); assert.notEqual(result.status, 0); assert.match(result.stderr, /regular file/u);
  } finally { fs.rmSync(linked, { recursive: true, force: true }); }
  const duplicate = fixture("arch");
  try { const result = execute(duplicate, "--check", "--print-plan"); assert.notEqual(result.status, 0); assert.match(result.stderr, /only one mode/u); }
  finally { fs.rmSync(duplicate, { recursive: true, force: true }); }
});

test("script statically pins exact versions, checks package ownership, and has no remote shell installer", () => {
  const source = fs.readFileSync(SCRIPT, "utf8");
  assert.match(source, /readonly TAURI_DRIVER_VERSION="2\.0\.6"/u);
  assert.match(source, /cargo install tauri-driver --version "\$\{TAURI_DRIVER_VERSION\}" --locked --force/u);
  assert.match(source, /dpkg-query -S/u);
  assert.match(source, /rpm -qf --qf '%\{NAME\}\\n'/u);
  assert.match(source, /pacman -Qoq/u);
  assert.match(source, /\[\[ "\$\{owner\}" == "\$\{EXPECTED_PACKAGE\}" \]\]/u);
  assert.match(source, /WebKitWebDriver --version/u);
  assert.match(source, /readlink -f/u);
  assert.doesNotMatch(source, /curl|wget/u);
});
