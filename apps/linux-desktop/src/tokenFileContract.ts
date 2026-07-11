/**
 * VAL-PATH-002 / Issue 5: documented auth token file mode contract shared with
 * Rust `read_token_file_secure` and packaging/linux/openburnbar-daemon-launch.sh.
 *
 * - Path: `<supportDir>/daemon-socket-auth-token`
 * - Mode: 0600 (owner rw) or 0400 (owner r); group/other bits refused
 * - Type: regular file only (no symlink/FIFO/socket/device)
 */

export const TOKEN_FILE_NAME = 'daemon-socket-auth-token';
export const TOKEN_ALLOWED_MODES = [0o600, 0o400] as const;

/** POSIX mode bits that must be clear on token files (group + other). */
export const TOKEN_FORBIDDEN_MODE_MASK = 0o077;

export function isTokenModeAllowed(mode: number): boolean {
  const bits = mode & 0o777;
  return (bits & TOKEN_FORBIDDEN_MODE_MASK) === 0 && (bits & 0o400) !== 0;
}

export function describeTokenModeContract(): string {
  return 'daemon-socket-auth-token must be a regular file with mode 0600 or 0400; shell and launch script refuse group/other bits and non-regular paths.';
}
