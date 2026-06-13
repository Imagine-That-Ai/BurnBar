# Endpoint Authorization Matrix

The machine-readable source of truth is `functions/src/security/endpointAuthorizationMatrix.ts`.

The matrix is intentionally tested against `functions/src/index.ts` by `functions/src/__tests__/endpointAuthorizationMatrix.test.ts`. Any new exported Firebase Function must declare:

- trigger type
- authentication method
- App Check posture
- tenant source
- client-controlled object identifiers
- ownership check
- BOLA/IDOR negative test reference or public/trigger justification

This document is the auditor-facing pointer. Do not maintain a separate hand-copied Markdown matrix; it will drift. Generate any presentation copy from the TypeScript matrix.

Run:

```sh
npm --prefix functions run test:security
```
