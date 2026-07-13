import assert from 'node:assert/strict';
import test from 'node:test';
import { buildLinuxUpdatePlan } from './linux-update-plan.mjs';

test('deb plan keeps install and rollback guidance fail closed without repository/history artifacts', () => {
  const plan = buildLinuxUpdatePlan({ packageChannel: 'deb', currentVersion: '1.0.0', latestVersion: '1.1.0' });
  assert.equal(plan.packageManager, 'apt');
  assert.equal(plan.install.command, null);
  assert.equal(plan.install.available, false);
  assert.equal(plan.rollback.command, null);
  assert.equal(plan.rollback.available, false);
  assert.equal(plan.restart.command, 'systemctl --user restart openburnbar-daemon.service');
  assert.equal(plan.install.requiresConfirmation, true);
});

test('rpm and AppImage plans preserve native ownership', () => {
  const rpm = buildLinuxUpdatePlan({ packageChannel: 'rpm', currentVersion: '1.0.0' });
  assert.equal(rpm.packageManager, 'dnf');
  assert.equal(rpm.install.command, null);
  assert.equal(rpm.install.available, false);
  assert.equal(rpm.rollback.command, null);
  assert.equal(rpm.rollback.available, false);

  const appimage = buildLinuxUpdatePlan({ packageChannel: 'appimage', currentVersion: '1.0.0' });
  assert.equal(appimage.packageManager, 'appimage');
  assert.equal(appimage.install.command, null);
  assert.equal(appimage.rollback.command, null);
  assert.equal(appimage.install.available, true);
  assert.equal(appimage.rollback.available, false);
  assert.equal(appimage.restart.command, null);
});

test('unknown channel remains explicitly unavailable', () => {
  const plan = buildLinuxUpdatePlan({ packageChannel: 'unknown', currentVersion: '1.0.0' });
  assert.equal(plan.install.available, false);
  assert.equal(plan.rollback.available, false);
  assert.equal(plan.install.command, null);
});

test('rejects invalid versions and channels before producing an action', () => {
  assert.throws(
    () => buildLinuxUpdatePlan({ packageChannel: 'deb', currentVersion: '1.0.0;rm -rf /' }),
    /currentVersion must be strict/u
  );
  assert.throws(
    () => buildLinuxUpdatePlan({ packageChannel: 'shell', currentVersion: '1.0.0' }),
    /unsupported Linux package channel/u
  );
});
