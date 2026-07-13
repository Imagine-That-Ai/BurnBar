import assert from 'node:assert/strict';
import test from 'node:test';
import { buildLinuxUpdatePlan } from './linux-update-plan.mjs';

test('deb plan exposes fixed install, rollback, and restart actions', () => {
  const plan = buildLinuxUpdatePlan({ packageChannel: 'deb', currentVersion: '1.0.0', latestVersion: '1.1.0' });
  assert.equal(plan.packageManager, 'apt');
  assert.equal(plan.install.command, 'sudo apt-get install --only-upgrade open-burn-bar');
  assert.equal(plan.rollback.command, 'sudo apt-get install --allow-downgrades open-burn-bar=PREVIOUS_VERSION');
  assert.equal(plan.restart.command, 'systemctl --user restart openburnbar-daemon.service');
  assert.equal(plan.install.requiresConfirmation, true);
});

test('rpm and AppImage plans preserve native ownership', () => {
  const rpm = buildLinuxUpdatePlan({ packageChannel: 'rpm', currentVersion: '1.0.0' });
  assert.equal(rpm.packageManager, 'dnf');
  assert.equal(rpm.install.command, 'sudo dnf upgrade --refresh open-burn-bar');
  assert.equal(rpm.rollback.command, 'sudo dnf downgrade open-burn-bar');

  const appimage = buildLinuxUpdatePlan({ packageChannel: 'appimage', currentVersion: '1.0.0' });
  assert.equal(appimage.packageManager, 'appimage');
  assert.equal(appimage.install.command, null);
  assert.equal(appimage.rollback.command, null);
  assert.equal(appimage.install.available, true);
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
