# Android Release Credentials

This document tracks the Android release signing credentials and Google Play service account for the OpenBurnBar project.

## Secrets Inventory

| Secret Name                             | GitHub Secret | Firebase Secret | Purpose                                        |
| --------------------------------------- | ------------- | --------------- | ---------------------------------------------- |
| `OPENBURNBAR_ANDROID_KEYSTORE_BASE64`   | ✅ Yes        | ✅ Yes          | Base64-encoded release upload keystore (.jks)  |
| `OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD` | ✅ Yes        | ✅ Yes          | Password for the keystore file                 |
| `OPENBURNBAR_ANDROID_KEY_ALIAS`         | ✅ Yes        | ✅ Yes          | Alias of the signing key inside the keystore   |
| `OPENBURNBAR_ANDROID_KEY_PASSWORD`      | ✅ Yes        | ✅ Yes          | Password for the signing key alias             |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`      | ✅ Yes        | ✅ Yes          | Google Play Developer API service account JSON |

## Where the Source Files Live

These files are **never committed** to git. They are stored in the developer's local machine and the cloud secret managers.

| File                 | Local Path                                                                                                               | Description                                                      |
| -------------------- | ------------------------------------------------------------------------------------------------------------------------ | ---------------------------------------------------------------- |
| Upload keystore      | `~/.secrets/android/upload-keystore.jks`                                                                                 | Created May 11, 2026; alias `openburnbar-upload`                 |
| Keystore env         | `~/.secrets/android/release-signing.env`                                                                                 | Shell env file with keystore path, password, alias, key password |
| Service account JSON | `~/Library/Mobile Documents/com~apple~CloudDocs/imagine-that.ai/Super IMportant Files /AndroidAppServiceAccountKey.json` | Google Play service account for `imaginethat-17aa7` project      |

## How CI Uses Them

The GitHub Actions `release.yml` workflow:

1. Runs `scripts/ci/inject-android-keystore.sh` which:
   - Reads `OPENBURNBAR_ANDROID_KEYSTORE_BASE64`
   - Decodes it to `.secrets/android/upload-keystore.jks`
   - Writes `.secrets/android/.keystore-ci-injected` marker
2. Exports `OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD`, `OPENBURNBAR_ANDROID_KEY_ALIAS`, `OPENBURNBAR_ANDROID_KEY_PASSWORD` as env vars
3. Runs `./gradlew :app:bundleRelease` which reads the env vars and applies the `releaseUpload` signing config
4. The signed AAB is uploaded under its immutable versioned artifact name
5. After every release gate and native artifact proof succeeds, the protected
   `publish-google-play-internal` job:
   - downloads that exact AAB from the same workflow run,
   - validates it with the pinned, checksum-verified `bundletool`,
   - binds the embedded `versionName` and `versionCode` to the Play API call,
   - uploads or reuses the exact bundle idempotently,
   - refuses to replace a newer or in-progress Play release,
   - commits it to the `internal` track, and
   - reads the committed track back before retaining a 365-day receipt.

## How to Rotate the Keystore

**Warning:** Rotating the upload keystore requires creating a new key in Play Console and may break existing update paths. Only do this if the keystore is compromised.

1. Generate a new keystore:
   ```bash
   keytool -genkey -v -keystore upload-keystore-new.jks -keyalg RSA -keysize 2048 -validity 10000 -alias openburnbar-upload
   ```
2. Base64-encode the new keystore:
   ```bash
   base64 -i upload-keystore-new.jks | pbcopy
   ```
3. Update GitHub secret `OPENBURNBAR_ANDROID_KEYSTORE_BASE64` with the copied value
4. Update Firebase secret `OPENBURNBAR_ANDROID_KEYSTORE_BASE64`:
   ```bash
   firebase functions:secrets:set OPENBURNBAR_ANDROID_KEYSTORE_BASE64 --project burnbar
   ```
5. Update `OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD`, `OPENBURNBAR_ANDROID_KEY_ALIAS`, `OPENBURNBAR_ANDROID_KEY_PASSWORD` in both GitHub and Firebase
6. Update the local `~/.secrets/android/release-signing.env` file
7. Run a release build to verify the new keystore signs correctly

## How to Rotate the Service Account

1. In Google Cloud Console, go to IAM & Admin > Service Accounts
2. Enable the Google Play Android Developer API for the service-account project
3. In Play Console → Users and permissions, invite the service-account email
   and grant only `com.openburnbar` access plus the permissions required to
   view app information and release builds to testing tracks. Do not grant
   account-wide admin or production-release access to the internal publisher.
4. Generate a new JSON key
5. Update the protected GitHub `release` environment secret
   `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` with the JSON content
6. Update Firebase secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`:
   ```bash
   firebase functions:secrets:set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON --project burnbar
   ```
7. Update the local file in iCloud Drive

## Verification Checklist

After any rotation or when an agent claims credentials are missing:

- [ ] `keytool -list -keystore ~/.secrets/android/upload-keystore.jks -alias openburnbar-upload` works with the stored password
- [ ] `gh secret list --repo Imagine-That-Ai/BurnBar | grep -E 'OPENBURNBAR_ANDROID|GOOGLE_PLAY'` shows all 5 secrets
- [ ] `firebase functions:secrets:access OPENBURNBAR_ANDROID_KEYSTORE_BASE64 --project burnbar` returns a valid base64 blob
- [ ] `gh workflow run release.yml` produces the versioned signed AAB artifact
- [ ] The AAB can be verified in Play Console or via `bundletool` (`jarsigner` does not work on `.aab` files)
- [ ] The `publish-google-play-internal` job succeeds and its retained receipt
      reports the embedded version code with `readback.status=completed`
- [ ] A Play-installed build on a physical device reports the same version code

## Agent Self-Service

If an agent needs to access these secrets for a build:

1. **Local builds**: Source the env file:

   ```bash
   source ~/.secrets/android/release-signing.env
   cd android && ./gradlew :app:bundleRelease
   ```

2. **CI builds**: The workflow already handles injection. If a build fails with "keystore password was incorrect", the GitHub secret may have been corrupted. Re-inject from the local source.

3. **Play Console uploads**: Release CI publishes automatically. For a
   controlled local recovery using an already-verified AAB:

   ```bash
   npm ci --prefix functions --omit=dev --ignore-scripts
   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(firebase functions:secrets:access GOOGLE_PLAY_SERVICE_ACCOUNT_JSON --project burnbar)" \
     node tools/google-play/publish-internal-release.mjs \
       --aab /absolute/path/OpenBurnBar.aab \
       --expected-version-code 41 \
       --version-name 1.0.31 \
       --track internal \
       --receipt /tmp/google-play-internal-release-receipt.json \
       --confirm-google-play-publish burnbar-google-play-internal
   ```

   The caller must derive the expected version code from the exact AAB with the
   pinned `bundletool`; do not guess it from source. A 401/403 usually means
   the service account is missing Play Console app/track permissions, not a
   Google Cloud project role.

4. **Play Console API grants**: OpenBurnBar's Play developer account is
   `5605378652941109095`. The Firebase/Cloud Functions compute service account
   `246956661961-compute@developer.gserviceaccount.com` has full app-level
   access for `com.openburnbar`. The stored
   `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` service account
   `android-iap-service@imaginethat-17aa7.iam.gserviceaccount.com` is also
   granted app-level access for catalog automation and purchase verification.
   Verify catalog state with:
   ```bash
   GOOGLE_PLAY_SERVICE_ACCOUNT_JSON="$(firebase functions:secrets:access GOOGLE_PLAY_SERVICE_ACCOUNT_JSON --project burnbar)" \
     node tools/google-play/prepare-commercial-iaps.mjs --json
   ```

## Emergency: Keystore Lost

GitHub Actions secrets are write-only and cannot be downloaded through the API.
If the local keystore file is lost, recover it only from an independently
retained encrypted backup or from Firebase Secret Manager when that copy is
current and access is authorized:

```bash
firebase functions:secrets:access OPENBURNBAR_ANDROID_KEYSTORE_BASE64 --project burnbar \
  | base64 --decode > /secure/recovery/path/upload-keystore.jks
```

Verify the recovered keystore fingerprint against the approved upload
certificate before restoring any CI secret. If no retrievable trusted copy
remains, the keystore is unrecoverable. You must:

1. Generate a new keystore
2. Contact Google Play support to reset the upload key
3. Re-upload the new keystore to both local storage and all secret managers
