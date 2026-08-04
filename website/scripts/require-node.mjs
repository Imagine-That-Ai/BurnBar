#!/usr/bin/env node

const required = { major: 22, minor: 22, patch: 3 };

function parseVersion(raw) {
  const match = /^v?(\d+)\.(\d+)\.(\d+)/.exec(raw);
  if (!match) return null;
  return {
    major: Number(match[1]),
    minor: Number(match[2]),
    patch: Number(match[3]),
  };
}

function isAtLeast(current, minimum) {
  if (current.major !== minimum.major) return current.major > minimum.major;
  if (current.minor !== minimum.minor) return current.minor > minimum.minor;
  return current.patch >= minimum.patch;
}

const current = parseVersion(process.version);

if (!current || !isAtLeast(current, required)) {
  console.error(
    [
      "OpenBurnBar website requires Node >=22.22.3.",
      `Current Node is ${process.version}.`,
      "Run `nvm use` from the repo root or website/ before running website commands.",
    ].join("\n"),
  );
  process.exit(1);
}
