import assert from "node:assert/strict";
import fs from "node:fs";
import os from "node:os";
import path from "node:path";
import { spawnSync } from "node:child_process";
import test from "node:test";
import { fileURLToPath } from "node:url";

const ROOT = path.resolve(path.dirname(fileURLToPath(import.meta.url)), "../..");
const HOST_SCRIPT = path.join(ROOT, "scripts/linux-port/utm-ephemeral-github-runner.sh");
const GUEST_SCRIPT = path.join(ROOT, "scripts/linux-port/utm-ephemeral-github-runner-guest.sh");
const ENVIRONMENT = "ubuntu-24.04-gnome-x11-aarch64";
const VM_UUID = "7923D0DD-6367-45EA-9064-152EECC1AC65";
const SECRET = "AAAA_mock_short_lived_runner_token_123456789";

function writeExecutable(file, body) {
  fs.writeFileSync(file, `#!/bin/bash\nset -euo pipefail\n${body}\n`, { mode: 0o700 });
}

function fixture({ status = "started", token = SECRET, failSshAction = "" } = {}) {
  const root = fs.mkdtempSync(path.join(os.homedir(), ".burnbar-utm-runner-test-"));
  fs.chmodSync(root, 0o700);
  const bin = path.join(root, "bin");
  const home = path.join(root, "home");
  const sshDir = path.join(home, ".ssh");
  const calls = path.join(root, "calls");
  fs.mkdirSync(bin, { mode: 0o700 });
  fs.mkdirSync(home, { mode: 0o700 });
  fs.mkdirSync(sshDir, { mode: 0o700 });
  fs.mkdirSync(calls, { mode: 0o700 });
  fs.writeFileSync(path.join(sshDir, "key"), "private-key-fixture\n", { mode: 0o600 });
  fs.writeFileSync(path.join(sshDir, "known_hosts"), "host-key-fixture\n", { mode: 0o600 });

  writeExecutable(path.join(bin, "uname"), `
case "\${1:-}" in
  -s) printf 'Darwin\\n' ;;
  -m) printf 'arm64\\n' ;;
  *) exit 2 ;;
esac`);
  writeExecutable(path.join(bin, "utmctl"), `
printf '%q ' "$@" >> "$MOCK_CALLS/utmctl.argv"
printf '\\n' >> "$MOCK_CALLS/utmctl.argv"
[[ "\${1:-}" == "status" ]] || exit 93
printf '%s\\n' "$MOCK_UTM_STATUS"`);
  writeExecutable(path.join(bin, "gh"), `
printf '%q ' "$@" >> "$MOCK_CALLS/gh.argv"
printf '\\n' >> "$MOCK_CALLS/gh.argv"
if [[ "\${1:-}" == "repo" ]]; then
  printf 'Imagine-That-Ai/BurnBar\\n'
elif [[ "\${1:-}" == "api" ]]; then
  printf '%s\\n' "$MOCK_TOKEN"
else
  exit 94
fi`);
  writeExecutable(path.join(bin, "ssh"), `
call_id="\$(printf '%04d' "\$(($(find "$MOCK_CALLS" -name 'ssh.*.argv' | wc -l) + 1))")"
printf '%q ' "$@" > "$MOCK_CALLS/ssh.$call_id.argv"
printf '\\n' >> "$MOCK_CALLS/ssh.$call_id.argv"
cat > "$MOCK_CALLS/ssh.$call_id.stdin"
if [[ -n "$MOCK_SSH_FAIL_ACTION" && " $* " == *" $MOCK_SSH_FAIL_ACTION "* ]]; then
  exit 95
fi
printf 'mock-ssh-ok\\n'`);

  return {
    root,
    env: {
      ...process.env,
      HOME: home,
      PATH: `${bin}:${process.env.PATH}`,
      MOCK_CALLS: calls,
      MOCK_TOKEN: token,
      MOCK_UTM_STATUS: status,
      MOCK_SSH_FAIL_ACTION: failSshAction,
    },
    calls,
    key: path.join(sshDir, "key"),
    knownHosts: path.join(sshDir, "known_hosts"),
  };
}

function execute(fx, operation, extra = []) {
  return spawnSync("bash", [
    HOST_SCRIPT,
    operation,
    "--vm",
    VM_UUID,
    "--environment",
    ENVIRONMENT,
    "--ssh-key",
    fx.key,
    "--known-hosts",
    fx.knownHosts,
    ...extra,
  ], {
    cwd: ROOT,
    env: fx.env,
    encoding: "utf8",
  });
}

function callContents(directory, suffix) {
  return fs.readdirSync(directory)
    .filter((entry) => entry.endsWith(suffix))
    .sort()
    .map((entry) => fs.readFileSync(path.join(directory, entry), "utf8"));
}

test("pins the Linux arm64 runner and exact no-default-label contract", () => {
  const host = fs.readFileSync(HOST_SCRIPT, "utf8");
  const guest = fs.readFileSync(GUEST_SCRIPT, "utf8");
  assert.match(guest, /RUNNER_VERSION="2\.336\.0"/u);
  assert.match(guest, /RUNNER_SHA256="58b758e420b87093fbd4bfddd368074960053e2f1388f01848c82624b90f27d1"/u);
  assert.match(guest, /EXPECTED_LABELS="self-hosted,linux,ubuntu-24\.04-gnome-x11-aarch64"/u);
  for (const flag of ["--ephemeral", "--disableupdate", "--no-default-labels"]) {
    assert.ok(guest.includes(flag), `missing ${flag}`);
  }
  assert.match(guest, /--labels "\$EXPECTED_LABELS"/u);
  assert.doesNotMatch(guest, /--token/u);
  assert.match(guest, /ACTIONS_RUNNER_INPUT_TOKEN="\$token"/u);
  assert.doesNotMatch(host, /utmctl start/u);
  assert.match(guest, /installed_version=.*Runner\.Listener" --version/u);
  assert.match(guest, /--setenv "PATH=\$graphical_path"/u);
  assert.match(guest, /environment_value XDG_SESSION_DESKTOP/u);
  assert.match(guest, /--setenv "XDG_SESSION_DESKTOP=\$graphical_session_desktop"/u);
});

test("start obtains the repository token after preflight and never puts it in argv or output", () => {
  const fx = fixture();
  try {
    const result = execute(fx, "start");
    assert.equal(result.status, 0, result.stderr);
    assert.doesNotMatch(`${result.stdout}${result.stderr}`, new RegExp(SECRET, "u"));

    const ghCalls = fs.readFileSync(path.join(fx.calls, "gh.argv"), "utf8");
    assert.match(ghCalls, /repos\/Imagine-That-Ai\/BurnBar\/actions\/runners\/registration-token/u);
    const utmCalls = fs.readFileSync(path.join(fx.calls, "utmctl.argv"), "utf8");
    assert.match(utmCalls, /^status /u);
    assert.doesNotMatch(utmCalls, /start/u);

    const sshArgv = callContents(fx.calls, ".argv").filter((value) => value.includes("BatchMode"));
    assert.ok(sshArgv.some((value) => value.includes("preflight-start")));
    assert.ok(sshArgv.some((value) => /guest\.sh.*\\ start\\/u.test(value)));
    assert.equal(sshArgv.every((value) => !value.includes(SECRET)), true);

    const sshStdin = callContents(fx.calls, ".stdin");
    assert.equal(sshStdin.filter((value) => value.trim() === SECRET).length, 1);
  } finally {
    fs.rmSync(fx.root, { recursive: true, force: true });
  }
});

test("teardown uses a repository removal token and the teardown guest action", () => {
  const fx = fixture();
  try {
    const result = execute(fx, "teardown");
    assert.equal(result.status, 0, result.stderr);
    const ghCalls = fs.readFileSync(path.join(fx.calls, "gh.argv"), "utf8");
    assert.match(ghCalls, /repos\/Imagine-That-Ai\/BurnBar\/actions\/runners\/remove-token/u);
    const sshArgv = callContents(fx.calls, ".argv").filter((value) => value.includes("BatchMode"));
    assert.ok(sshArgv.some((value) => value.includes("preflight-teardown")));
    assert.ok(sshArgv.some((value) => /guest\.sh.*\\ teardown\\/u.test(value)));
    assert.equal(sshArgv.every((value) => !value.includes(SECRET)), true);
  } finally {
    fs.rmSync(fx.root, { recursive: true, force: true });
  }
});

test("a failed start obtains a removal token and runs teardown rollback", () => {
  const fx = fixture({ failSshAction: "start" });
  try {
    const result = execute(fx, "start");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /registered state was unregistered and removed/u);
    const ghCalls = fs.readFileSync(path.join(fx.calls, "gh.argv"), "utf8");
    assert.match(ghCalls, /registration-token/u);
    assert.match(ghCalls, /remove-token/u);
    const sshArgv = callContents(fx.calls, ".argv").filter((value) => value.includes("BatchMode"));
    assert.ok(sshArgv.some((value) => /guest\.sh.*\\ preflight-teardown\\/u.test(value)));
    assert.ok(sshArgv.some((value) => /guest\.sh.*\\ teardown\\/u.test(value)));
  } finally {
    fs.rmSync(fx.root, { recursive: true, force: true });
  }
});

test("refuses unsupported VM and environment identities before external calls", () => {
  const fx = fixture();
  try {
    const wrongVm = spawnSync("bash", [
      HOST_SCRIPT,
      "start",
      "--vm",
      "some-other-vm",
      "--environment",
      ENVIRONMENT,
    ], { cwd: ROOT, env: fx.env, encoding: "utf8" });
    assert.notEqual(wrongVm.status, 0);
    assert.match(wrongVm.stderr, /documented OpenBurnBar Linux name or UUID/u);

    const wrongEnvironment = spawnSync("bash", [
      HOST_SCRIPT,
      "start",
      "--vm",
      VM_UUID,
      "--environment",
      "ubuntu-24.04-gnome-wayland-aarch64",
    ], { cwd: ROOT, env: fx.env, encoding: "utf8" });
    assert.notEqual(wrongEnvironment.status, 0);
    assert.match(wrongEnvironment.stderr, /unsupported canonical environment id/u);
    assert.equal(fs.readdirSync(fx.calls).length, 0);
  } finally {
    fs.rmSync(fx.root, { recursive: true, force: true });
  }
});

test("refuses stopped guests, symlinked keys, and group-readable key material", () => {
  const stopped = fixture({ status: "stopped" });
  try {
    const result = execute(stopped, "start");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /not already running/u);
    assert.equal(fs.existsSync(path.join(stopped.calls, "gh.argv")), false);
  } finally {
    fs.rmSync(stopped.root, { recursive: true, force: true });
  }

  const linked = fixture();
  try {
    const realKey = linked.key;
    const linkedKey = path.join(path.dirname(realKey), "linked-key");
    fs.symlinkSync(realKey, linkedKey);
    linked.key = linkedKey;
    const result = execute(linked, "start");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not contain symlinks/u);
  } finally {
    fs.rmSync(linked.root, { recursive: true, force: true });
  }

  const readable = fixture();
  try {
    fs.chmodSync(readable.key, 0o640);
    const result = execute(readable, "start");
    assert.notEqual(result.status, 0);
    assert.match(result.stderr, /must not be accessible by group or world/u);
  } finally {
    fs.rmSync(readable.root, { recursive: true, force: true });
  }
});

test("requires the exact UTM started status and accepts a public-readable known_hosts file", () => {
  for (const status of ["not started", "started\nstopped", "Started", "running"]) {
    const fx = fixture({ status });
    try {
      const result = execute(fx, "start");
      assert.notEqual(result.status, 0, `unexpectedly accepted status ${JSON.stringify(status)}`);
      assert.match(result.stderr, /not already running/u);
      assert.equal(fs.existsSync(path.join(fx.calls, "gh.argv")), false);
    } finally {
      fs.rmSync(fx.root, { recursive: true, force: true });
    }
  }

  const publicKnownHosts = fixture();
  try {
    fs.chmodSync(publicKnownHosts.knownHosts, 0o644);
    const result = execute(publicKnownHosts, "start");
    assert.equal(result.status, 0, result.stderr);
  } finally {
    fs.rmSync(publicKnownHosts.root, { recursive: true, force: true });
  }
});

test("attempts helper cleanup when the staging SSH command loses the connection", () => {
  const fx = fixture({ failSshAction: "sha256sum" });
  try {
    const result = execute(fx, "start");
    assert.notEqual(result.status, 0);
    const sshArgv = callContents(fx.calls, ".argv").filter((value) => value.includes("BatchMode"));
    assert.equal(sshArgv.length, 2);
    assert.ok(sshArgv.some((value) => value.includes("rmdir")));
    const ghCalls = fs.readFileSync(path.join(fx.calls, "gh.argv"), "utf8");
    assert.doesNotMatch(ghCalls, /registration-token/u);
  } finally {
    fs.rmSync(fx.root, { recursive: true, force: true });
  }
});

test("guest lifecycle fails closed on architecture, distro, desktop, session, and path trust", () => {
  const guest = fs.readFileSync(GUEST_SCRIPT, "utf8");
  assert.match(guest, /\[\[ "\$distro" == "ubuntu" && "\$version" == "24\.04" \]\]/u);
  assert.match(guest, /\[\[ "\$architecture" == "aarch64" && "\$deb_arch" == "arm64" \]\]/u);
  assert.match(guest, /\$type" == "x11"/u);
  assert.match(guest, /\$desktop" == "GNOME" \|\| "\$desktop" == "ubuntu" \|\| "\$desktop" == "ubuntu:GNOME"/u);
  assert.match(guest, /expected exactly one active local GNOME X11 session/u);
  assert.match(guest, /assert_no_symlink_components/u);
  assert.match(guest, /runner state already exists; teardown it before starting another runner/u);
  assert.match(guest, /trap cleanup_temporary_state EXIT/u);
  assert.match(guest, /remove_partial_state="false"/u);
  assert.match(guest, /configuration failed; protected state was retained for teardown/u);
  assert.doesNotMatch(
    guest,
    /configuration failed;[\s\S]{0,120}rm -rf "\$state_root"/u,
  );
  assert.match(guest, /local runner registration is missing; refusing to claim unregistration/u);
  assert.match(guest, /validate_graphical_path/u);
  assert.match(guest, /canonical="\$\(readlink -f "\$entry"\)"/u);
  assert.match(guest, /graphical_path=.*canonical_entries/u);
  assert.match(guest, /systemd-run --user/u);
  assert.match(guest, /systemctl --user stop/u);
  assert.match(guest, /\.\/config\.sh remove/u);
  assert.match(guest, /rm -rf "\$state_root"/u);
});
