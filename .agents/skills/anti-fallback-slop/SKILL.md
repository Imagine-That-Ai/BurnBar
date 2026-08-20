---
name: anti-fallback-slop
description: Prevents silent failure anti-patterns, fake fallbacks, useless try-catches that mask errors, phantom default states, and 'still works' illusions that hide broken core logic.
---

# Anti-Fallback Slop: Real Errors over Fake Resilience (@webtkdev)

Prevents the "it still works" illusion where AI writes nested fallbacks, default values, or empty catches that swallow errors and make broken systems look healthy.

---

## 1. The Anti-Pattern: Phantom Resilience

AI often writes defensive code that hides the real bug under five layers of fallbacks:
- Swallowing HTTP 500s and returning `[]` or `{}` or `mockData` without notifying callers or logging.
- Catching exceptions and silently continuing with empty or stale state.
- Coalescing `null`/`undefined` through 6 levels of fallback constants instead of finding why the primary data source failed.
- Fabricating mock responses when real integrations fail, creating fake green test suites.

```typescript
// ❌ SLOP: Swallows fatal error, returns empty object, disguises broken API
async function fetchUserProfile(userId: string) {
  try {
    const res = await api.get(`/users/${userId}`);
    return res.data;
  } catch (err) {
    console.warn("User fetch failed, fallback to default", err);
    return { id: userId, name: "Anonymous User", role: "guest" }; // Lies to caller
  }
}

// ✅ CLEAN: Fails loudly with actionable error context
async function fetchUserProfile(userId: string): Promise<UserProfile> {
  const res = await api.get(`/users/${userId}`);
  if (!res.ok) {
    throw new UserFetchError(`Failed to fetch user ${userId}: ${res.status} ${res.statusText}`);
  }
  return res.data;
}
```

---

## 2. Rules for Clean Error Handling

1. **Fail fast and loudly:** If a required dependency or state is missing, throw an explicit error.
2. **Never swallow errors silently:** Every `catch` block must either handle the error definitively, rethrow, or record a structured operational log.
3. **No phantom default objects:** Do not return fake valid-looking objects when an operation failed. Callers must know whether they have real data or a failure.
4. **Distinguish intentional fallback from failure masking:**
   - Intentional: Cache-aside with graceful fallback to cached snapshot on network timeout (with explicit `isStale: true` flag).
   - Slop: Catching parsing/syntax errors and returning empty collections.
5. **No mock fallbacks in production paths:** Never inject synthetic mock data as a catch-block fallback in real code.
