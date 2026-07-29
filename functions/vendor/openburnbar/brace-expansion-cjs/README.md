# brace-expansion-cjs

First-party callable CommonJS facade over the patched brace-expansion
algorithm, for the minimatch 3 consumers inside the Firebase CLI dependency
subtree (`firebase-tools`, `glob@7`, `readdir-glob`, `superstatic`).

## Why it exists

- minimatch 3 loads brace expansion as `var expand = require("brace-expansion")`
  and calls it directly, so it needs a **callable default export**.
- Every brace-expansion release patched against the expansion DoS advisories
  (GHSA-mh99-v99m-4gvg, GHSA-3jxr-9vmj-r5cp) — upstream `>= 5.0.8` and the
  `@isaacs/brace-expansion` fork — exports a named-only `{ expand }` surface,
  which crashes minimatch 3 at brace-expansion call time.
- This shim wraps `@isaacs/brace-expansion >= 5.0.1` (patched fork of the same
  algorithm) and re-exposes it as a callable default with an `expand` named
  property, satisfying both minimatch 3 and minimatch 10 loading patterns.
- `scripts/ci/verify-firebase-tools-runtime.mjs` smoke-tests the wiring
  (including an actual brace pattern) before any deploy authentication.

## Non-obvious mechanics

- **Version `6.0.0+openburnbar.2`** sits above the `>= 5.0.8` security floor
  enforced by `scripts/security/check-known-vulnerability-floors.mjs`, and
  deliberately **outside** the repository-wide `brace-expansion: "^5.0.8"`
  override range so npm keeps the registry package at the tree root for
  modern minimatch and nests this facade only where the scoped override
  routes it.
- **Package name is literally `brace-expansion`** because npm matches override
  targets by name; the dependency uses the fork's distinct name because a dep
  literally named `brace-expansion` would be rewritten again by the same
  override (infinite recursion).
- **The tarball is a direct development dependency** named
  `openburnbar-brace-expansion-cjs`, using the root-relative
  `file:vendor/openburnbar/brace-expansion-cjs.tgz` spec. The
  version-qualified override references that exact spec with
  `$openburnbar-brace-expansion-cjs`. This keeps the installed dependency
  edges portable and valid under `npm ls`; a raw nested `file:` override is
  interpreted relative to each dependent package and can install successfully
  while still leaving an invalid dependency tree.
- **The override key is version-qualified** (`brace-expansion@^1.1.7`, the
  range minimatch 3 declares) because npm applies nested override rules to
  every package with a matching name; the qualifier keeps the shim away from
  minimatch 10's `brace-expansion@^5` edge.
- **The tarball is what npm consumes.** Directory `file:` overrides produce
  `link: true` lock entries that `npm ci` cannot reproduce for nested
  placements. Rebuild after editing the sources:

  ```bash
  cd functions/vendor/openburnbar/brace-expansion-cjs
  npm pack --pack-destination ..
  mv ../brace-expansion-6.0.0+openburnbar.2.tgz ../brace-expansion-cjs.tgz
  ```

- **Lock placement matters:** `npm ci` reproduces the tree only when the shim
  entries live at `node_modules/<pkg>/node_modules/brace-expansion` (sibling
  of each nested minimatch's parent), not nested inside minimatch itself.
  `npm install` accepts and preserves that placement.
