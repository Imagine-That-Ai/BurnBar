const PRODUCTION_FIREBASE_PROJECT_ID = "burnbar";
export const PRODUCTION_FIREBASE_WEB_API_KEY = "AIzaSyBiAIHwf1MKZ6LN5HrsaPYsAR3UTe8hyw4";
const FIREBASE_WEB_API_KEY_PATTERN = /^AIza[A-Za-z0-9_-]{20,120}$/u;

export function resolveCliLinkFirebaseWebAPIKey(projectId: string, configuredKey: string): string {
  const candidate = configuredKey.trim();
  if (FIREBASE_WEB_API_KEY_PATTERN.test(candidate)) return candidate;
  if (projectId === PRODUCTION_FIREBASE_PROJECT_ID && candidate.length === 0) {
    return PRODUCTION_FIREBASE_WEB_API_KEY;
  }
  throw new Error(`A Firebase Web API key paired with project ${projectId} is required for desktop authentication.`);
}
