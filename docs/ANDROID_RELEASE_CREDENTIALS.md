# Android Release Credentials

This document tracks the Android release signing credentials and Google Play service account for the OpenBurnBar project.

## Secrets Inventory

| Secret Name | GitHub Secret | Firebase Secret | Purpose |
|-------------|-------------|-----------------|---------|
| `OPENBURNBAR_ANDROID_KEYSTORE_BASE64` | ✅ Yes | ✅ Yes | Base64-encoded release upload keystore (.jks) |
| `OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD` | ✅ Yes | ✅ Yes | Password for the keystore file |
| `OPENBURNBAR_ANDROID_KEY_ALIAS` | ✅ Yes | ✅ Yes | Alias of the signing key inside the keystore |
| `OPENBURNBAR_ANDROID_KEY_PASSWORD` | ✅ Yes | ✅ Yes | Password for the signing key alias |
| `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` | ✅ Yes | ✅ Yes | Google Play Developer API service account JSON |

## Where the Source Files Live

These files are **never committed** to git. They are stored in the developer's local machine and the cloud secret managers.

| File | Local Path | Description |
|------|-----------|-------------|
| Upload keystore | `~/.secrets/android/upload-keystore.jks` | Created May 11, 2026; alias `openburnbar-upload` |
| Keystore env | `~/.secrets/android/release-signing.env` | Shell env file with keystore path, password, alias, key password |
| Service account JSON | `~/Library/Mobile Documents/com~apple~CloudDocs/imagine-that.ai/Super IMportant Files /AndroidAppServiceAccountKey.json` | Google Play service account for `imaginethat-17aa7` project |

## How CI Uses Them

The GitHub Actions `release.yml` workflow:

1. Runs `scripts/ci/inject-android-keystore.sh` which:
   - Reads `OPENBURNBAR_ANDROID_KEYSTORE_BASE64`
   - Decodes it to `.secrets/android/upload-keystore.jks`
   - Writes `.secrets/android/.keystore-ci-injected` marker
2. Exports `OPENBURNBAR_ANDROID_KEYSTORE_PASSWORD`, `OPENBURNBAR_ANDROID_KEY_ALIAS`, `OPENBURNBAR_ANDROID_KEY_PASSWORD` as env vars
3. Runs `./gradlew :app:bundleRelease` which reads the env vars and applies the `releaseUpload` signing config
4. The signed AAB is uploaded as a GitHub Actions artifact named `app-release-aab`

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
2. Create a new service account with **Android Management** or **Android Publisher** roles
3. Generate a new JSON key
4. Update GitHub secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON` with the JSON content
5. Update Firebase secret `GOOGLE_PLAY_SERVICE_ACCOUNT_JSON`:
   ```bash
   firebase functions:secrets:set GOOGLE_PLAY_SERVICE_ACCOUNT_JSON --project burnbar
   ```
6. Update the local file in iCloud Drive

## Verification Checklist

After any rotation or when an agent claims credentials are missing:

- [ ] `keytool -list -keystore ~/.secrets/android/upload-keystore.jks -alias openburnbar-upload` works with the stored password
- [ ] `gh secret list --repo Imagine-That-Ai/BurnBar | grep -E 'OPENBURNBAR_ANDROID|GOOGLE_PLAY'` shows all 5 secrets
- [ ] `firebase functions:secrets:access OPENBURNBAR_ANDROID_KEYSTORE_BASE64 --project burnbar` returns a valid base64 blob
- [ ] `gh workflow run release.yml` or a PR build produces a signed `app-release.aab` artifact
- [ ] The AAB can be verified in Play Console or via `bundletool` (`jarsigner` does not work on `.aab` files)

## Agent Self-Service

If an agent needs to access these secrets for a build:

1. **Local builds**: Source the env file:
   ```bash
   source ~/.secrets/android/release-signing.env
   cd android && ./gradlew :app:bundleRelease
   ```

2. **CI builds**: The workflow already handles injection. If a build fails with "keystore password was incorrect", the GitHub secret may have been corrupted. Re-inject from the local source.

3. **Play Console uploads**: The service account JSON is needed for any automated Play Console API calls (uploading AABs, updating listings, etc.). If the API returns 401/403, the service account may need its key regenerated.

## Emergency: Keystore Lost

If the local keystore file is lost but the GitHub secret still exists:

```bash
# Recover from GitHub secret
cd /tmp
gh api repos/Imagine-That-Ai/BurnBar/actions/secrets/OPENBURNBAR_ANDROID_KEYSTORE_BASE64 > keystore.b64
echo "Decode the value and write to ~/.secrets/android/upload-keystore.jks"
```

If both local and GitHub copies are lost, the keystore is unrecoverable. You must:
1. Generate a new keystore
2. Contact Google Play support to reset the upload key
3. Re-upload the new keystore to both local storage and all secret managers
