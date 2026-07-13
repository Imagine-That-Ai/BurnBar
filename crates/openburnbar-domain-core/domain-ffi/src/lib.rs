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

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultAesGcmDetachedBox {
    pub nonce: Vec<u8>,
    pub ciphertext: Vec<u8>,
    pub tag: Vec<u8>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultRecoveryWrappedVaultKey {
    pub combined: Vec<u8>,
    pub verification_hash: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultEscrowWireParts {
    pub ephemeral_public_key: Vec<u8>,
    pub aes_gcm_combined: Vec<u8>,
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
    #[error("AES-256-GCM nonces must be exactly 12 bytes")]
    InvalidNonceLength,
    #[error("the AES-256-GCM combined box is too short")]
    InvalidCombinedLength,
    #[error("the AES-256-GCM authentication tag did not verify")]
    AuthenticationFailed,
    #[error("decrypted CloudVault text is not valid UTF-8")]
    InvalidUtf8,
    #[error("CloudVault Base64 must be canonical RFC 4648 standard encoding")]
    InvalidBase64,
    #[error("recovery keys must contain at least 20 normalized letters or numbers")]
    InvalidRecoveryKey,
    #[error("P-256 ECDH shared secrets must be exactly 32 bytes")]
    InvalidSharedSecretLength,
    #[error("P-256 public keys must be valid 65-byte uncompressed X9.63 points")]
    InvalidP256PublicKey,
    #[error("the P-256 escrow wire must contain a public key and AES-GCM combined box")]
    InvalidEscrowWireLength,
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

#[uniffi::export]
pub fn cloud_vault_aes_gcm_seal_detached(
    plaintext: Vec<u8>,
    mut key: Vec<u8>,
    nonce: Vec<u8>,
    aad: Vec<u8>,
) -> Result<CloudVaultAesGcmDetachedBox, CloudVaultFfiError> {
    let result = cloudvault::aes_gcm_seal_detached(&plaintext, &key, &nonce, &aad)
        .map(Into::into)
        .map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_aes_gcm_seal_combined(
    plaintext: Vec<u8>,
    mut key: Vec<u8>,
    nonce: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result =
        cloudvault::aes_gcm_seal_combined(&plaintext, &key, &nonce, &aad).map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_aes_gcm_open_detached(
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    tag: Vec<u8>,
    mut key: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::aes_gcm_open_detached(&nonce, &ciphertext, &tag, &key, &aad)
        .map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_aes_gcm_open_text_detached(
    nonce: Vec<u8>,
    ciphertext: Vec<u8>,
    tag: Vec<u8>,
    mut key: Vec<u8>,
    aad: Vec<u8>,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::aes_gcm_open_text_detached(&nonce, &ciphertext, &tag, &key, &aad)
        .map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_aes_gcm_open_combined(
    combined: Vec<u8>,
    mut key: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::aes_gcm_open_combined(&combined, &key, &aad).map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_base64_encode(data: Vec<u8>) -> String {
    cloudvault::base64_encode(&data)
}

#[uniffi::export]
pub fn cloud_vault_base64_decode_strict(value: String) -> Result<Vec<u8>, CloudVaultFfiError> {
    cloudvault::base64_decode_strict(&value).map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_normalize_recovery_key(
    mut recovery_key: String,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::normalize_recovery_key(&recovery_key).map_err(Into::into);
    recovery_key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_recovery_wrapping_key(
    mut recovery_key: String,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::recovery_wrapping_key(&recovery_key)
        .map(|mut key| {
            let output = key.to_vec();
            key.zeroize();
            output
        })
        .map_err(Into::into);
    recovery_key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_recovery_verification_hash(
    mut recovery_key: String,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::recovery_verification_hash(&recovery_key).map_err(Into::into);
    recovery_key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_recovery_wrap_vault_key(
    mut vault_key: Vec<u8>,
    mut recovery_key: String,
    nonce: Vec<u8>,
) -> Result<CloudVaultRecoveryWrappedVaultKey, CloudVaultFfiError> {
    let result = cloudvault::recovery_wrap_vault_key(&vault_key, &recovery_key, &nonce)
        .map(Into::into)
        .map_err(Into::into);
    vault_key.zeroize();
    recovery_key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_recovery_open_vault_key(
    combined: Vec<u8>,
    mut recovery_key: String,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::recovery_open_vault_key(&combined, &recovery_key).map_err(Into::into);
    recovery_key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_validate_p256_x963_public_key(
    public_key: Vec<u8>,
) -> Result<(), CloudVaultFfiError> {
    cloudvault::validate_p256_x963_public_key(&public_key).map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_escrow_wrapping_key(
    mut shared_secret: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::escrow_wrapping_key(&shared_secret)
        .map(|mut key| {
            let output = key.to_vec();
            key.zeroize();
            output
        })
        .map_err(Into::into);
    shared_secret.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_escrow_assemble_wire(
    ephemeral_public_key: Vec<u8>,
    aes_gcm_combined: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    cloudvault::escrow_assemble_wire(&ephemeral_public_key, &aes_gcm_combined).map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_escrow_split_wire(
    wire: Vec<u8>,
) -> Result<CloudVaultEscrowWireParts, CloudVaultFfiError> {
    cloudvault::escrow_split_wire(&wire)
        .map(Into::into)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_escrow_seal(
    mut plaintext: Vec<u8>,
    ephemeral_public_key: Vec<u8>,
    mut shared_secret: Vec<u8>,
    nonce: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::escrow_seal(&plaintext, &ephemeral_public_key, &shared_secret, &nonce)
        .map_err(Into::into);
    plaintext.zeroize();
    shared_secret.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_escrow_open(
    wire: Vec<u8>,
    mut shared_secret: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result = cloudvault::escrow_open(&wire, &shared_secret).map_err(Into::into);
    shared_secret.zeroize();
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
            cloudvault::CloudVaultError::InvalidNonceLength => Self::InvalidNonceLength,
            cloudvault::CloudVaultError::InvalidCombinedLength => Self::InvalidCombinedLength,
            cloudvault::CloudVaultError::AuthenticationFailed => Self::AuthenticationFailed,
            cloudvault::CloudVaultError::InvalidUtf8 => Self::InvalidUtf8,
            cloudvault::CloudVaultError::InvalidBase64 => Self::InvalidBase64,
            cloudvault::CloudVaultError::InvalidRecoveryKey => Self::InvalidRecoveryKey,
            cloudvault::CloudVaultError::InvalidSharedSecretLength => {
                Self::InvalidSharedSecretLength
            }
            cloudvault::CloudVaultError::InvalidP256PublicKey => Self::InvalidP256PublicKey,
            cloudvault::CloudVaultError::InvalidEscrowWireLength => Self::InvalidEscrowWireLength,
        }
    }
}

impl From<cloudvault::AesGcmDetachedBox> for CloudVaultAesGcmDetachedBox {
    fn from(value: cloudvault::AesGcmDetachedBox) -> Self {
        Self {
            nonce: value.nonce,
            ciphertext: value.ciphertext,
            tag: value.tag,
        }
    }
}

impl From<cloudvault::RecoveryWrappedVaultKey> for CloudVaultRecoveryWrappedVaultKey {
    fn from(value: cloudvault::RecoveryWrappedVaultKey) -> Self {
        Self {
            combined: value.combined,
            verification_hash: value.verification_hash,
        }
    }
}

impl From<cloudvault::EscrowWireParts> for CloudVaultEscrowWireParts {
    fn from(value: cloudvault::EscrowWireParts) -> Self {
        Self {
            ephemeral_public_key: value.ephemeral_public_key,
            aes_gcm_combined: value.aes_gcm_combined,
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
        let zero_key = vec![0; 32];
        let sealed = cloud_vault_aes_gcm_seal_detached(
            b"OpenBurnBar".to_vec(),
            zero_key.clone(),
            vec![0; 12],
            b"aad".to_vec(),
        )?;
        assert_eq!(
            cloud_vault_aes_gcm_open_text_detached(
                sealed.nonce,
                sealed.ciphertext,
                sealed.tag,
                zero_key,
                b"aad".to_vec(),
            )?,
            "OpenBurnBar"
        );
        assert!(matches!(
            cloud_vault_base64_decode_strict("AA==\n".into()),
            Err(CloudVaultFfiError::InvalidBase64)
        ));
        let recovery_key = "abc-defg-hjkm-npq-rst-vwxyz-23456789".to_owned();
        let recovery_wrapped = cloud_vault_recovery_wrap_vault_key(
            (0_u8..32).collect(),
            recovery_key.clone(),
            (0_u8..12).collect(),
        )?;
        assert_eq!(
            cloud_vault_recovery_open_vault_key(recovery_wrapped.combined, recovery_key)?,
            (0_u8..32).collect::<Vec<_>>()
        );

        let public_key = decode_hex(
            "046b17d1f2e12c4247f8bce6e563a440f277037d812deb33a0f4a13945d898c296\
             4fe342e2fe1a7f9b8ee7eb4a7c0f9e162bce33576b315ececbb6406837bf51f5",
        );
        cloud_vault_validate_p256_x963_public_key(public_key.clone())?;
        let shared_secret: Vec<u8> = (0xa0_u8..=0xbf).collect();
        let wire = cloud_vault_escrow_seal(
            vec![],
            public_key,
            shared_secret.clone(),
            (0_u8..12).collect(),
        )?;
        assert_eq!(
            cloud_vault_escrow_open(wire, shared_secret)?,
            Vec::<u8>::new()
        );
        Ok(())
    }

    fn decode_hex(value: &str) -> Vec<u8> {
        value
            .split_ascii_whitespace()
            .collect::<String>()
            .as_bytes()
            .chunks_exact(2)
            .filter_map(|pair| std::str::from_utf8(pair).ok())
            .filter_map(|pair| u8::from_str_radix(pair, 16).ok())
            .collect()
    }
}
