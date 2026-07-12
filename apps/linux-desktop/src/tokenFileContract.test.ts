import { describe, expect, it } from 'vitest';
import {
  describeTokenModeContract,
  isTokenModeAllowed,
  TOKEN_ALLOWED_MODES,
  TOKEN_FILE_NAME,
  TOKEN_FORBIDDEN_MODE_MASK
} from './tokenFileContract.js';
import { linuxAuthTokenPath, linuxSupportDir } from './linuxPaths.js';

describe('token file mode contract (VAL-PATH-002)', () => {
  it('names the token file under support dir', () => {
    process.env.OPENBURNBAR_DAEMON_SUPPORT_DIR = '/tmp/obb-support-test';
    expect(linuxAuthTokenPath().endsWith(`/${TOKEN_FILE_NAME}`)).toBe(true);
    expect(linuxAuthTokenPath().startsWith(linuxSupportDir())).toBe(true);
    delete process.env.OPENBURNBAR_DAEMON_SUPPORT_DIR;
  });

  it('allows 0600 and 0400 only', () => {
    expect(isTokenModeAllowed(0o600)).toBe(true);
    expect(isTokenModeAllowed(0o400)).toBe(true);
    expect(TOKEN_ALLOWED_MODES).toContain(0o600);
  });

  it('refuses group/other readable or writable modes', () => {
    expect(isTokenModeAllowed(0o640)).toBe(false);
    expect(isTokenModeAllowed(0o644)).toBe(false);
    expect(isTokenModeAllowed(0o666)).toBe(false);
    expect(isTokenModeAllowed(0o777)).toBe(false);
    expect(0o644 & TOKEN_FORBIDDEN_MODE_MASK).toBeTruthy();
  });

  it('documents the shared contract with Rust and launch script', () => {
    expect(describeTokenModeContract()).toMatch(/0600/);
    expect(describeTokenModeContract()).toMatch(/regular file/);
  });
});
