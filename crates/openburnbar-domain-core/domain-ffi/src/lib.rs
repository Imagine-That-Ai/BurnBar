use openburnbar_domain_core::quota as core;
use openburnbar_domain_core::{cloudvault, quota};
use zeroize::Zeroize;

pub const DOMAIN_CORE_ABI_VERSION: u32 = 2;

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CloudVaultHashPurpose {
    BlobIntegrity,
    SessionBody,
    SessionChunk,
    ProjectMemoryContent,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultAadContextInput {
    pub uid: String,
    pub collection: String,
    pub doc_id: String,
    pub field: String,
    pub schema_version: u32,
    pub purpose: Option<String>,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum CloudVaultFfiError {
    #[error("cloud vault keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("cloud vault AAD parts must be non-empty and contain no controls or pipe")]
    InvalidAadPart,
    #[error("cloud vault AAD schema versions must be at least 2")]
    InvalidSchemaVersion,
    #[error("the envelope AAD does not match the expected context")]
    AadMismatch,
    #[error("legacy CloudVault v1 AAD is rejected")]
    LegacyAadRejected,
    #[error("the session body hash version is unsupported")]
    UnsupportedHashVersion,
    #[error("the CloudVault key derivation failed")]
    DerivationFailure,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum QuotaParseStatus {
    Parsed,
    Empty,
    Malformed,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum QuotaSourceKind {
    OfficialApi,
    LocalCli,
    LocalSession,
    ManualEstimate,
    Unavailable,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum QuotaConfidence {
    Exact,
    Estimated,
    Unavailable,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum QuotaUnit {
    Percent,
    Requests,
    Tokens,
    Sessions,
    Lines,
    Files,
    Count,
    Currency,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum QuotaWindowKind {
    RollingHours,
    RollingDays,
    Daily,
    Weekly,
    Monthly,
    Lifetime,
    Custom,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum AnthropicCredentialShape {
    OauthBearer,
    ConsoleApiKey,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct QuotaBucket {
    pub key: String,
    pub label: String,
    pub window_kind: QuotaWindowKind,
    pub used_value: Option<f64>,
    pub limit_value: Option<f64>,
    pub remaining_value: Option<f64>,
    pub used_percent: Option<f64>,
    pub resets_at_unix: Option<f64>,
    pub unit: QuotaUnit,
    pub is_estimated: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct QuotaSnapshot {
    pub provider: String,
    pub source: QuotaSourceKind,
    pub confidence: QuotaConfidence,
    pub status_message: String,
    pub now_unix: Option<i64>,
    pub buckets: Vec<QuotaBucket>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct QuotaParseResult {
    pub status: QuotaParseStatus,
    pub snapshot: QuotaSnapshot,
}

#[uniffi::export]
pub fn domain_core_abi_version() -> u32 {
    DOMAIN_CORE_ABI_VERSION
}

#[uniffi::export]
pub fn domain_core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[uniffi::export]
pub fn cloud_vault_aad_v2(
    uid: String,
    collection: String,
    doc_id: String,
    field: String,
    schema_version: u32,
    purpose: Option<String>,
) -> Result<String, CloudVaultFfiError> {
    Ok(cloud_vault_aad_context(
        &uid,
        &collection,
        &doc_id,
        &field,
        schema_version,
        purpose.as_deref(),
    )?
    .v2_string())
}

#[uniffi::export]
pub fn cloud_vault_aad_v1(
    uid: String,
    collection: String,
    doc_id: String,
    field: String,
) -> Result<String, CloudVaultFfiError> {
    Ok(cloud_vault_aad_context(&uid, &collection, &doc_id, &field, 2, None)?.v1_string())
}

#[uniffi::export]
pub fn cloud_vault_resolve_aad(
    envelope_aad: String,
    context: CloudVaultAadContextInput,
    reject_legacy: bool,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    cloud_vault_aad_context(
        &context.uid,
        &context.collection,
        &context.doc_id,
        &context.field,
        context.schema_version,
        context.purpose.as_deref(),
    )?
    .resolve(&envelope_aad, reject_legacy)
    .map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_sha256_hex(data: Vec<u8>) -> String {
    cloudvault::sha256_hex(&data)
}

#[uniffi::export]
pub fn cloud_vault_key_id(mut key: Vec<u8>) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::vault_key_id(&key).map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_keyed_hash_hex(
    data: Vec<u8>,
    mut key: Vec<u8>,
    purpose: CloudVaultHashPurpose,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::keyed_hash_hex(&data, &key, purpose.into()).map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_expected_session_body_hash(
    data: Vec<u8>,
    mut key: Vec<u8>,
    body_hash_version: u32,
) -> Result<String, CloudVaultFfiError> {
    let result =
        cloudvault::expected_session_body_hash(&data, &key, body_hash_version).map_err(Into::into);
    key.zeroize();
    result
}

fn cloud_vault_aad_context(
    uid: &str,
    collection: &str,
    doc_id: &str,
    field: &str,
    schema_version: u32,
    purpose: Option<&str>,
) -> Result<cloudvault::CloudVaultAadContext, CloudVaultFfiError> {
    cloudvault::CloudVaultAadContext::new(uid, collection, doc_id, field, schema_version, purpose)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn parse_claude_statusline_quota(payload: Vec<u8>) -> QuotaParseResult {
    quota::parse_claude_statusline_quota(&payload).into()
}

impl From<CloudVaultHashPurpose> for cloudvault::CloudVaultHashPurpose {
    fn from(value: CloudVaultHashPurpose) -> Self {
        match value {
            CloudVaultHashPurpose::BlobIntegrity => Self::BlobIntegrity,
            CloudVaultHashPurpose::SessionBody => Self::SessionBody,
            CloudVaultHashPurpose::SessionChunk => Self::SessionChunk,
            CloudVaultHashPurpose::ProjectMemoryContent => Self::ProjectMemoryContent,
        }
    }
}

impl From<cloudvault::CloudVaultError> for CloudVaultFfiError {
    fn from(value: cloudvault::CloudVaultError) -> Self {
        match value {
            cloudvault::CloudVaultError::InvalidKeyLength => Self::InvalidKeyLength,
            cloudvault::CloudVaultError::InvalidAadPart => Self::InvalidAadPart,
            cloudvault::CloudVaultError::InvalidSchemaVersion => Self::InvalidSchemaVersion,
            cloudvault::CloudVaultError::AadMismatch => Self::AadMismatch,
            cloudvault::CloudVaultError::LegacyAadRejected => Self::LegacyAadRejected,
            cloudvault::CloudVaultError::UnsupportedHashVersion => Self::UnsupportedHashVersion,
            cloudvault::CloudVaultError::DerivationFailure => Self::DerivationFailure,
        }
    }
}

#[uniffi::export]
pub fn parse_codex_usage_quota(payload: Vec<u8>, now_unix: i64) -> QuotaParseResult {
    core::parse_codex_usage_quota(&payload, now_unix).into()
}

#[uniffi::export]
pub fn parse_cursor_usage_quota(payload: Vec<u8>, user_email: Option<String>) -> QuotaParseResult {
    core::parse_cursor_usage_quota(&payload, user_email.as_deref()).into()
}

#[uniffi::export]
pub fn parse_anthropic_rate_limit_headers(
    payload: Vec<u8>,
    now_unix: i64,
    shape: AnthropicCredentialShape,
) -> QuotaParseResult {
    core::parse_anthropic_rate_limit_headers(&payload, now_unix, shape.into()).into()
}

impl From<AnthropicCredentialShape> for core::AnthropicCredentialShape {
    fn from(value: AnthropicCredentialShape) -> Self {
        match value {
            AnthropicCredentialShape::OauthBearer => Self::OauthBearer,
            AnthropicCredentialShape::ConsoleApiKey => Self::ConsoleApiKey,
        }
    }
}

impl From<core::QuotaParseResult> for QuotaParseResult {
    fn from(value: core::QuotaParseResult) -> Self {
        Self {
            status: value.status.into(),
            snapshot: value.snapshot.into(),
        }
    }
}

impl From<core::QuotaParseStatus> for QuotaParseStatus {
    fn from(value: core::QuotaParseStatus) -> Self {
        match value {
            core::QuotaParseStatus::Parsed => Self::Parsed,
            core::QuotaParseStatus::Empty => Self::Empty,
            core::QuotaParseStatus::Malformed => Self::Malformed,
        }
    }
}

impl From<core::QuotaSnapshot> for QuotaSnapshot {
    fn from(value: core::QuotaSnapshot) -> Self {
        Self {
            provider: value.provider,
            source: value.source.into(),
            confidence: value.confidence.into(),
            status_message: value.status_message,
            now_unix: value.now_unix,
            buckets: value.buckets.into_iter().map(Into::into).collect(),
        }
    }
}

impl From<core::QuotaBucket> for QuotaBucket {
    fn from(value: core::QuotaBucket) -> Self {
        Self {
            key: value.key,
            label: value.label,
            window_kind: value.window_kind.into(),
            used_value: value.used_value,
            limit_value: value.limit_value,
            remaining_value: value.remaining_value,
            used_percent: value.used_percent,
            resets_at_unix: value.resets_at_unix,
            unit: value.unit.into(),
            is_estimated: value.is_estimated,
        }
    }
}

impl From<core::QuotaSourceKind> for QuotaSourceKind {
    fn from(value: core::QuotaSourceKind) -> Self {
        match value {
            core::QuotaSourceKind::OfficialApi => Self::OfficialApi,
            core::QuotaSourceKind::LocalCli => Self::LocalCli,
            core::QuotaSourceKind::LocalSession => Self::LocalSession,
            core::QuotaSourceKind::ManualEstimate => Self::ManualEstimate,
            core::QuotaSourceKind::Unavailable => Self::Unavailable,
        }
    }
}

impl From<core::QuotaConfidence> for QuotaConfidence {
    fn from(value: core::QuotaConfidence) -> Self {
        match value {
            core::QuotaConfidence::Exact => Self::Exact,
            core::QuotaConfidence::Estimated => Self::Estimated,
            core::QuotaConfidence::Unavailable => Self::Unavailable,
        }
    }
}

impl From<core::QuotaUnit> for QuotaUnit {
    fn from(value: core::QuotaUnit) -> Self {
        match value {
            core::QuotaUnit::Percent => Self::Percent,
            core::QuotaUnit::Requests => Self::Requests,
            core::QuotaUnit::Tokens => Self::Tokens,
            core::QuotaUnit::Sessions => Self::Sessions,
            core::QuotaUnit::Lines => Self::Lines,
            core::QuotaUnit::Files => Self::Files,
            core::QuotaUnit::Count => Self::Count,
            core::QuotaUnit::Currency => Self::Currency,
        }
    }
}

impl From<core::QuotaWindowKind> for QuotaWindowKind {
    fn from(value: core::QuotaWindowKind) -> Self {
        match value {
            core::QuotaWindowKind::RollingHours => Self::RollingHours,
            core::QuotaWindowKind::RollingDays => Self::RollingDays,
            core::QuotaWindowKind::Daily => Self::Daily,
            core::QuotaWindowKind::Weekly => Self::Weekly,
            core::QuotaWindowKind::Monthly => Self::Monthly,
            core::QuotaWindowKind::Lifetime => Self::Lifetime,
            core::QuotaWindowKind::Custom => Self::Custom,
        }
    }
}

uniffi::setup_scaffolding!();

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn ffi_surface_reports_version_and_parses_without_throwing() -> Result<(), CloudVaultFfiError> {
        assert_eq!(domain_core_abi_version(), 2);
        assert_eq!(domain_core_version(), "0.1.0");
        let result =
            parse_claude_statusline_quota(br#"{"five_hour":{"used_percentage":42}}"#.to_vec());
        assert!(matches!(result.status, QuotaParseStatus::Parsed));
        assert_eq!(result.snapshot.buckets.len(), 1);
        assert!(matches!(
            parse_codex_usage_quota(
                br#"{"rate_limit":{"primary_window":{"used_percent":1}}}"#.to_vec(),
                0
            )
            .status,
            QuotaParseStatus::Parsed
        ));
        assert!(matches!(
            parse_cursor_usage_quota(br#"{}"#.to_vec(), None).status,
            QuotaParseStatus::Parsed
        ));
        assert!(matches!(
            parse_anthropic_rate_limit_headers(
                br#"{"anthropic-ratelimit-requests-limit":"1"}"#.to_vec(),
                0,
                AnthropicCredentialShape::OauthBearer
            )
            .status,
            QuotaParseStatus::Parsed
        ));
        assert_eq!(
            cloud_vault_sha256_hex(b"OpenBurnBar".to_vec()),
            "59800516f507102c0d9257d31f7bc779b876d6ad343d610387e74ece02a35ad7"
        );
        let key: Vec<u8> = (0_u8..32).collect();
        assert_eq!(
            cloud_vault_key_id(key.clone())?,
            "v1_630dcd2966c4336691125448bbb25b4f"
        );
        assert_eq!(
            cloud_vault_aad_v2("u".into(), "c".into(), "d".into(), "f".into(), 2, None,)?,
            "OpenBurnBar-CloudVault-aad-v2|u|c|d|f|2|f"
        );
        assert!(matches!(
            cloud_vault_expected_session_body_hash(vec![], key, 99),
            Err(CloudVaultFfiError::UnsupportedHashVersion)
        ));
        Ok(())
    }
}
