# Android App — Firebase Config

## google-services.json

The real `google-services.json` contains API keys. It is **never committed**.

### Local development

```bash
# 1. Register the Android app in Firebase Console (project: burnbar, package: com.openburnbar)
# 2. Download google-services.json
# 3. Copy it in place:
cp ~/Downloads/google-services.json android/app/google-services.json
```

The template at `android/app/google-services.json.template` is safe to commit — it contains only placeholder values.

### CI

CI injects the config from `GOOGLE_SERVICES_JSON_BASE64` (a GitHub Actions secret).

```bash
# Encode the real file for CI:
python3 -c "import base64; print(base64.b64encode(open('android/app/google-services.json','rb').read()).decode())"

# Add the output as a GitHub secret named GOOGLE_SERVICES_JSON_BASE64
```

The injection script is `scripts/ci/inject-firebase-config-android.sh`.

### git

`android/.gitignore` already excludes `google-services.json`.


## Java version

Android build requires **JDK 21** (Gradle 8.9 + AGP 8.7.3). On macOS:

```bash
brew install openjdk@21
export JAVA_HOME="/opt/homebrew/opt/openjdk@21"
```

Verify: `java -version` should show `21.x.x`.
