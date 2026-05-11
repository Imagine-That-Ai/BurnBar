# Hermes Realtime Relay

OpenBurnBar supports two remote Hermes relay paths:

- **Realtime relay:** iOS/iPadOS and the Mac connect to a Cloud Run WebSocket service. Cloud Run routes encrypted frames through Redis Pub/Sub. This is the preferred path for near-realtime streaming.
- **Firestore fallback:** the existing encrypted Firestore request/chunk relay remains available when the realtime endpoint is not configured or temporarily fails.

The realtime service never receives plaintext chat content. iOS still encrypts each relay request to the Mac relay public key, and the Mac encrypts every response chunk back to the request key. Cloud Run and Redis only carry routing metadata and ciphertext.

The hosted route is intentionally premium-only infrastructure. Every WebSocket upgrade must pass Firebase Auth, Firebase App Check, an explicit relay role header, and an unexpired Apple-verified `hosted_quota_sync` entitlement before the relay accepts the socket.

## Deploy

1. Create a Memorystore Redis instance in the same region as the relay. Use Standard Tier for production so Redis has automatic failover; Basic is only for local/staging cost control.
2. Ensure Cloud Run can reach Redis. Prefer Direct VPC egress when available; use a Serverless VPC Access connector when Direct VPC egress is not available for the project.
3. Create a least-privilege Cloud Run service account for production and grant only the Firebase/Firestore access required to read entitlement documents.
4. Deploy:

```bash
PROJECT_ID=burnbar \
REGION=us-central1 \
REDIS_URL=redis://10.0.0.3:6379 \
DIRECT_VPC_NETWORK=default \
DIRECT_VPC_SUBNET=default \
SERVICE_ACCOUNT=hermes-realtime-relay@burnbar.iam.gserviceaccount.com \
./scripts/deploy-hermes-realtime-relay.sh
```

Connector-based projects can set `VPC_CONNECTOR=openburnbar-serverless` instead of `DIRECT_VPC_NETWORK` / `DIRECT_VPC_SUBNET`. `VPC_EGRESS` defaults to `private-ranges-only`.

The deploy script uses named profiles:

- `DEPLOY_PROFILE=staging-cheap`: zero warm instances, max two instances, Basic Redis acceptable.
- `DEPLOY_PROFILE=prod-safe` default: one warm instance, max ten instances, 500 concurrent WebSockets per instance, 512MiB memory, request-based billing, session affinity, and a 60-minute request timeout.
- `DEPLOY_PROFILE=prod-scale`: two warm instances and a higher max-instance ceiling after load tests prove Redis, latency, and cost margins.

Override `MIN_INSTANCES`, `MAX_INSTANCES`, `CPU`, `MEMORY`, `CONCURRENCY`, `SESSION_AFFINITY`, or `REQUEST_TIMEOUT_SECONDS` only when a real usage pattern requires it. The script also publishes the security and cost limits as environment variables: frame size, sockets/user, request starts/minute, bytes/minute, in-flight requests/user, entitlement cache TTLs, and socket lease TTLs.

The script prints the Cloud Run HTTPS URL. Convert it to WebSocket form by replacing `https://` with `wss://` and appending `/v1/hermes/ws`. Only `wss://` endpoints are advertised to iOS through Firestore; local `ws://` endpoints can be used for local relay development, but they are intentionally not published as mobile-ready realtime endpoints.

## Configure the Mac

In OpenBurnBar for macOS:

1. Open Settings -> Chat Gateway.
2. Choose **Open Hermes + Gateway** to start the Hermes Dashboard and local Hermes gateway together.
3. Keep Hermes Base URL pointed at the local Hermes gateway, usually `http://127.0.0.1:8642`.
4. Optionally turn on **Launch Hermes Dashboard and gateway when OpenBurnBar opens**.
5. Turn on Remote Relay.

OpenBurnBar ships with the hosted relay endpoint built in; normal users do not paste infrastructure URLs. The endpoint field is kept behind Advanced relay endpoint for development and self-hosted staging only.

Hermes Remote Relay is a premium capability. The Mac can run Hermes locally without a subscription, but advertising a hosted relay connection and sending mobile relay traffic require the Apple-verified `hosted_quota_sync` entitlement for `com.openburnbar.hostedQuotaSync.monthly`. Firestore rules, callable functions, and the WebSocket relay all enforce that gate so hosted relay cost is tied to paid accounts.

The Mac publishes the realtime relay URL to its `hermes_connections` document only after the Cloud Run service acknowledges `host.register` with `host.ready`. Mobile uses that verified URL first and falls back to Firestore if realtime connection fails. If the relay service is reachable but no Mac host is subscribed, iOS now receives an immediate realtime error instead of waiting for the full request timeout before falling back.

For chat completions, the Mac host forwards upstream Server-Sent Events as soon as each complete SSE event is received. It does not wait for the local Hermes gateway to finish the whole response before sending encrypted realtime chunks back to iOS. Non-streaming relay operations, such as model and session listing, are split into bounded encrypted data fragments before completion so large catalogs cannot exceed the WebSocket frame budget.

The iOS realtime client races each WebSocket receive against the remaining request deadline. If Cloud Run, Redis, the Mac host, or the local Hermes gateway stalls, iOS cancels the realtime attempt promptly and lets the encrypted Firestore fallback take over instead of hanging inside a socket receive.

Cloud Run WebSocket streams are still HTTP requests and remain subject to the Cloud Run request timeout, so clients must tolerate reconnects. The deployment script sets a 60-minute timeout and the app keeps Firestore as the durability fallback. See Google's Cloud Run WebSocket guidance and VPC guidance for the platform constraints:

- <https://cloud.google.com/run/docs/triggering/websockets>
- <https://cloud.google.com/vpc/docs/configure-serverless-vpc-access>

## Security Model

The relay enforces these checks before accepting a hosted socket:

- `Authorization: Bearer <Firebase ID token>`
- `X-Firebase-AppCheck: <App Check token>`
- `X-OpenBurnBar-Relay-Role: host` for the Mac host socket or `client` for iOS/iPadOS request sockets
- Active `users/{uid}/entitlements/hosted_quota_sync` document with matching product ID and future expiry

Roles are enforced inside the protocol: hosts may register and return responses; clients may start/cancel requests; neither side can impersonate the other frame class. Host registration is single-owner per `(uid, connectionId)`: a newer valid host socket replaces an older one cleanly.

All protocol identifiers are restricted to safe bounded Redis channel segments. The relay rejects unknown operations, methods, frame types, oversized frames, oversized ciphertexts, malformed sequences, and cross-user frames. Payload bodies remain encrypted end to end.

## Cost Controls

Default production limits:

- `MAX_FRAME_BYTES=524288`
- `MAX_HOST_SOCKETS_PER_USER=2`
- `MAX_CLIENT_SOCKETS_PER_USER=4`
- `MAX_REQUEST_STARTS_PER_MINUTE=60`
- `MAX_BYTES_PER_MINUTE=26214400`
- `MAX_IN_FLIGHT_REQUESTS_PER_USER=6`
- `ENTITLEMENT_CACHE_TTL_SECONDS=60`
- `ENTITLEMENT_NEGATIVE_CACHE_TTL_SECONDS=15`

The service uses one shared Redis publisher and one shared Redis subscriber per Cloud Run instance. Per-socket Redis publisher/subscriber clients are intentionally avoided so thousands of WebSocket connections do not multiply Redis connection pressure.

Keep Redis in the same region as Cloud Run and use Direct VPC egress when available. The default `prod-safe` profile keeps one warm instance and caps production at ten relay instances until load-test evidence justifies a higher ceiling. For a cheaper but colder staging relay, deploy with `DEPLOY_PROFILE=staging-cheap`.

Memorystore Redis is the dominant fixed cost while the relay is live. Cloud Run cost scales primarily with open WebSocket request time, so the hosted route is only enabled for premium users and is capped by max instances plus per-user quotas. Delete staging Redis, or scale staging to zero, when remote Hermes testing is done.

## Observability

Cloud Run already exposes request count, request latency, CPU, memory, bytes sent/received, instance count, and concurrent request metrics. The relay emits structured JSON logs for socket opens, auth/entitlement denials, Redis failures, readiness failures, rate-limit closes, and shutdowns. Create log-based metrics for:

- `relay_socket_opened`
- `relay_upgrade_denied`
- `redis_error`
- `readyz_failed`

Alert on Redis errors, 403/429 spikes, sustained max-instance pressure, and billable instance time growth.

## Protocol

All frames are JSON and include:

- `type`
- `uid`
- `connectionId`
- `requestId` when request-scoped
- `protocolVersion`
- `payload`

Frame types:

- `host.register`
- `host.ready`
- `request.start`
- `request.cancel`
- `response.chunk`
- `response.complete`
- `response.error`
- `ping`
- `pong`

Redis channels:

- Host request channel: `hermes:req:{uid}:{connectionId}`
- Request response channel: `hermes:resp:{uid}:{requestId}`
- Host presence key: `hermes:host:{uid}:{connectionId}`
- Host replacement control channel: `hermes:ctrl:{uid}:{connectionId}`

## Verification

Run backend checks:

```bash
npm --prefix services/hermes-realtime-relay test
```

Verify a live deployment:

```bash
curl -fsS https://HERMES_REALTIME_RELAY_RUN_URL/readyz
```

Run the existing Firebase Hermes contract checks:

```bash
npm --prefix functions run test:hermes
```

Run focused Swift checks:

```bash
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .derived-mobile-hermes-realtime build
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBarMobile -configuration Debug -destination 'platform=iOS Simulator,name=iPhone 17 Pro' -derivedDataPath .derived-mobile-hermes-realtime -only-testing:OpenBurnBarMobileTests/HermesServiceTests
xcodebuild -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -configuration Debug -derivedDataPath .derived-hermes-realtime build
xcodebuild test -project OpenBurnBar.xcodeproj -scheme OpenBurnBar -configuration Debug -destination 'platform=macOS,arch=arm64' -derivedDataPath .derived-hermes-realtime -only-testing:OpenBurnBarTests/HermesRelayHostServiceTests
```
