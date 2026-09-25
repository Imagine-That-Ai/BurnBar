const DEMO_PROVIDER_ACCOUNT_ID_PREFIX = "demo_android_";

function isRecord(value: unknown): value is Record<string, unknown> {
  return typeof value === "object" && value !== null && !Array.isArray(value);
}

export function demoProviderAccountIDPrefix(): string {
  return DEMO_PROVIDER_ACCOUNT_ID_PREFIX;
}

export function isDemoProviderAccountID(accountID: string): boolean {
  return accountID.startsWith(DEMO_PROVIDER_ACCOUNT_ID_PREFIX);
}

export function providerAccountIDFromPath(path: string): string | undefined {
  const segments = path.split("/");
  if (segments.length < 2 || segments.at(-2) !== "provider_accounts") {
    return undefined;
  }
  return segments.at(-1);
}

export function isDemoProviderAccountRecord(raw: unknown, accountID?: string): boolean {
  if (accountID !== undefined && isDemoProviderAccountID(accountID)) {
    return true;
  }
  if (!isRecord(raw)) {
    return false;
  }
  if (raw.demo === true) {
    return true;
  }
  return typeof raw.id === "string" && isDemoProviderAccountID(raw.id);
}
