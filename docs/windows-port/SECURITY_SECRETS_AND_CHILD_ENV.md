# Windows Secret Storage, Redaction, and Child Process Isolation

This runbook covers the Windows security boundary for app configuration secrets
and product-spawned child processes.

## Protected Secret Store

Windows configuration uses `AppConfiguration.SecretStore` as the single
application-owned secret store. `app_config.json` may contain non-secret
configuration and stable secret references only:

- `sqlCipherPassphraseRef`
- `firebaseIdTokenRef`
- `appCheckTokenRef`
- `vaultKeyB64Ref`

Plaintext values for the legacy fields are migration input only. They must not
be persisted after a successful load or save. New settings UI writes secret
values into protected storage and keeps existing protected values when a secret
field is left blank.

On Windows, protected payloads are wrapped with current-user DPAPI before they
are written to the app secret directory. The store verifies every write by
reading the value back before returning success. A missing, corrupt, denied, or
unverified protected secret raises `SecretStoreException` and the app fails
closed instead of falling back to plaintext or sample credentials.

## Legacy Migration

When `app_config.json` contains legacy plaintext credentials, startup performs
an atomic migration:

1. Write a `.secret-migration.json` journal beside the config file.
2. Write each legacy secret to protected storage.
3. Read each protected secret back and verify byte-for-byte equality.
4. Replace `app_config.json` atomically with a reference-only version.
5. Delete the journal after the replacement succeeds.

If migration is interrupted before the config replacement, the next startup
retries from the plaintext config. If the replacement already happened, the
next startup treats the config as clean and removes the completed journal. If
protected storage denies a write or verification fails, the plaintext config is
left intact and startup fails closed.

## Redaction And Leak Scanning

Secrets resolved from the environment or protected store are registered with the
shared `SecretRedactor`. Diagnostics and exception logging redact registered
values before writing user-visible text. The companion `SecretLeakScanner`
checks representative artifacts for:

- Exact secret values.
- Base64, hex, and URL-encoded forms.
- Sliding substrings of long secrets.
- Structured secret fields such as tokens, passwords, keys, and passphrases.
- High-entropy credential-shaped tokens.

Run the focused configuration tests after touching this surface:

```bash
dotnet test windows/tests/configuration/OpenBurnBar.App.Configuration.Tests.csproj --no-restore --nologo
```

## Child Process Environments

All production child-process paths must use `ChildProcessEnvironment` with the
smallest matching `ChildProcessProfile`. The helper starts from an explicit
allowlist and removes provider credentials, Firebase tokens, signing keys,
diagnostic canaries, SQLCipher passphrases, vault keys, and other secret-shaped
environment variables.

Covered production paths include:

- Chat CLI launch.
- Win32 ConPTY chat sessions.
- Swift parser helper launch.
- Project-code language-server launch.
- Project-code static-parser launch.
- Windows update signing helper fallback.
- Generated Claude statusline wrapper.

New process spawns must use `ChildProcessLaunchPolicy.CreateStartInfo(...)` and
`ChildProcessLaunchPolicy.Start(...)`, or use the environment helper directly
only when a reviewed lower-level API owns process creation.

## Evidence Requirements

Before promoting any Windows parity or security claim, collect host evidence on
Windows x64 and Windows ARM64:

- App launch with plaintext legacy config migrated to reference-only config.
- Power loss or forced interruption at each migration boundary, followed by
  successful recovery or fail-closed denial.
- Redaction canary scan across diagnostics, logs, support bundles, screenshots,
  crash artifacts, CI artifacts, and release artifacts.
- Child-process environment dump for every product-spawned process profile,
  proving forbidden credential names and values are absent.
- Compatibility run against the macOS v1.0.29 configuration oracle fixtures.

Local macOS unit tests are useful regression coverage, but they are not a
substitute for the Windows DPAPI, Credential Manager, crash artifact, support
bundle, and host process evidence above.
