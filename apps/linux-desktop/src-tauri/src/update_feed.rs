use ed25519_dalek::pkcs8::{DecodePublicKey, EncodePublicKey};
use ed25519_dalek::{Signature, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use std::collections::HashSet;
use std::time::{Duration, SystemTime, UNIX_EPOCH};

const DEFAULT_FEED_URL: &str = "https://downloads.burnbar.ai/latest-linux.json";
const MAX_FEED_BYTES: usize = 1024 * 1024;
const MAX_SIGNATURE_BYTES: usize = 1024;
const MAX_FEED_AGE_SECONDS: u64 = 7 * 24 * 60 * 60;
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
    pub instructions: Option<LinuxUpdateInstructions>,
    pub package_channel: Option<String>,
    pub channel_info: Option<LinuxUpdateChannelInfo>,
    pub signature_state: String,
    pub feed_freshness: String,
    pub feed_age_seconds: Option<u64>,
    pub checked_at_unix_seconds: u64,
    pub compatibility: Option<LinuxUpdateCompatibility>,
    pub reason: Option<String>,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxUpdateChannelInfo {
    pub id: String,
    pub label: String,
    pub owner: String,
    pub install_mode: String,
    pub automatic_install: bool,
    pub rollback_mode: String,
    pub explanation: String,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxUpdateCompatibility {
    pub state: String,
    pub shell_version: String,
    pub daemon_version: Option<String>,
    pub reason: Option<String>,
}

/// Package-manager-owned actions exposed to the renderer as fixed, audited
/// instructions. The desktop shell never executes these strings; users run
/// them through their distro's terminal/package UI after reviewing the signed
/// feed result.
#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxUpdateAction {
    pub id: String,
    pub label: String,
    pub instruction: String,
    pub command: Option<String>,
    pub available: bool,
    pub requires_confirmation: bool,
}

#[derive(Debug, Clone, Serialize)]
#[serde(rename_all = "camelCase")]
pub struct LinuxUpdateInstructions {
    pub package_manager: String,
    pub install: LinuxUpdateAction,
    pub rollback: LinuxUpdateAction,
    pub restart: LinuxUpdateAction,
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
            instructions: None,
            package_channel: None,
            channel_info: None,
            signature_state: "unknown".into(),
            feed_freshness: "unknown".into(),
            feed_age_seconds: None,
            checked_at_unix_seconds: now_unix_seconds(),
            compatibility: None,
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
            instructions: None,
            package_channel: None,
            channel_info: None,
            signature_state: "rejected".into(),
            feed_freshness: "unknown".into(),
            feed_age_seconds: None,
            checked_at_unix_seconds: now_unix_seconds(),
            compatibility: None,
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
    let Some(artifact_type) = artifact_type_for_package_channel(package_channel) else {
        return LinuxUpdateStatus::unavailable(
            current_version,
            format!("Installed package channel {package_channel} is unsupported."),
        );
    };
    let artifact = select_artifact(&feed, artifact_type, architecture);
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
    let feed_version = feed.version.clone();
    let feed_channel = feed.channel.clone();
    let feed_published_at = feed.published_at.clone();
    let feed_notes = feed.notes.clone();
    let mut status = LinuxUpdateStatus {
        state: state.into(),
        current_version: current_version.into(),
        latest_version: Some(feed_version),
        channel: Some(feed_channel),
        published_at: Some(feed_published_at.clone()),
        notes: feed_notes,
        artifact: Some(artifact),
        instructions: None,
        package_channel: Some(package_channel.to_string()),
        channel_info: Some(channel_info(package_channel)),
        signature_state: "verified".into(),
        feed_freshness: feed_freshness(&feed_published_at),
        feed_age_seconds: feed_age_seconds(&feed_published_at),
        checked_at_unix_seconds: now_unix_seconds(),
        compatibility: None,
        reason: None,
    };
    status.instructions = Some(build_update_instructions(
        package_channel,
        current_version,
        status.latest_version.as_deref(),
    ));
    status
}

/// Attach deterministic package-manager instructions to a status that may
/// have failed before the signed feed was available. This keeps recovery UX
/// useful during outages without inventing release metadata or a download URL.
pub fn attach_update_instructions(
    mut status: LinuxUpdateStatus,
    package_channel: &str,
) -> LinuxUpdateStatus {
    status.package_channel = Some(package_channel.to_string());
    status.channel_info = Some(channel_info(package_channel));
    if status.instructions.is_none() {
        status.instructions = Some(build_update_instructions(
            package_channel,
            &status.current_version,
            status.latest_version.as_deref(),
        ));
    }
    if status.artifact.is_none()
        || status.signature_state != "verified"
        || status.feed_freshness != "fresh"
    {
        if let Some(instructions) = status.instructions.as_mut() {
            instructions.install.available = false;
            instructions.rollback.available = false;
        }
    }
    status
}

/// Add daemon compatibility facts after the signed feed check. The daemon
/// version is optional because an offline daemon must remain a typed,
/// recoverable state rather than being represented as a fake match.
pub fn attach_compatibility(
    mut status: LinuxUpdateStatus,
    shell_version: &str,
    daemon_version: Option<&str>,
) -> LinuxUpdateStatus {
    let (state, reason) = match daemon_version {
        None => (
            "unknown",
            Some("Daemon version is unavailable; reconnect before installing an update.".into()),
        ),
        Some(version) if version == shell_version => ("aligned", None),
        Some(version) => (
            "mismatch",
            Some(format!(
                "Shell {shell_version} and daemon {version} differ; restart after the package manager finishes."
            )),
        ),
    };
    status.compatibility = Some(LinuxUpdateCompatibility {
        state: state.into(),
        shell_version: shell_version.into(),
        daemon_version: daemon_version.map(str::to_string),
        reason,
    });
    let package_actions_allowed = status.signature_state == "verified"
        && status.feed_freshness == "fresh"
        && status
            .compatibility
            .as_ref()
            .is_some_and(|compatibility| compatibility.state == "aligned");
    if !package_actions_allowed {
        if let Some(instructions) = status.instructions.as_mut() {
            instructions.install.available = false;
            instructions.rollback.available = false;
        }
    }
    status
}

fn channel_info(package_channel: &str) -> LinuxUpdateChannelInfo {
    match package_channel {
        "deb" => LinuxUpdateChannelInfo {
            id: "deb".into(),
            label: "Debian package (.deb)".into(),
            owner: "apt/dpkg".into(),
            install_mode: "package-manager-guided".into(),
            automatic_install: false,
            rollback_mode: "apt-version-selection".into(),
            explanation: "The distro package manager owns files and upgrades; OpenBurnBar only verifies release metadata and shows safe guidance.".into(),
        },
        "rpm" => LinuxUpdateChannelInfo {
            id: "rpm".into(),
            label: "RPM package (.rpm)".into(),
            owner: "dnf/rpm".into(),
            install_mode: "package-manager-guided".into(),
            automatic_install: false,
            rollback_mode: "dnf-history".into(),
            explanation: "The distro package manager owns files and upgrades; OpenBurnBar never replaces RPM-owned files from the shell.".into(),
        },
        "arch" => LinuxUpdateChannelInfo {
            id: "arch".into(),
            label: "Arch package (.pkg.tar.zst)".into(),
            owner: "pacman".into(),
            install_mode: "package-manager-guided".into(),
            automatic_install: false,
            rollback_mode: "pacman-cache".into(),
            explanation: "The Arch package manager owns files and upgrades; OpenBurnBar never replaces pacman-owned files from the shell.".into(),
        },
        "appimage" => LinuxUpdateChannelInfo {
            id: "appimage".into(),
            label: "AppImage".into(),
            owner: "user-managed artifact".into(),
            install_mode: "artifact-replacement-guided".into(),
            automatic_install: false,
            rollback_mode: "previous-artifact".into(),
            explanation: "AppImage replacement is user-managed; keep a signed previous image and preserve its executable bit before relaunching.".into(),
        },
        _ => LinuxUpdateChannelInfo {
            id: "unknown".into(),
            label: "Unknown package channel".into(),
            owner: "unresolved".into(),
            install_mode: "unavailable".into(),
            automatic_install: false,
            rollback_mode: "unavailable".into(),
            explanation: "The owning package channel is not known, so install and rollback actions stay unavailable until it is identified.".into(),
        },
    }
}

fn artifact_type_for_package_channel(package_channel: &str) -> Option<&'static str> {
    match package_channel {
        "deb" => Some("deb"),
        "rpm" => Some("rpm"),
        "arch" => Some("arch"),
        "appimage" => Some("appimage"),
        _ => None,
    }
}

fn select_artifact(
    feed: &LinuxUpdateFeed,
    artifact_type: &str,
    architecture: &str,
) -> Option<LinuxUpdateArtifact> {
    feed.artifacts
        .iter()
        .find(|artifact| artifact.r#type == artifact_type && artifact.architecture == architecture)
        .cloned()
}

fn now_unix_seconds() -> u64 {
    SystemTime::now()
        .duration_since(UNIX_EPOCH)
        .map(|duration| duration.as_secs())
        .unwrap_or(0)
}

fn feed_freshness(published_at: &str) -> String {
    let Some(published) = timestamp_to_unix_seconds(published_at) else {
        return "unknown".into();
    };
    let now = now_unix_seconds() as i64;
    if published > now.saturating_add(300) {
        "future".into()
    } else if now.saturating_sub(published) as u64 > MAX_FEED_AGE_SECONDS {
        "stale".into()
    } else {
        "fresh".into()
    }
}

fn feed_age_seconds(published_at: &str) -> Option<u64> {
    let published = timestamp_to_unix_seconds(published_at)?;
    let now = now_unix_seconds() as i64;
    if published > now {
        return None;
    }
    Some(now.saturating_sub(published) as u64)
}

/// Convert the already-validated UTC timestamp shape to Unix seconds without
/// pulling a date/time dependency into the native shell.
fn timestamp_to_unix_seconds(value: &str) -> Option<i64> {
    let (date, time) = value.split_once('T')?;
    let year = date.get(0..4)?.parse::<i64>().ok()?;
    let month = date.get(5..7)?.parse::<i64>().ok()?;
    let day = date.get(8..10)?.parse::<i64>().ok()?;
    let clock = time.strip_suffix('Z')?;
    let mut parts = clock.split(':');
    let hour = parts.next()?.parse::<i64>().ok()?;
    let minute = parts.next()?.parse::<i64>().ok()?;
    let second_part = parts.next()?;
    let second = second_part.get(0..2)?.parse::<i64>().ok()?;
    let y = year - if month <= 2 { 1 } else { 0 };
    let era = (if y >= 0 { y } else { y - 399 }) / 400;
    let year_of_era = y - era * 400;
    let month_prime = month + if month > 2 { -3 } else { 9 };
    let day_of_year = (153 * month_prime + 2) / 5 + day - 1;
    let day_of_era = year_of_era * 365 + year_of_era / 4 - year_of_era / 100 + day_of_year;
    let days = era * 146_097 + day_of_era - 719_468;
    Some(days * 86_400 + hour * 3_600 + minute * 60 + second)
}

fn build_update_instructions(
    package_channel: &str,
    current_version: &str,
    latest_version: Option<&str>,
) -> LinuxUpdateInstructions {
    let channel = match package_channel {
        "deb" => "apt",
        "rpm" => "dnf",
        "arch" => "pacman",
        "appimage" => "appimage",
        _ => "unknown",
    };
    let version = latest_version
        .filter(|value| compare_semver(value, "0.0.0").is_some())
        .unwrap_or(current_version);
    let install = match channel {
        "apt" => LinuxUpdateAction {
            id: "install".into(),
            label: "Update with apt".into(),
            instruction: "A signed direct-download artifact is available, but no apt repository channel is configured; install that artifact manually after verifying its digest.".into(),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        "dnf" => LinuxUpdateAction {
            id: "install".into(),
            label: "Update with dnf".into(),
            instruction: "A signed direct-download artifact is available, but no dnf repository channel is configured; install that artifact manually after verifying its digest.".into(),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        "pacman" => LinuxUpdateAction {
            id: "install".into(),
            label: "Update with pacman".into(),
            instruction: "A signed direct-download artifact is available, but no pacman repository channel is configured; install that artifact manually after verifying its digest.".into(),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        "appimage" => LinuxUpdateAction {
            id: "install".into(),
            label: "Replace the AppImage".into(),
            instruction: "Download the signed artifact, replace the current AppImage atomically, and keep its executable bit.".into(),
            command: None,
            available: true,
            requires_confirmation: true,
        },
        _ => LinuxUpdateAction {
            id: "install".into(),
            label: "Use your package manager".into(),
            instruction: "Identify the owning package channel before replacing OpenBurnBar.".into(),
            command: None,
            available: false,
            requires_confirmation: true,
        },
    };
    let rollback = match channel {
        "apt" => LinuxUpdateAction {
            id: "rollback".into(),
            label: "Roll back with apt".into(),
            instruction: format!(
                "No previous signed Debian artifact is attached to this feed (current: {current_version}, feed: {version}); rollback stays unavailable until release metadata supplies one."
            ),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        "dnf" => LinuxUpdateAction {
            id: "rollback".into(),
            label: "Roll back with dnf".into(),
            instruction: format!(
                "No previous signed RPM artifact is attached to this feed (current: {current_version}, feed: {version}); rollback stays unavailable until release metadata supplies one."
            ),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        "pacman" => LinuxUpdateAction {
            id: "rollback".into(),
            label: "Roll back with pacman".into(),
            instruction: format!(
                "No previous signed Arch artifact is attached to this feed (current: {current_version}, feed: {version}); rollback stays unavailable until release metadata supplies one."
            ),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        "appimage" => LinuxUpdateAction {
            id: "rollback".into(),
            label: "Restore the previous AppImage".into(),
            instruction: "Restore a previously signed AppImage backup, verify its digest, and relaunch OpenBurnBar.".into(),
            command: None,
            available: false,
            requires_confirmation: true,
        },
        _ => LinuxUpdateAction {
            id: "rollback".into(),
            label: "Rollback guidance unavailable".into(),
            instruction: "The owning package channel is unknown; do not replace binaries until it is identified.".into(),
            command: None,
            available: false,
            requires_confirmation: true,
        },
    };
    let restart = LinuxUpdateAction {
        id: "restart".into(),
        label: "Restart OpenBurnBar".into(),
        instruction: if channel == "appimage" || channel == "unknown" {
            "Quit OpenBurnBar from the tray, replace or restore the signed artifact, then launch it again.".into()
        } else {
            "Quit OpenBurnBar from the tray, let the package manager finish, then launch it again."
                .into()
        },
        command: if channel == "appimage" || channel == "unknown" {
            None
        } else {
            Some("systemctl --user restart openburnbar-daemon.service".into())
        },
        available: true,
        requires_confirmation: false,
    };
    LinuxUpdateInstructions {
        package_manager: channel.into(),
        install,
        rollback,
        restart,
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
    if !is_utc_timestamp(&feed.published_at) {
        return Err("Update feed publication timestamp is invalid.".into());
    }
    if feed.signature.algorithm != "Ed25519"
        || feed.signature.public_key_spki_sha256 != PINNED_PUBLIC_KEY_SPKI_SHA256
    {
        return Err("Update feed signing identity does not match the pinned release key.".into());
    }
    let signature_url = reqwest::Url::parse(&feed.signature.url)
        .map_err(|_| "Update feed signature URL is invalid.".to_string())?;
    if !allowed_download_url(&signature_url) {
        return Err("Update feed signature URL is not allowlisted HTTPS.".into());
    }
    if feed.artifacts.is_empty() {
        return Err("Update feed has no artifacts.".into());
    }
    let mut keys = HashSet::new();
    for artifact in &feed.artifacts {
        if !matches!(
            artifact.r#type.as_str(),
            "appimage" | "arch" | "deb" | "rpm" | "daemon"
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
            let url = reqwest::Url::parse(raw_url)
                .map_err(|_| "Update artifact URL is invalid.".to_string())?;
            if !allowed_download_url(&url) {
                return Err("Update artifact URL is not allowlisted HTTPS.".into());
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

fn is_utc_timestamp(value: &str) -> bool {
    // Keep the release contract dependency-free while rejecting ambiguous
    // local timestamps and date-like strings. Fractional seconds are allowed
    // because the release assembler uses RFC3339 output from Date::toISOString.
    let Some((date, time)) = value.split_once('T') else {
        return false;
    };
    if date.len() != 10
        || !date.bytes().enumerate().all(|(index, byte)| {
            if matches!(index, 4 | 7) {
                byte == b'-'
            } else {
                byte.is_ascii_digit()
            }
        })
        || !time.ends_with('Z')
    {
        return false;
    }
    let year = date[..4].parse::<u32>().ok();
    let month = date[5..7].parse::<u8>().ok();
    let day = date[8..10].parse::<u8>().ok();
    let (Some(year), Some(month), Some(day)) = (year, month, day) else {
        return false;
    };
    let days_in_month = match month {
        1 | 3 | 5 | 7 | 8 | 10 | 12 => 31,
        4 | 6 | 9 | 11 => 30,
        2 if year % 400 == 0 || (year % 4 == 0 && year % 100 != 0) => 29,
        2 => 28,
        _ => 0,
    };
    if day == 0 || day > days_in_month {
        return false;
    }
    let clock = &time[..time.len() - 1];
    let clock_parts = clock.split(':').collect::<Vec<_>>();
    if clock_parts.len() != 3 {
        return false;
    }
    let hours = clock_parts[0];
    let minutes = clock_parts[1];
    let seconds = clock_parts[2];
    if hours.len() != 2 || minutes.len() != 2 || seconds.len() < 2 || !seconds.is_char_boundary(2) {
        return false;
    }
    if !hours.bytes().all(|byte| byte.is_ascii_digit())
        || !minutes.bytes().all(|byte| byte.is_ascii_digit())
        || !seconds[..2].bytes().all(|byte| byte.is_ascii_digit())
    {
        return false;
    }
    let fractional = &seconds[2..];
    if !fractional.is_empty() {
        if !fractional.starts_with('.') {
            return false;
        }
        let digits = &fractional[1..];
        if digits.is_empty() || !digits.bytes().all(|byte| byte.is_ascii_digit()) {
            return false;
        }
    }
    hours.parse::<u8>().is_ok_and(|value| value < 24)
        && minutes.parse::<u8>().is_ok_and(|value| value < 60)
        && seconds[..2].parse::<u8>().is_ok_and(|value| value < 60)
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
    if raw_url.len() > 2_048 {
        return Err("update_url_too_long".into());
    }
    let url = reqwest::Url::parse(raw_url).map_err(|_| "update_url_invalid".to_string())?;
    if !allowed_download_url(&url) || url.query().is_some() || url.fragment().is_some() {
        return Err("update_url_origin_refused".into());
    }
    let allowed_path = match url.host_str() {
        Some("burnbar.ai" | "www.burnbar.ai") => url.path().starts_with("/downloads/"),
        Some("github.com") => url
            .path()
            .starts_with("/Imagine-That-Ai/BurnBar/releases/download/"),
        _ => false,
    };
    if !allowed_path {
        return Err("update_url_path_refused".into());
    }
    Ok(url.to_string())
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
        let mut arch_feed = feed();
        arch_feed.artifacts.push(artifact("arch", "aarch64"));
        assert!(validate_feed(&arch_feed).is_ok());
        let mut missing = feed();
        missing.artifacts.pop();
        assert!(validate_feed(&missing).unwrap_err().contains("x86_64"));
    }

    #[test]
    fn rejects_ambiguous_publication_timestamps() {
        let mut invalid = feed();
        invalid.published_at = "2026-07-09 00:00:00Z".into();
        assert!(validate_feed(&invalid).unwrap_err().contains("timestamp"));
        invalid.published_at = "2026-07-09T25:00:00Z".into();
        assert!(validate_feed(&invalid).unwrap_err().contains("timestamp"));
        invalid.published_at = "2026-07-09T00:60:00Z".into();
        assert!(validate_feed(&invalid).unwrap_err().contains("timestamp"));
        invalid.published_at = "2026-07-09T00:00:60Z".into();
        assert!(validate_feed(&invalid).unwrap_err().contains("timestamp"));
        invalid.published_at = "2026-02-30T00:00:00Z".into();
        assert!(validate_feed(&invalid).unwrap_err().contains("timestamp"));
        invalid.published_at = "2026-13-01T00:00:00Z".into();
        assert!(validate_feed(&invalid).unwrap_err().contains("timestamp"));
        invalid.published_at = "2026-07-09T00:00:00.123Z".into();
        assert!(validate_feed(&invalid).is_ok());
    }

    #[test]
    fn package_actions_are_channel_native_and_fail_closed_for_unknown_channels() {
        let deb = build_update_instructions("deb", "1.0.0", Some("1.1.0"));
        assert_eq!(deb.package_manager, "apt");
        assert!(deb.install.command.is_none());
        assert!(!deb.install.available);
        assert!(deb.rollback.command.is_none());
        assert!(!deb.rollback.available);
        let rpm = build_update_instructions("rpm", "1.0.0", Some("1.1.0"));
        assert!(rpm.rollback.command.is_none());
        assert!(!rpm.rollback.available);
        let arch = build_update_instructions("arch", "1.0.0", Some("1.1.0"));
        assert_eq!(arch.package_manager, "pacman");
        assert_eq!(arch.install.label, "Update with pacman");
        assert!(!arch.install.available);
        assert!(arch.rollback.instruction.contains("Arch artifact"));
        let unknown = build_update_instructions("unknown", "1.0.0", None);
        assert!(!unknown.install.available);
        assert!(!unknown.rollback.available);
        assert!(unknown.install.command.is_none());
    }

    #[test]
    fn artifact_selection_never_falls_back_to_a_different_package_channel_or_architecture() {
        let release = feed();
        assert_eq!(artifact_type_for_package_channel("deb"), Some("deb"));
        assert_eq!(artifact_type_for_package_channel("rpm"), Some("rpm"));
        assert_eq!(artifact_type_for_package_channel("arch"), Some("arch"));
        assert_eq!(
            artifact_type_for_package_channel("appimage"),
            Some("appimage")
        );
        assert_eq!(artifact_type_for_package_channel("flatpak"), None);
        assert!(select_artifact(&release, "deb", "aarch64").is_none());
        assert!(select_artifact(&release, "rpm", "x86_64").is_none());
        assert!(select_artifact(&release, "appimage", "mips64").is_none());
        assert_eq!(
            select_artifact(&release, "appimage", "aarch64")
                .expect("matching appimage")
                .architecture,
            "aarch64"
        );
        let mut arch_release = release;
        arch_release.artifacts.push(artifact("arch", "aarch64"));
        assert_eq!(
            select_artifact(&arch_release, "arch", "aarch64")
                .expect("matching Arch package")
                .r#type,
            "arch"
        );
    }

    #[test]
    fn status_exposes_channel_ownership_and_signature_freshness_contract() {
        let status = attach_update_instructions(
            LinuxUpdateStatus::unavailable("1.0.0", "network unavailable"),
            "deb",
        );
        let channel = status.channel_info.expect("channel metadata");
        assert_eq!(channel.id, "deb");
        assert_eq!(channel.owner, "apt/dpkg");
        assert_eq!(channel.install_mode, "package-manager-guided");
        assert!(!channel.automatic_install);
        assert_eq!(status.package_channel.as_deref(), Some("deb"));
        assert_eq!(status.signature_state, "unknown");
        assert_eq!(status.feed_freshness, "unknown");
        assert!(status.checked_at_unix_seconds > 0);
    }

    #[test]
    fn compatibility_is_typed_and_never_assumes_an_offline_daemon_matches() {
        let status = LinuxUpdateStatus::unavailable("1.0.0", "network unavailable");
        let unknown = attach_compatibility(status, "1.0.0", None);
        let compatibility = unknown.compatibility.expect("compatibility metadata");
        assert_eq!(compatibility.state, "unknown");
        assert!(compatibility.daemon_version.is_none());

        let status = LinuxUpdateStatus::unavailable("1.0.0", "network unavailable");
        let mismatch = attach_compatibility(status, "1.0.0", Some("0.9.0"));
        let compatibility = mismatch.compatibility.expect("compatibility metadata");
        assert_eq!(compatibility.state, "mismatch");
        assert!(compatibility.reason.unwrap().contains("differ"));
    }

    #[test]
    fn aligned_daemon_preserves_only_real_appimage_install_guidance() {
        let mut status = LinuxUpdateStatus::unavailable("1.0.0", "signed feed");
        status.state = "available".into();
        status.artifact = Some(artifact("appimage", "x86_64"));
        status.signature_state = "verified".into();
        status.feed_freshness = "fresh".into();
        status.instructions = Some(build_update_instructions(
            "appimage",
            "1.0.0",
            Some("1.1.0"),
        ));
        let status = attach_compatibility(status, "1.0.0", Some("1.0.0"));
        let compatibility = status.compatibility.expect("compatibility metadata");
        assert_eq!(compatibility.state, "aligned");
        let instructions = status.instructions.expect("instructions");
        assert!(instructions.install.available);
        assert!(instructions.install.command.is_none());
        assert!(!instructions.rollback.available);
    }

    #[test]
    fn package_mutation_actions_are_disabled_when_feed_is_not_fresh() {
        let mut status = LinuxUpdateStatus::unavailable("1.0.0", "stale feed");
        status.state = "available".into();
        status.signature_state = "verified".into();
        status.feed_freshness = "stale".into();
        status.instructions = Some(build_update_instructions("deb", "1.0.0", Some("1.1.0")));
        let status = attach_compatibility(status, "1.0.0", Some("1.0.0"));
        let instructions = status.instructions.expect("instructions");
        assert!(!instructions.install.available);
        assert!(!instructions.rollback.available);
        assert!(instructions.restart.available);
    }

    #[test]
    fn stale_future_and_tampered_feed_states_are_not_mutation_ready() {
        assert_eq!(feed_freshness("2000-01-01T00:00:00Z"), "stale");
        assert_eq!(feed_freshness("2999-01-01T00:00:00Z"), "future");
        assert!(feed_age_seconds("2999-01-01T00:00:00Z").is_none());

        let mut tampered = LinuxUpdateStatus::invalid(
            "1.0.0",
            "Update feed detached Ed25519 signature verification failed.",
        );
        tampered.instructions = Some(build_update_instructions(
            "appimage",
            "1.0.0",
            Some("1.1.0"),
        ));
        let tampered = attach_compatibility(tampered, "1.0.0", Some("1.0.0"));
        let instructions = tampered.instructions.expect("instructions");
        assert_eq!(tampered.signature_state, "rejected");
        assert!(!instructions.install.available);
        assert!(!instructions.rollback.available);
    }

    #[test]
    fn timestamp_conversion_handles_epoch_and_fractional_utc_values() {
        assert_eq!(timestamp_to_unix_seconds("1970-01-01T00:00:00Z"), Some(0));
        assert_eq!(
            timestamp_to_unix_seconds("2000-01-01T00:00:00.123Z"),
            Some(946684800)
        );
        assert!(timestamp_to_unix_seconds("not-a-timestamp").is_none());
    }

    #[test]
    fn failed_feed_status_keeps_recovery_instructions_without_feed_metadata() {
        let status = attach_update_instructions(
            LinuxUpdateStatus::unavailable("1.0.0", "network unavailable"),
            "rpm",
        );
        let instructions = status.instructions.expect("recovery instructions");
        assert_eq!(instructions.package_manager, "dnf");
        assert!(instructions.install.command.is_none());
        assert!(!instructions.install.available);
        assert!(instructions.rollback.command.is_none());
        assert!(!instructions.rollback.available);
        assert!(status.latest_version.is_none());
    }

    #[test]
    fn rejects_untrusted_urls_and_signing_identity() {
        let mut bad = feed();
        bad.artifacts[0].url = "http://localhost/update".into();
        assert!(validate_feed(&bad).unwrap_err().contains("allowlisted"));
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
    fn replayed_signed_version_is_rejected_when_it_would_downgrade_or_is_stale() {
        assert!(classify_version("1.2.3", "1.2.2").is_err());
        let mut replay = LinuxUpdateStatus::unavailable("1.2.3", "replayed signed feed");
        replay.state = "current".into();
        replay.artifact = Some(artifact("appimage", "x86_64"));
        replay.signature_state = "verified".into();
        replay.feed_freshness = "stale".into();
        replay.instructions = Some(build_update_instructions(
            "appimage",
            "1.2.3",
            Some("1.2.3"),
        ));
        let replay = attach_compatibility(replay, "1.2.3", Some("1.2.3"));
        let instructions = replay.instructions.expect("instructions");
        assert!(!instructions.install.available);
        assert!(!instructions.rollback.available);
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
        for refused in [
            "https://github.com/another/repo/releases/download/v1/app",
            "https://github.com/Imagine-That-Ai/BurnBar/issues/1",
            "https://burnbar.ai/",
            "https://objects.githubusercontent.com/arbitrary",
            "http://burnbar.ai/downloads/app",
        ] {
            assert!(validate_update_artifact_url(refused).is_err(), "{refused}");
        }
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
