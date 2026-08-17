/**
 * Small, durable popup preferences. Safari can make extension storage
 * unavailable in a transient popup session, so every access fails soft and the
 * caller keeps the default.
 */

const FULL_SCREEN_PROMPT_STORAGE_KEY = 'openburnbar.popup.fullscreen.skipPrompt.v1';
const WELCOME_STORAGE_KEY = 'openburnbar.popup.welcome.seen.v1';
const RELEASE_STAGE = 'Alpha';

export function localStorageIfAvailable(): Storage | undefined {
  try {
    return globalThis.localStorage;
  } catch {
    return undefined;
  }
}

/** The release moniker shown in the window and attached to every report. */
export function releaseStage(): string {
  return RELEASE_STAGE;
}

export function loadSkipFullScreenPrompt(storage: Storage | undefined = localStorageIfAvailable()): boolean {
  try {
    return storage?.getItem(FULL_SCREEN_PROMPT_STORAGE_KEY) === 'true';
  } catch {
    return false;
  }
}

/** First run shows the welcome once; the key is versioned so a reworked tour can return. */
export function loadWelcomeSeen(storage: Storage | undefined = localStorageIfAvailable()): boolean {
  try {
    return storage?.getItem(WELCOME_STORAGE_KEY) === 'true';
  } catch {
    /* An unreadable preference must not open the tour on every single visit. */
    return true;
  }
}

export function saveWelcomeSeen(storage: Storage | undefined = localStorageIfAvailable()): void {
  try {
    storage?.setItem(WELCOME_STORAGE_KEY, 'true');
  } catch {
    // Losing this only costs one extra welcome.
  }
}

export function saveSkipFullScreenPrompt(
  skip: boolean,
  storage: Storage | undefined = localStorageIfAvailable()
): void {
  try {
    if (skip) {
      storage?.setItem(FULL_SCREEN_PROMPT_STORAGE_KEY, 'true');
    } else {
      storage?.removeItem(FULL_SCREEN_PROMPT_STORAGE_KEY);
    }
  } catch {
    // Preference is a convenience; losing it only means asking again.
  }
}
