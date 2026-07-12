# Linux product feature proof contract

The Linux parity gate separates release evidence from environment-specific feature evidence.
Release evidence is produced once by the immutable Linux candidate. Feature evidence is captured
on each row of the seven-environment support matrix and is never treated as a pass by collection
alone.

## Trust chain

1. `product-feature-proof-registry.json` declares the exact artifact roles, media types, and byte
   limits owned by each feature requirement. The four release-only requirements (`P-01`, `P-03`,
   `P-04`, and `P-37`) cannot register feature roles.
2. `finalize-product-proof-closure.mjs` validates and snapshots that registry into the immutable
   candidate artifact. The aggregate closure records its SHA-256 and size.
3. A requirement capture harness writes only its observed artifacts under
   `feature-artifacts/` and an exact `feature-proof-registration.json` beside the downloaded
   candidate.
4. `finalize-product-feature-proof-closure.mjs` rejects missing, extra, duplicate, oversized,
   symlinked, or unregistered artifacts. Its `collected` closure binds their bytes to the current
   requirement, support environment, source commit, release version, candidate run, candidate
   artifact digest, aggregate product closure, and snapshotted registry.
5. `prepare-product-requirement-input.mjs` revalidates the complete binding and copies the exact
   subjects into the requirement-owned release closure. The validator runner repeats this check
   before executing a requirement module, so post-materialization mutation fails closed.
6. Only the substantive `P-XX.mjs` validator may interpret the captured artifacts and return a
   passed receipt. Feature closure status is deliberately `collected`; it has no `passed` field.

## Adding a requirement

1. Add one sorted requirement entry and its sorted `feature.*` roles to
   `product-feature-proof-registry.json`.
2. Add a capture step before **Finalize registered feature proof closure** in
   `linux-product-parity.yml`. The capture must exercise the installed candidate in the live
   desktop session and write the exact registration manifest.
3. Implement the corresponding validator with semantic assertions for every registered artifact.
4. Add positive and mutation tests for capture, registration, materialization, and validator
   behavior. A screenshot or JSON file existing is not acceptance evidence by itself.

The candidate artifact digest is learned only after GitHub uploads the candidate, so it cannot be
embedded into that artifact without a circular digest. The environment closure supplies that final
binding after the exact candidate is resolved, while the registry SHA inside the candidate prevents
the environment job from changing the accepted artifact contract.
