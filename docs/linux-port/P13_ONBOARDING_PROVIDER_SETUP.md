# P-13 Linux Provider Setup

The provider step in the Linux onboarding wizard now reads the daemon-owned
provider catalog and offers one explicit credential action. A credential is
sent to `provider_credential_slot_upsert`, where the native daemon stores it in
Secret Service or the configured Linux secret custodian. The web view clears
the input immediately after dispatch and never writes the value to onboarding
cache or renderer storage.

The onboarding completion gate remains `daemon.onboarding.snapshot`; storing a
credential does not mark the step verified. Users must still verify the
provider and can finish the step only when the daemon accepts the required
local setup. The daemon's required `provider_paths` probe also reads the
resolved configuration and requires at least one enabled routing provider with
either a Linux-local endpoint or a readable Secret Service credential; a
catalog row or disabled slot cannot create a false-green first run. If the
native bridge is absent or fixture mode is active, the mutation is rejected
with an explicit unavailable reason.

OAuth-only provider connections, portal consent, provider scan depth, and
desktop integration do not have a canonical Linux RPC in this slice. The UI
routes those cases to Settings/native flows instead of inventing a browser or
renderer-side auth path.

Focused verification:

```bash
npx vitest run src/app/App.test.tsx --reporter=dot
npx tsc --noEmit
npm run build
```
