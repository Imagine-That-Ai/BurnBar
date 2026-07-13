#!/usr/bin/env node
/**
 * Fail if AUR packaging copies drift from canonical packaging/linux sources.
 * VAL-PATH-001 packaging integrity: unit + launch script must match what ships.
 */
import crypto from 'node:crypto';
import fs from 'node:fs';
import path from 'node:path';
import { fileURLToPath } from 'node:url';

const repoRoot = path.resolve(path.dirname(fileURLToPath(import.meta.url)), '../..');

const pairs = [
  {
    canonical: 'packaging/linux/openburnbar-daemon-launch.sh',
    copy: 'packaging/linux/aur/openburnbar-daemon-launch'
  },
  {
    canonical: 'packaging/linux/openburnbar-daemon.service',
    copy: 'packaging/linux/aur/openburnbar-daemon.service'
  },
  {
    canonical: 'packaging/linux/openburnbar.desktop',
    copy: 'packaging/linux/aur/openburnbar.desktop'
  },
  {
    canonical: 'packaging/linux/autostart/openburnbar.desktop',
    copy: 'packaging/linux/aur/openburnbar-autostart.desktop'
  }
];

function sha(file) {
  return crypto.createHash('sha256').update(fs.readFileSync(file)).digest('hex');
}

const failures = [];
for (const { canonical, copy } of pairs) {
  const a = path.join(repoRoot, canonical);
  const b = path.join(repoRoot, copy);
  if (!fs.existsSync(a)) {
    failures.push({ message: `missing canonical ${canonical}` });
    continue;
  }
  if (!fs.existsSync(b)) {
    failures.push({ message: `missing packaging copy ${copy}` });
    continue;
  }
  if (sha(a) !== sha(b)) {
    failures.push({ message: `drift: ${copy} != ${canonical}` });
  }
}

// Unit must ExecStart the installed launch path.
const unit = fs.readFileSync(path.join(repoRoot, 'packaging/linux/openburnbar-daemon.service'), 'utf8');
if (!unit.includes('ExecStart=/usr/libexec/openburnbar-daemon-launch')) {
  failures.push({ message: 'systemd unit missing ExecStart=/usr/libexec/openburnbar-daemon-launch' });
}

const report = {
  generatedAt: new Date().toISOString(),
  pairs: pairs.length,
  passed: failures.length === 0,
  failures
};

console.log(JSON.stringify(report, null, 2));
process.exit(failures.length === 0 ? 0 : 1);
