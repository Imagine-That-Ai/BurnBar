# F2 evidence: gateway token-bucket rate limiter

Date: 2026-07-14
WPD-0006 row: 22
Disposition: SUB-DONE (per-client token bucket)

## Production composition

`LocalHttpGatewayHost` now constructs a `GatewayRateLimiter` for every production
gateway instance. The default matches the macOS gateway contract: 30 requests
per second sustained with a 50-request burst. The check runs after authentication
and before model discovery, metrics, routing, request-body reads, or provider
execution, so a throttled caller cannot consume provider credits or expensive
gateway work.

When the explicit unauthenticated-loopback escape hatch is active, a second
limiter applies the macOS fail-closed 5 requests/second, 30-request burst ceiling.
All tokenless callers share the literal `unauthenticated-loopback` bucket. An
untrusted same-host process therefore cannot evade the ceiling by inventing new
Bearer values.

## Contract parity and safety

- Each authenticated credential maps to a stable SHA-256-derived key; raw tokens
  are never retained in bucket state, response bodies, or telemetry.
- Refill uses `TimeProvider`'s monotonic timestamp rather than wall time.
- Bucket access is serialized, preserving the configured burst under concurrent
  requests.
- Idle client buckets are pruned after five minutes on a five-minute cadence.
- A rejection is HTTP 429 with an integer, ceiling-rounded `Retry-After` header
  and a bounded generic JSON error. Provider execution is not invoked.
- Configuration preserves the macOS minimums of 0.1 requests/second and one
  burst token, while rejecting non-finite rates.

## Verification

`GatewayRateLimiterTests` proves minimum normalization, exact burst/retry
behavior, per-client isolation, monotonic refill, concurrent burst enforcement,
and idle pruning. `LocalHttpGatewayHostTests` proves the production request path
rejects authentication before touching the legitimate bucket, throttles before
provider execution, emits the expected 429/`Retry-After`, does not disclose the
credential, and collapses invented Bearer values into the shared unauthenticated
bucket.

```text
dotnet test windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj -c Release --no-restore
Passed: 245, Failed: 0, Skipped: 0

dotnet format windows/app/OpenBurnBar.App.ManagedAgentRuntime/OpenBurnBar.App.ManagedAgentRuntime.csproj --verify-no-changes --no-restore
PASS

dotnet format windows/tests/managed-runtime/OpenBurnBar.App.ManagedAgentRuntime.Tests.csproj --verify-no-changes --no-restore
PASS
```
