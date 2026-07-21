# P35 — Diagnostics and support hardening

The Linux support route keeps diagnostics useful without turning the support
surface into a log viewer or exposing credentials.

## Native contract

`export_diagnostics` writes an owner-only (`0600`) JSON bundle under the native
support directory and returns:

```json
{
  "path": "/home/user/.local/share/openburnbar/diagnostics-<epoch>.json",
  "preview": {
    "schemaVersion": 1,
    "byteCount": 1234,
    "fileMode": "0600",
    "included": ["shell version", "package channel and runtime facts"],
    "excluded": ["provider API keys and credentials", "socket auth tokens"]
  }
}
```

The preview is metadata only. The webview never receives raw bundle contents.
The bridge rejects relative paths, traversal segments, control characters,
unexpected separators, and filenames that are not native diagnostics JSON.
The support store applies the same validation before rendering or copying a
path, so a compromised or stale bridge cannot redirect clipboard writes.

## Runtime/package facts

`app_version_info` reports shell/daemon versions plus explicit runtime facts:
architecture, kernel release when readable, desktop/session/display server,
package manager, and package evidence. Unsupported or unproven channels are
reported as `unknown`; the shell never labels an arbitrary unpacked process as
an AppImage. Fixture mode remains visibly fixture-only and does not claim live
package evidence.

## QA

- Export succeeds with `0600` permissions and returns a valid metadata preview.
- Preview contains included/excluded privacy classes and no token, provider
  payload, or session-content fields.
- Relative paths, `..` traversal, control characters, backslashes, and unknown
  filenames are rejected by the bridge/store.
- Copy path writes only the validated diagnostics path and reports unavailable
  or denied clipboard access without exposing raw errors.
- Version/support views display architecture, desktop/display server, kernel,
  package manager, and evidence; absent facts read `Not reported`.
- Fixture mode is labelled fixture-only and cannot be mistaken for installed
  package evidence.
