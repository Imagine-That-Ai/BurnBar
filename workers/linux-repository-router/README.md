# Linux repository router

This Cloudflare Worker keeps the public apt and dnf repository URLs stable while
activating a complete immutable repository snapshot with one conditional R2
write. It uses no KV or Durable Object state.

## Object contract

The R2 bucket contains:

- `linux/repository-snapshots/<channel>/<sha256>/repository-closure.json` and
  `.asc`, plus snapshot-relative `apt/` and `rpm/` mutable metadata;
- `linux/repository-activations/<channel>.json`, the single authoritative
  activation object for each supported channel;
- `linux/update-feed-activations/<channel>.json`, one independent feed pointer
  per channel, each bound to one exact repository snapshot, generation, and
  pointer ETag;
- shared immutable apt pool/by-hash objects and RPM packages/checksum-named
  metadata at their existing `linux/apt/` and `linux/rpm/` client paths; and
- immutable versioned update feeds under `linux/releases/linux-v<version>/`.

Bootstrap source, repo, and public-key files live inside each snapshot. Their
stable apt/RPM URLs resolve through the activation pointer, so signing-key or
configuration rotation is atomic with repository metadata. The channel-less
apt and RPM key URLs follow the active `stable` snapshot; channel-specific
source and repo files follow their named channel.

`<sha256>` is the lowercase SHA-256 of the exact closure bytes. Activation
validates that digest, the closure channel/version/commit identity, and the
presence of the detached closure signature before the pointer compare-and-swap.
It also checks every closure-listed snapshot object and its size, hashes every
object up to 8 MiB (including all signed repository metadata and bootstrap
keys/configuration), and requires larger objects to carry upload-time R2
`customMetadata.sha256` exactly matching the closure. It requires the complete
apt/RPM signed-root matrix and refuses apt metadata with less than 24 hours of
validity remaining.

## Administration API

Administration and upload endpoints require separate bearer credentials. The
control Worker reads `OPENBURNBAR_LINUX_REPOSITORY_ACTIVATION_TOKEN` and the
uploader reads `OPENBURNBAR_LINUX_REPOSITORY_UPLOAD_TOKEN` directly. Never
reuse, alias, or commit either credential.

```text
PUT /linux/repository-upload/immutable
GET /linux/repository-preview/<channel>/<snapshot-id>/(apt|rpm)/...
GET /linux/repository-preview/<channel>/<snapshot-id>/repository-closure.json
GET /linux/repository-preview/<channel>/<snapshot-id>/repository-closure.json.asc
GET /linux/repository-admin/status?channel=stable
POST /linux/repository-admin/activate
POST /linux/repository-admin/deactivate
GET /linux/repository-admin/feed-status?channel=stable
POST /linux/repository-admin/publish-feed
POST /linux/repository-admin/rebind-feed
```

Four named, role-isolated deployments share the source and R2 bucket:

| Config | Worker | Routes | `WORKER_ROLE` |
|---|---|---|---|
| `wrangler-upload.jsonc` | `openburnbar-linux-repository-uploader` | upload and immutable snapshot preview | `upload` |
| `wrangler-control.jsonc` | `openburnbar-linux-repository-control` | administration plus private-pointer read guards | `control` |
| `wrangler.jsonc` | `openburnbar-linux-repository-router` | apt and RPM only | `serving` |
| `wrangler-feed.jsonc` | `openburnbar-linux-update-feed` | stable root aliases plus `/linux/update/<channel>/...` | `feed` |

The public preview route serves safe apt/RPM paths and the signed closure pair
below the named content-addressed snapshot and needs no activation pointer.
Release and refresh automation can therefore authenticate the exact snapshot
and run package-manager lifecycle proof before changing the active pointer. The
runtime role check also rejects cross-surface requests if a route is ever
misconfigured.

The control deployment also claims the raw `linux/repository-activations/*`,
legacy `linux/update-feed-activation.json`, and current
`linux/update-feed-activations/*` storage paths and returns `404` for them. The
R2 custom domain therefore cannot expose pointer or tombstone records directly;
authenticated administration endpoints are the only HTTP read surface for
control state.

Immutable upload is create-only. An existing object with trusted SHA-256 custom
metadata is idempotent. During migration only, an existing object without that
metadata may be accepted when it is at most 8 MiB and hashing its exact stored
bytes proves the requested digest. The Worker never rewrites or annotates a
legacy object, and rejects unknown large objects or any drift.

The activation body is an exact schema:

```json
{
  "schemaVersion": 1,
  "mode": "promote",
  "channel": "stable",
  "targetSnapshotId": "<64 lowercase hex characters>",
  "expectedCurrentSnapshotId": null,
  "expectedCurrentGeneration": null,
  "expectedCurrentPointerEtag": null,
  "version": "1.2.3",
  "sourceCommit": "<40 lowercase hex characters>",
  "actor": "release-engineer",
  "runUrl": "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/12345",
  "reason": "Promote after repository lifecycle verification"
}
```

The expected snapshot is `null` before first activation and while an inactive
tombstone is current. `expectedCurrentGeneration` and
`expectedCurrentPointerEtag` are both `null` only when the pointer object is
truly absent; an inactive tombstone still requires its generation and ETag.
All three values come from `status` and must match together, closing ABA as
well as snapshot-identity races. The Worker also conditions the R2 write on
that R2 ETag. `promote` requires a strictly newer semantic version, preventing
a delayed older release run from replaying after a newer one. `rollback` may
select only the active record's retained `previousSnapshotId`; the rollback
drill then reactivates the newer candidate with `promote`. `refresh` is a third,
same-version mode available only while a repository snapshot is active. It must
preserve the active version and source commit and pass the metadata-refresh
closure contract below.

## Metadata refresh contract

A metadata refresh uses closure schema 2 and an exact `refresh` record:

```json
{
  "schemaVersion": 2,
  "refresh": {
    "kind": "apt-expiry",
    "refreshedAt": "2026-07-11T12:00:00.000Z",
    "previousSnapshotId": "<active 64-character snapshot digest>",
    "previousReleaseDate": "2026-07-08T12:00:00.000Z",
    "previousValidUntil": "2026-07-15T12:00:00.000Z"
  }
}
```

The omitted fields are the normal repository closure fields. The Worker loads
and hashes the active parent closure from R2 before accepting `mode: refresh`.
The child must chain to that exact snapshot, advance `refreshedAt` and apt
`releaseDate` together, advance `validUntil`, and retain the canonical 168-hour
signed window. Product, version, channel, source commit, architectures,
package-set root, signing identity, package records, lifecycle requirements,
RPM repository summary, and every non-apt-root file record must be byte-for-byte
identical to the parent. Only `apt/dists/<channel>/Release`, `InRelease`, and
`Release.gpg` may change.

The control Worker proves closure-addressed bytes, required signature-object
presence, lineage, and the allowed delta; it is not an OpenPGP trust engine.
The keyless freshness inspector, isolated repository verifier, preview/public
package-manager lifecycle, and apt/dnf clients perform cryptographic OpenPGP
verification against the pinned repository identity. Compromise of both
role-separated upload and activation credentials can cause availability loss
(activation already has an explicit deactivation capability), but cannot make
clients accept metadata or packages without a valid OpenPGP chain.

Refresh activation uses the same snapshot/generation/pointer-ETag compare and
conditional R2 write as promotion and rollback. It never rewrites immutable
objects or publishes a new application feed. Because a feed pointer binds the
repository generation, snapshot, and ETag, feed routes return fail-closed `503`
after refresh activation until `rebind-feed` selects the existing `current`
feed descriptor with fresh CAS identities. Any downstream failure must roll
back and rebind the retained descriptor through the normal compensation path.

The scheduled workflow checks every six hours and refreshes at 96 hours of
remaining apt validity, with 48 hours treated as critical and 24 hours enforced
as the activation minimum. Those values are committed in
`packaging/linux/distribution-channels.json`. They are source policy, not proof
that the Worker, credentials, schedule, or public repository have been deployed
and exercised successfully.

Deactivation is the fail-closed compensation path for a first activation, where
there is no older snapshot to roll back to. Its body is also an exact schema:

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "expectedCurrentSnapshotId": "<64 lowercase hex characters>",
  "expectedCurrentGeneration": 1,
  "expectedCurrentPointerEtag": "\"<R2 HTTP ETag>\"",
  "actor": "release-engineer",
  "runUrl": "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/12345",
  "reason": "Deactivate after failed public repository verification"
}
```

The control Worker conditionally replaces the active record with an `inactive`
tombstone; it never deletes the pointer object. A successful response is:

```json
{
  "schemaVersion": 1,
  "status": "inactive",
  "channel": "stable",
  "previousSnapshotId": "<64 lowercase hex characters>",
  "fallbackMode": "legacy-direct-r2",
  "generation": 2,
  "pointerEtag": "\"<R2 HTTP ETag>\""
}
```

The tombstone's exact `fallbackMode` is `legacy-direct-r2` only when the
deactivated activation had no prior snapshot. In that first-cutover case,
snapshot-routed apt/RPM paths temporarily serve their exact pre-cutover raw R2
keys, with ordinary `200` or `404` results and no snapshot header. Every other
deactivation writes `disabled`, which makes those routes return a non-cacheable
`503`; malformed tombstones also fail closed. For `stable`, the same
first-cutover tombstone restores the pre-cutover raw root `latest-linux.json`
and signature keys through both the root aliases and stable channel routes,
with ordinary `200` or `404` results and no repository snapshot or
feed-generation header, including when no feed pointer was created. There is no
legacy root feed for `prerelease` or `nightly`, so their exact first-cutover
channel routes return an ordinary `404` with no pointer headers. Feed requests
remain fail-closed for `disabled` tombstones, and feed publication is rejected
while the repository is inactive.
A later promotion uses the tombstone generation and ETag, advances its
generation, and may retry the exact deactivated identity or use a strictly
newer version. Rollback from inactive state is forbidden.

Feed publication uses this exact request schema:

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "generation": 4,
  "snapshotId": "<64 lowercase hex characters>",
  "version": "1.2.3",
  "sourceCommit": "<40 lowercase hex characters>",
  "repositoryPointerEtag": "\"<R2 HTTP ETag>\"",
  "feed": {
    "key": "linux/releases/linux-v1.2.3/latest-linux.json",
    "signatureKey": "linux/releases/linux-v1.2.3/latest-linux.json.ed25519.sig",
    "sha256": "<64 lowercase hex characters>",
    "size": 1234,
    "signatureSha256": "<64 lowercase hex characters>",
    "signatureSize": 64
  },
  "expectedCurrent": { "generation": null, "etag": null }
}
```

Both `expectedCurrent` fields are `null` only for the first feed in that
channel. Later calls must send the generation and ETag returned by
`feed-status?channel=<channel>`. Each channel has an independent storage key,
generation sequence, conditional write, and retained history; activity in one
channel cannot satisfy or invalidate another channel's feed CAS. The control
Worker validates the immutable feed bytes, exact release URLs, the exact 64-byte
Ed25519 signature against the bundled official public key, and every signed
artifact object's exact R2 size and `customMetadata.sha256` before a conditional
feed-pointer write. Every feed record retains either `null` or one exact
`previousFeed` identity (`channel`, `version`, `sourceCommit`, `feed`, and
original `publishedAt`) when a replacement is published, and retained identities
must remain in the same channel. The feed Worker exposes
`/linux/update/<channel>/latest-linux.json` and its `.ed25519.sig` peer. The two
root paths are aliases for `stable` only. It rechecks both the channel feed
pointer and repository identity on every request and returns a non-cacheable
`503` after any pointer or activation race until a matching feed pointer is
published.

After repository rollback, rebind the retained feed without rewriting immutable
feed bytes:

```json
{
  "schemaVersion": 1,
  "channel": "stable",
  "target": "previous",
  "expectedCurrent": { "generation": 2, "etag": "\"<feed pointer ETag>\"" },
  "expectedRepository": {
    "generation": 3,
    "snapshotId": "<64 lowercase hex characters>",
    "pointerEtag": "\"<repository pointer ETag>\""
  },
  "actor": "release-engineer",
  "runUrl": "https://github.com/Imagine-That-Ai/BurnBar/actions/runs/12345",
  "reason": "Rebind retained feed after verified repository rollback"
}
```

`target` is exactly `current` or `previous`. The selected feed's channel,
version, and source commit must match the currently active repository. The
Worker revalidates its signed bundle and artifact metadata, conditionally writes
against the feed ETag, and re-reads the repository after the write. A repository
race leaves the public feed fail-closed. Selecting `previous` swaps the prior
current identity into `previousFeed`, so verified forward recovery can use the
same operation in reverse.

Both Worker credentials use the shared safe alphabet
`^[A-Za-z0-9._~+/=-]{32,4096}$`; whitespace, controls, quotes, and backslashes
are rejected before constant-time digest comparison.

## Local verification

```bash
npm ci --ignore-scripts
npm test
npx wrangler deploy --dry-run --config wrangler-upload.jsonc
npx wrangler deploy --dry-run --config wrangler-control.jsonc
npx wrangler deploy --dry-run --config wrangler.jsonc
npx wrangler deploy --dry-run --config wrangler-feed.jsonc
```

Public mutable metadata is served with revalidation and a snapshot header.
Content-addressed leaves and packages are immutable. Missing or malformed
activation state returns a non-cacheable `503`; only an exact
`legacy-direct-r2` first-cutover tombstone enables raw-key fallback.

The activation design relies on [R2 strong consistency](https://developers.cloudflare.com/r2/reference/consistency/)
and [conditional Worker binding writes](https://developers.cloudflare.com/r2/api/workers/workers-api-reference/).
The activation and feed records are each single objects per channel, so KV or a
Durable Object would add state without strengthening the compare-and-swap
invariant.
