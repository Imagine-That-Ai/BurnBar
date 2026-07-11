use ed25519_dalek::pkcs8::{DecodePublicKey, EncodePublicKey};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::time::Duration;

const DEFAULT_FEED_URL: &str = "https://downloads.burnbar.ai/latest-linux.json";
const MAX_FEED_BYTES: usize = 1024 * 1024;
const MAX_SIGNATURE_BYTES: usize = 1024;
const PINNED_PUBLIC_KEY_PEM: &str =
    include_str!("../../../../packaging/linux/openburnbar-linux-ed25519.pub.pem");
const PINNED_PUBLIC_KEY_SPKI_SHA256: &str =
    "0e0fd1f52af308d96c71571ef7e94f3e183218abf531760dfcc8ef8e499e5c37";

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LinuxUpdateFeed {
    schema_version: u32,
    product: String,
    platform: String,
    version: String,
    git_commit: String,
    published_at: String,
    channel: String,
    #[serde(default)]
    notes: Option<String>,
    artifacts: Vec<LinuxUpdateArtifact>,
    signature: LinuxUpdateSignature,
}

#[derive(Debug, Clone, Deserialize, Serialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
pub struct LinuxUpdateArtifact {
    pub r#type: String,
    pub architecture: String,
    pub url: String,
    pub sha256: String,
    pub size: u64,
    pub signature_url: String,
}

#[derive(Debug, Clone, Deserialize)]
#[serde(rename_all = "camelCase", deny_unknown_fields)]
struct LinuxUpdateSignature {
    algorithm: String,
    public_key_spki_sha256: String,
    url: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxUpdateStatus {
    pub state: String,
    pub current_version: String,
    pub latest_version: Option<String>,
    pub channel: Option<String>,
    pub published_at: Option<String>,
    pub notes: Option<String>,
    pub artifact: Option<LinuxUpdateArtifact>,
    pub reason: Option<String>,
}

impl LinuxUpdateStatus {
    fn unavailable(current_version: &str, reason: impl Into<String>) -> Self {
        Self {
            state: "unavailable".into(),
            current_version: current_version.into(),
            latest_version: None,
            channel: None,
            published_at: None,
            notes: None,
            artifact: None,
            reason: Some(reason.into()),
        }
    }

    fn invalid(current_version: &str, reason: impl Into<String>) -> Self {
        Self {
            state: "invalid".into(),
            current_version: current_version.into(),
            latest_version: None,
            channel: None,
            published_at: None,
            notes: None,
            artifact: None,
            reason: Some(reason.into()),
        }
    }
}

pub async fn check_linux_update(current_version: &str, package_channel: &str) -> LinuxUpdateStatus {
    let feed_url = if cfg!(debug_assertions) {
        std::env::var("OPENBURNBAR_UPDATE_FEED_URL")
            .unwrap_or_else(|_| DEFAULT_FEED_URL.to_string())
    } else {
        DEFAULT_FEED_URL.to_string()
    };
    let feed_url = match reqwest::Url::parse(&feed_url) {
        Ok(url) if allowed_feed_url(&url) => url,
        _ => {
            return LinuxUpdateStatus::invalid(
                current_version,
                "Update feed URL is not allowlisted.",
            )
        }
    };
    let client = match update_client() {
        Ok(client) => client,
        Err(error) => return LinuxUpdateStatus::unavailable(current_version, error),
    };

    let response = match client
        .get(feed_url)
        .header(reqwest::header::ACCEPT, "application/json")
        .send()
        .await
    {
        Ok(response) => response,
        Err(error) => {
            return LinuxUpdateStatus::unavailable(
                current_version,
                format!("Signed update feed could not be reached: {error}"),
            )
        }
    };
    if !response.status().is_success() {
        return LinuxUpdateStatus::unavailable(
            current_version,
            format!("Signed update feed returned HTTP {}.", response.status()),
        );
    }
    let content_type = response
        .headers()
        .get(reqwest::header::CONTENT_TYPE)
        .and_then(|value| value.to_str().ok())
        .unwrap_or("")
        .to_ascii_lowercase();
    if !content_type.contains("application/json") {
        return LinuxUpdateStatus::invalid(
            current_version,
            format!("Update feed returned a non-JSON content type: {content_type}"),
        );
    }
    if response
        .content_length()
        .is_some_and(|size| size as usize > MAX_FEED_BYTES)
    {
        return LinuxUpdateStatus::invalid(current_version, "Update feed exceeds the size limit.");
    }
    let feed_bytes = match response.bytes().await {
        Ok(bytes) if bytes.len() <= MAX_FEED_BYTES => bytes,
        Ok(_) => {
            return LinuxUpdateStatus::invalid(
                current_version,
                "Update feed exceeds the size limit.",
            )
        }
        Err(error) => {
            return LinuxUpdateStatus::unavailable(
                current_version,
                format!("Update feed body could not be read: {error}"),
            )
        }
    };
    let feed: LinuxUpdateFeed = match serde_json::from_slice(&feed_bytes) {
        Ok(feed) => feed,
        Err(error) => {
            return LinuxUpdateStatus::invalid(
                current_version,
                format!("Update feed schema is invalid: {error}"),
            )
        }
    };
    if let Err(error) = validate_feed(&feed) {
        return LinuxUpdateStatus::invalid(current_version, error);
    }
    if let Err(error) = verify_feed_signature(&client, &feed, &feed_bytes).await {
        return LinuxUpdateStatus::invalid(current_version, error);
    }

    let architecture = normalized_architecture(std::env::consts::ARCH);
    let artifact_type = match package_channel {
        "deb" => "deb",
        "rpm" => "rpm",
        _ => "appimage",
    };
    let artifact = feed
        .artifacts
        .iter()
        .find(|artifact| artifact.r#type == artifact_type && artifact.architecture == architecture)
        .cloned()
        .or_else(|| {
            feed.artifacts
                .iter()
                .find(|artifact| {
                    artifact.r#type == "appimage" && artifact.architecture == architecture
                })
                .cloned()
        });
    let Some(artifact) = artifact else {
        return LinuxUpdateStatus::invalid(
            current_version,
            format!(
                "Signed feed has no supported {architecture} artifact for this package channel."
            ),
        );
    };

    let state = match classify_version(current_version, &feed.version) {
        Ok(state) => state,
        Err(error) => return LinuxUpdateStatus::invalid(current_version, error),
    };
    LinuxUpdateStatus {
        state: state.into(),
        current_version: current_version.into(),
        latest_version: Some(feed.version),
        channel: Some(feed.channel),
        published_at: Some(feed.published_at),
        notes: feed.notes,
        artifact: Some(artifact),
        reason: None,
    }
}

fn update_client() -> Result<reqwest::Client, String> {
    reqwest::Client::builder()
        .timeout(Duration::from_secs(8))
        .redirect(reqwest::redirect::Policy::custom(|attempt| {
            if attempt.previous().len() >= 4 || !allowed_download_url(attempt.url()) {
                attempt.stop()
            } else {
                attempt.follow()
            }
        }))
        .user_agent(concat!("OpenBurnBar-Linux/", env!("CARGO_PKG_VERSION")))
        .build()
        .map_err(|error| format!("Update client could not start: {error}"))
}

fn validate_feed(feed: &LinuxUpdateFeed) -> Result<(), String> {
    if feed.schema_version != 1 || feed.product != "OpenBurnBar" || feed.platform != "linux" {
        return Err("Update feed product, platform, or schema version is invalid.".into());
    }
    if compare_semver(&feed.version, "0.0.0").is_none() {
        return Err("Update feed version is not strict semver.".into());
    }
    if feed.git_commit.len() != 40
        || !feed
            .git_commit
            .bytes()
            .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
    {
        return Err("Update feed commit is not a lowercase 40-character SHA.".into());
    }
    if !matches!(feed.channel.as_str(), "stable" | "prerelease" | "nightly") {
        return Err("Update feed channel is invalid.".into());
    }
    if feed.published_at.len() < 20 || !feed.published_at.ends_with('Z') {
        return Err("Update feed publication timestamp is invalid.".into());
    }
    if feed.signature.algorithm != "Ed25519"
        || feed.signature.public_key_spki_sha256 != PINNED_PUBLIC_KEY_SPKI_SHA256
    {
        return Err("Update feed signing identity does not match the pinned release key.".into());
    }
    let signature_url = reqwest::Url::parse(&feed.signature.url)
        .map_err(|_| "Update feed signature URL is invalid.".to_string())?;
    if validate_update_artifact_url_for_version(signature_url.as_str(), Some(&feed.version))
        .is_err()
    {
        return Err("Update feed signature URL is not an allowed release path.".into());
    }
    if feed.artifacts.is_empty() {
        return Err("Update feed has no artifacts.".into());
    }
    let mut keys = HashSet::new();
    for artifact in &feed.artifacts {
        if !matches!(
            artifact.r#type.as_str(),
            "appimage" | "deb" | "rpm" | "daemon"
        ) || !matches!(artifact.architecture.as_str(), "aarch64" | "x86_64")
            || artifact.size == 0
            || artifact.sha256.len() != 64
            || !artifact
                .sha256
                .bytes()
                .all(|byte| byte.is_ascii_hexdigit() && !byte.is_ascii_uppercase())
        {
            return Err("Update feed contains invalid artifact metadata.".into());
        }
        if !keys.insert((artifact.r#type.as_str(), artifact.architecture.as_str())) {
            return Err("Update feed contains duplicate artifact metadata.".into());
        }
        for raw_url in [&artifact.url, &artifact.signature_url] {
            if validate_update_artifact_url_for_version(raw_url, Some(&feed.version)).is_err() {
                return Err("Update artifact URL is not an allowed release path.".into());
            }
        }
    }
    for architecture in ["aarch64", "x86_64"] {
        if !keys.contains(&("appimage", architecture)) {
            return Err(format!(
                "Update feed is missing the {architecture} AppImage."
            ));
        }
    }
    Ok(())
}

async fn verify_feed_signature(
    client: &reqwest::Client,
    feed: &LinuxUpdateFeed,
    feed_bytes: &[u8],
) -> Result<(), String> {
    let response = client
        .get(&feed.signature.url)
        .header(reqwest::header::ACCEPT, "application/octet-stream")
        .send()
        .await
        .map_err(|error| format!("Update feed signature could not be reached: {error}"))?;
    if !response.status().is_success() {
        return Err(format!(
            "Update feed signature returned HTTP {}.",
            response.status()
        ));
    }
    if response
        .content_length()
        .is_some_and(|size| size as usize > MAX_SIGNATURE_BYTES)
    {
        return Err("Update feed signature exceeds the size limit.".into());
    }
    let bytes = response
        .bytes()
        .await
        .map_err(|error| format!("Update feed signature could not be read: {error}"))?;
    if bytes.len() != 64 {
        return Err("Update feed signature is not a 64-byte Ed25519 signature.".into());
    }
    let signature = Signature::from_slice(&bytes)
        .map_err(|_| "Update feed signature bytes are invalid.".to_string())?;
    let key = VerifyingKey::from_public_key_pem(PINNED_PUBLIC_KEY_PEM)
        .map_err(|_| "Pinned update public key is invalid.".to_string())?;
    let der = key
        .to_public_key_der()
        .map_err(|_| "Pinned update public key could not be encoded.".to_string())?;
    if format!("{:x}", Sha256::digest(der.as_bytes())) != PINNED_PUBLIC_KEY_SPKI_SHA256 {
        return Err("Pinned update public-key fingerprint is inconsistent.".into());
    }
    key.verify_strict(feed_bytes, &signature)
        .map_err(|_| "Update feed detached Ed25519 signature verification failed.".to_string())
}

fn allowed_feed_url(url: &reqwest::Url) -> bool {
    let allowed_path = match url.host_str() {
        Some("github.com") => {
            url.path() == "/Imagine-That-Ai/BurnBar/releases/latest/download/latest-linux.json"
        }
        Some("downloads.burnbar.ai") => {
            matches!(
                url.path(),
                "/latest-linux.json" | "/downloads/latest-linux.json"
            )
        }
        _ => false,
    };
    allowed_download_url(url) && allowed_path && url.query().is_none() && url.fragment().is_none()
}

pub fn validate_update_artifact_url(raw_url: &str) -> Result<String, String> {
    validate_update_artifact_url_for_version(raw_url, None)
}

fn validate_update_artifact_url_for_version(
    raw_url: &str,
    expected_version: Option<&str>,
) -> Result<String, String> {
    if raw_url.len() > 2_048 {
        return Err("update_url_too_long".into());
    }
    let url = reqwest::Url::parse(raw_url).map_err(|_| "update_url_invalid".to_string())?;
    if !allowed_download_url(&url) || url.query().is_some() || url.fragment().is_some() {
        return Err("update_url_origin_refused".into());
    }
    let allowed_path = match url.host_str() {
        Some("burnbar.ai" | "www.burnbar.ai") => url.path().starts_with("/downloads/"),
        Some("downloads.burnbar.ai") => {
            allowed_r2_release_artifact_path(url.path(), expected_version)
        }
        Some("github.com") => {
            url.path()
                .starts_with("/Imagine-That-Ai/BurnBar/releases/download/")
                && expected_release_version(url.path()).is_some_and(|version| {
                    expected_version.map_or(true, |expected| version == expected)
                })
        }
        _ => false,
    };
    if !allowed_path {
        return Err("update_url_path_refused".into());
    }
    Ok(url.to_string())
}

fn allowed_r2_release_artifact_path(path: &str, expected_version: Option<&str>) -> bool {
    let parts = path.split('/').collect::<Vec<_>>();
    if parts.len() != 5 || parts[0] != "" || parts[1] != "linux" || parts[2] != "releases" {
        return false;
    }
    let Some(version) = parts[3].strip_prefix("linux-v") else {
        return false;
    };
    let filename = parts[4];
    compare_semver(version, "0.0.0").is_some()
        && expected_version.map_or(true, |expected| version == expected)
        && !filename.is_empty()
        && filename != "."
        && filename != ".."
        && filename
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b'-'))
}

fn expected_release_version(path: &str) -> Option<&str> {
    let parts = path.split('/').collect::<Vec<_>>();
    parts.windows(2).find_map(|window| {
        window[0]
            .strip_prefix("linux-v")
            .filter(|version| !version.is_empty())
    })
}

fn allowed_download_url(url: &reqwest::Url) -> bool {
    url.scheme() == "https"
        && url.username().is_empty()
        && url.password().is_none()
        && matches!(
            url.host_str(),
            Some(
                "burnbar.ai"
                    | "www.burnbar.ai"
                    | "downloads.burnbar.ai"
                    | "github.com"
                    | "objects.githubusercontent.com"
                    | "github-releases.githubusercontent.com"
            )
        )
}

fn normalized_architecture(value: &str) -> &str {
    match value {
        "arm64" | "aarch64" => "aarch64",
        "amd64" | "x86_64" => "x86_64",
        other => other,
    }
}

fn compare_semver(left: &str, right: &str) -> Option<i32> {
    let parse = |value: &str| -> Option<[u64; 3]> {
        let parts = value.split('.').collect::<Vec<_>>();
        if parts.len() != 3
            || parts.iter().any(|part| {
                part.is_empty()
                    || (part.len() > 1 && part.starts_with('0'))
                    || !part.bytes().all(|byte| byte.is_ascii_digit())
            })
        {
            return None;
        }
        Some([
            parts[0].parse().ok()?,
            parts[1].parse().ok()?,
            parts[2].parse().ok()?,
        ])
    };
    let left = parse(left)?;
    let right = parse(right)?;
    Some(match left.cmp(&right) {
        std::cmp::Ordering::Less => -1,
        std::cmp::Ordering::Equal => 0,
        std::cmp::Ordering::Greater => 1,
    })
}

fn classify_version(current_version: &str, feed_version: &str) -> Result<&'static str, String> {
    match compare_semver(feed_version, current_version) {
        Some(value) if value > 0 => Ok("available"),
        Some(0) => Ok("current"),
        Some(_) => Err(format!(
            "Signed feed version {feed_version} is older than installed version {current_version}."
        )),
        None => Err("Current or feed version is not strict semver.".into()),
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    fn artifact(kind: &str, architecture: &str) -> LinuxUpdateArtifact {
        LinuxUpdateArtifact {
            r#type: kind.into(),
            architecture: architecture.into(),
            url: format!("https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/openburnbar-{kind}-{architecture}"),
            sha256: "a".repeat(64),
            size: 100,
            signature_url: format!("https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/openburnbar-{kind}-{architecture}.sig"),
        }
    }

    fn feed() -> LinuxUpdateFeed {
        LinuxUpdateFeed {
            schema_version: 1,
            product: "OpenBurnBar".into(),
            platform: "linux".into(),
            version: "1.2.3".into(),
            git_commit: "b".repeat(40),
            published_at: "2026-07-09T00:00:00Z".into(),
            channel: "prerelease".into(),
            notes: None,
            artifacts: vec![artifact("appimage", "aarch64"), artifact("appimage", "x86_64")],
            signature: LinuxUpdateSignature {
                algorithm: "Ed25519".into(),
                public_key_spki_sha256: PINNED_PUBLIC_KEY_SPKI_SHA256.into(),
                url: "https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/latest-linux.json.ed25519.sig".into(),
            },
        }
    }

    #[test]
    fn validates_strict_feed_and_required_architectures() {
        assert!(validate_feed(&feed()).is_ok());
        let mut missing = feed();
        missing.artifacts.pop();
        assert!(validate_feed(&missing).unwrap_err().contains("x86_64"));
    }

    #[test]
    fn rejects_untrusted_urls_and_signing_identity() {
        let mut bad = feed();
        bad.artifacts[0].url = "http://localhost/update".into();
        assert!(validate_feed(&bad)
            .unwrap_err()
            .contains("allowed release path"));
        let mut bad = feed();
        bad.signature.public_key_spki_sha256 = "c".repeat(64);
        assert!(validate_feed(&bad).unwrap_err().contains("pinned"));
    }

    #[test]
    fn semver_and_architecture_normalization_are_strict() {
        assert_eq!(compare_semver("1.2.4", "1.2.3"), Some(1));
        assert_eq!(compare_semver("1.2.3", "1.2.3"), Some(0));
        assert_eq!(compare_semver("1.2.2", "1.2.3"), Some(-1));
        assert_eq!(compare_semver("01.2.3", "1.2.3"), None);
        assert_eq!(normalized_architecture("arm64"), "aarch64");
        assert_eq!(normalized_architecture("amd64"), "x86_64");
    }

    #[test]
    fn downgrade_feed_comparison_is_rejected_by_the_status_contract() {
        assert_eq!(classify_version("1.2.3", "1.2.4").unwrap(), "available");
        assert_eq!(classify_version("1.2.3", "1.2.3").unwrap(), "current");
        assert!(classify_version("1.2.3", "1.2.2")
            .unwrap_err()
            .contains("older than installed"));
        assert!(classify_version("1.2.3", "1.2.3-beta.1").is_err());
    }

    #[test]
    fn pinned_key_fingerprint_matches_manifest_contract() {
        let key = VerifyingKey::from_public_key_pem(PINNED_PUBLIC_KEY_PEM).unwrap();
        let der = key.to_public_key_der().unwrap();
        assert_eq!(
            format!("{:x}", Sha256::digest(der.as_bytes())),
            PINNED_PUBLIC_KEY_SPKI_SHA256
        );
    }

    #[test]
    fn update_navigation_allows_only_first_party_release_paths() {
        assert!(validate_update_artifact_url(
            "https://github.com/Imagine-That-Ai/BurnBar/releases/download/linux-v1.2.3/OpenBurnBar_1.2.3_arm64.deb"
        )
        .is_ok());
        assert!(validate_update_artifact_url(
            "https://burnbar.ai/downloads/OpenBurnBar_1.2.3_aarch64.AppImage"
        )
        .is_ok());
        assert!(validate_update_artifact_url(
            "https://downloads.burnbar.ai/linux/releases/linux-v1.2.3/OpenBurnBar_1.2.3_aarch64.AppImage"
        )
        .is_ok());
        assert!(validate_update_artifact_url(
            "https://downloads.burnbar.ai/linux/releases/linux-v1.2.3/OpenBurnBar_1.2.3_aarch64.AppImage.ed25519.sig"
        )
        .is_ok());
        for refused in [
            "https://github.com/another/repo/releases/download/v1/app",
            "https://github.com/Imagine-That-Ai/BurnBar/issues/1",
            "https://burnbar.ai/",
            "https://objects.githubusercontent.com/arbitrary",
            "https://downloads.burnbar.ai/linux/releases/latest/app",
            "https://downloads.burnbar.ai/linux/releases/linux-v1.2.3/nested/app",
            "https://downloads.burnbar.ai/linux/releases/linux-v1.2.3/%2e%2e",
            "http://burnbar.ai/downloads/app",
        ] {
            assert!(validate_update_artifact_url(refused).is_err(), "{refused}");
        }
    }

    #[test]
    fn feed_artifact_version_must_match_feed_version() {
        let mut mismatched = feed();
        mismatched.artifacts[0].url =
            "https://downloads.burnbar.ai/linux/releases/linux-v9.9.9/OpenBurnBar.AppImage".into();
        assert!(validate_feed(&mismatched)
            .unwrap_err()
            .contains("allowed release path"));
    }

    #[test]
    fn production_feed_url_is_fixed_to_the_branded_download_origin() {
        assert!(allowed_feed_url(
            &reqwest::Url::parse(DEFAULT_FEED_URL).unwrap()
        ));
        let release_manifest: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../packaging/linux/release-manifest.json"
        ))
        .unwrap();
        assert_eq!(
            release_manifest["updateMetadata"]["publicUrl"].as_str(),
            Some(DEFAULT_FEED_URL)
        );
        for refused in [
            "https://burnbar.ai/latest-linux.json",
            "https://downloads.burnbar.ai/other.json",
            "https://downloads.burnbar.ai/latest-linux.json?ref=other",
        ] {
            assert!(!allowed_feed_url(&reqwest::Url::parse(refused).unwrap()));
        }
    }
}
