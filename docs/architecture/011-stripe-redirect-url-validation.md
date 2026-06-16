# ADR 011: Stripe Redirect URL Validation

## Context

Stripe checkout and customer-portal sessions accept `success_url`, `cancel_url`, and `return_url` values that are sent back to the client and ultimately followed by the user's browser. Because these URLs are supplied by the caller, an attacker who can influence the parameter can redirect a user to an attacker-controlled host after a payment flow. A previous naive substring check allowed bypasses such as `localhost.attacker.example`, `malocalhost.com`, and various IP-obfuscation tricks.

## Decision

All Stripe redirect URLs in Cloud Functions are validated by `boundedHttpsURL` in `functions/src/callables/shared/validators.ts` before being passed to Stripe.

The validator:

1. Parses the value with the WHATWG `URL` parser.
2. Rejects URLs that include userinfo (`username:password@`).
3. Rejects non-HTTP/HTTPS schemes.
4. Allows `http://` only for the exact loopback hosts `localhost`, `127.0.0.1`, and `[::1]`.
5. Requires `https://` for every other host.
6. Uses the raw authority string (not the normalized `URL.host`) to decide whether the loopback exception applies, closing parser-differential bypasses where the normalized host differs from the raw host.
7. Optionally enforces a production origin allowlist: when `stripeRedirectURLAllowlist` is non-empty, non-loopback destinations must match an exact `hostname[:port]` entry.

The allowlist is configured via `STRIPE_REDIRECT_URL_ALLOWLIST` (comma-separated hostnames) or Firebase Functions config `stripe.redirect_url_allowlist`. An empty allowlist preserves the legacy HTTPS-only behavior so existing deployments are not broken.

## Consequences

- Parser-differential localhost-substring bypasses are blocked by construction.
- Operators can tighten production deployments to an explicit set of callback origins.
- Local development and simulator builds continue to use `http://localhost` without configuration.
- New bypass attempts must be covered by unit tests in `functions/src/__tests__/validators.test.ts`.
