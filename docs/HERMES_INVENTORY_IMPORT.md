# Hermes Inventory Import

OpenBurnBar can import existing Hermes conversations from the Mac Hermes data folder and make them available across devices after explicit user consent.

## User flow

1. On macOS, open **Hermes Setup** or **Settings → General → Chat Backends**.
2. Use **Bring your Hermes history** / **Import existing Hermes chats** to scan local Hermes data.
3. Choose storage:
   - **OpenBurnBar Cloud** uploads conversation metadata and chunked transcript bodies to the signed-in Firebase user namespace so iPhone and iPad can read them.
   - **iCloud Drive archive** mirrors Hermes files and exports OpenBurnBar-normalized transcript JSON to the app iCloud Documents container for same-Apple-ID devices.
4. On iOS/iPadOS, the Hermes tab shows live host sessions and imported library sessions. Imported sessions open read-only unless a live Mac relay is connected.

## Data boundaries

- Local SQLite remains canonical for imported Mac records.
- Firebase is optional replication under `users/{uid}/conversations` and `users/{uid}/session_logs`.
- iCloud is an Apple-ID file archive under `Documents/OpenBurnBar/SessionMirror/Hermes`.
- Provider secrets and `API_SERVER_KEY` are not uploaded by this flow.

## Failure behavior

- Duplicate imports are idempotent by stable Hermes conversation id.
- Cloud upload waits for Firebase sign-in/cloud sync availability.
- iCloud reading requests download for not-yet-local ubiquitous files and shows available downloaded sessions first.
