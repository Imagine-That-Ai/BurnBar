# Evidence — SQLCipher storage byte-compat (Real)

**Ledger row:** `storage-sqlcipher-byte-compat`  
**Status claim:** Real  
**Date recorded:** 2026-07-09  
**Architecture:** WPD-0005 (`docs/windows-port/decisions/0005-windows-storage-architecture.md`)

## What this proves

Windows `OpenBurnBar.Storage` opens the shared SQLCipher database with the pinned cipher profile and reproduces the committed `DatabaseByteCompatVector` (schema hash + ordered payload digest) used for macOS ↔ Windows file compatibility.

## Artifacts

| Artifact | Location |
|----------|----------|
| Storage open API | `windows/storage/OpenBurnBar.Storage/OpenBurnBarStorage.cs` |
| Vector algorithm | `windows/storage/OpenBurnBar.Storage/DbCompatVector.cs` |
| Connection/cipher | `windows/storage/OpenBurnBar.Storage/SqlCipherConnection.cs`, `SqlCipherParameters.cs` |
| Tests | `windows/storage/OpenBurnBar.Storage.Tests/DbByteCompatVectorTests.cs` |
| Architecture gate | `scripts/ci/verify-windows-storage-architecture.sh` |

## Explicit non-claims

- Does **not** claim full 53-migration write/migration parity with GRDB on Windows.
- Does **not** claim every UI surface is storage-backed by default (see Substituted nav rows).
- Production UI composition that still fabricates demo datasets remains non-Real at the surface layer.
