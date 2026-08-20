---
name: deslop-user-copy
description: Prevents internal implementation details, raw error stacks, database keys, and backend jargon from leaking into user-facing copy, alerts, and UI states.
---

# Deslop User Copy: User-Centered Language (Phantastic)

Eliminates developer jargon, raw exception messages, internal database identifiers, and backend infrastructure details from user-facing copy, alerts, dialogs, and error states.

---

## 1. The Anti-Pattern: Internals Leaking to Users

Software created with AI frequently surfaces internal mechanics directly to the end-user:
- ❌ *"Failed to execute task: null pointer in FirebaseProviderAccountDoc sync worker at step 4"*
- ❌ *"Error: GRDB SQLite foreign key constraint failed on usage_rollups_v2"*
- ❌ *"Successfully dispatched mutation to GraphQL endpoint https://api.internal/v1"*
- ❌ *"Invalid payload: provider_id does not match schema enum value"*

Users cannot act on database column names, raw stack traces, or internal microservice names.

---

## 2. The 3-Rule Translation Standard

1. **User Actionability:** What does this mean for the user, and what should they do next?
2. **Clear & Human Vocabulary:** Replace technical jargon with plain English.
3. **Structured Debug Logs for Devs, Human Copy for Users:**
   - Log the full stack trace, request ID, and raw error to internal logging / Sentry / console.
   - Show the user a clear explanation with a direct path to recover or retry.

---

## 3. Translation Matrix

| Raw Internal Error / Jargon | Clean User-Facing Copy |
|---|---|
| `FirebaseAuthError: auth/id-token-expired` | "Your session has expired. Please sign in again to continue." |
| `NetworkError: ECONNREFUSED 127.0.0.1:443` | "Unable to reach the server. Please check your internet connection and try again." |
| `QuotaSnapshotDoc sync failure: 429 Too Many Requests` | "You've reached your usage limit. Upgrade your plan or try again in 15 minutes." |
| `RecordNotFoundException: no row for ID 92837 in table orders` | "We couldn't find that order. It may have been deleted or moved." |
| `FileIOError: EACCES permission denied /var/log/audit.db` | "Permission required. Please grant storage access in Settings to save your history." |

---

## 4. UI Copy Guidelines

- **Buttons:** Use clear verbs (`Save changes`, `Try again`, `Cancel`, `Sign in`) instead of generic tech terms (`Execute`, `Trigger`, `Submit mutation`).
- **Empty States:** Explain what belongs here and how to get started, not "Collection query returned 0 items".
- **Loading States:** "Loading your projects..." instead of "Awaiting socket response from worker...".
