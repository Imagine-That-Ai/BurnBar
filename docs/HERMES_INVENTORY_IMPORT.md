# Hermes Inventory Import

OpenBurnBar can import existing Hermes conversations from the Mac Hermes data folder and make them available across devices after explicit user consent.

## User flow

1. On macOS, open **Hermes Setup** or **Settings → General → Chat Backends**.
2. Use **Bring your Hermes history** / **Import existing Hermes chats** to scan local Hermes data.
3. Choose storage:
   - **OpenBurnBar Cloud** uploads sealed conversation metadata plus encrypted session-log manifests, snippets, search terms, and bodies to the signed-in Firebase user namespace when the user enables hosted backup.
   - **iCloud Drive archive** is disabled until a sealed iCloud archive format ships. Current builds do not create new raw Hermes `SessionMirror` copies.
4. On iOS/iPadOS, the Hermes tab shows live host sessions and imported library sessions. Imported sessions open read-only unless a live Mac relay is connected.

## Data boundaries

- Local SQLite remains canonical for imported Mac records.
- Firebase is optional replication under `users/{uid}/conversations` and `users/{uid}/session_logs`; private fields are Cloud Vault sealed before upload.
- Legacy iCloud raw archive files may exist under `Documents/OpenBurnBar/SessionMirror/Hermes`, but the current raw mirror writer is disabled.
- Provider secrets and `API_SERVER_KEY` are not uploaded by this flow.

## Failure behavior

- Duplicate imports are idempotent by stable Hermes conversation id.
- Cloud upload waits for Firebase sign-in/cloud sync availability.
- iCloud import/export remains blocked until sealed archive support replaces the raw mirror.
