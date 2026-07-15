use openburnbar_domain_core::quota as core;
use openburnbar_domain_core::{
    cloudvault, cloudvault_rewrap, cloudvault_search, hermes, pensieve_vectors, pricing, quota,
};
use zeroize::{Zeroize, Zeroizing};

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

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CloudVaultSearchOperation {
    Token,
    Index,
    Query,
    Semantic,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultSearchRequest {
    pub operation: CloudVaultSearchOperation,
    pub text: String,
    pub vault_key: Vec<u8>,
    pub limit: i32,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultSearchAnalysis {
    pub normalized_tokens: Vec<String>,
    pub exact_phrase_tokens: Vec<String>,
    pub semantic_features: Vec<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultSearchResult {
    pub operation: CloudVaultSearchOperation,
    pub hashes: Vec<String>,
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

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum CloudVaultDocumentEnvelopeKind {
    SealedPayload,
    SealedText,
    Blob,
}

/// Typed, transport-safe representation of one CloudVault envelope.
/// Fields not used by `kind` must be absent; conversion fails closed otherwise.
#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultDocumentEnvelope {
    pub kind: CloudVaultDocumentEnvelopeKind,
    pub field_name: String,
    pub schema_version: Option<u32>,
    pub algorithm: String,
    pub key_version: u32,
    pub vault_key_id: Option<String>,
    pub nonce: Option<String>,
    pub ciphertext: Option<String>,
    pub tag: Option<String>,
    pub sealed_box_base64: Option<String>,
    pub plaintext_sha256: Option<String>,
    pub plaintext_hmac: Option<String>,
    pub integrity_hash_version: Option<u32>,
    pub aad: Option<String>,
    pub has_created_at: bool,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultDocumentRewrapRequest {
    pub uid: String,
    pub collection: String,
    pub doc_id: String,
    pub document_field_names: Vec<String>,
    pub envelopes: Vec<CloudVaultDocumentEnvelope>,
    pub reseal_nonce_plan: Vec<CloudVaultResealNonce>,
    pub vault_generation: Option<i64>,
    pub rotation_job_id: Option<String>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultResealNonce {
    pub field_name: String,
    pub nonce: Vec<u8>,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultCompanionUpdateIntent {
    pub source_field_name: String,
    pub companion_field_name: String,
    pub vault_key_id: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultPreservedEnvelopeMemberIntent {
    pub source_field_name: String,
    pub member_name: String,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct CloudVaultDocumentRewrapResult {
    pub changed_fields: Vec<String>,
    pub skipped_fields: Vec<String>,
    pub rewrapped_envelopes: Vec<CloudVaultDocumentEnvelope>,
    pub companion_update_intents: Vec<CloudVaultCompanionUpdateIntent>,
    pub preserved_member_intents: Vec<CloudVaultPreservedEnvelopeMemberIntent>,
    pub vault_generation_update: Option<i64>,
    pub rotation_job_id_update: Option<String>,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct TokenPricingRates {
    pub input_nano_usd_per_m_token: u64,
    pub output_nano_usd_per_m_token: u64,
    pub cache_creation_nano_usd_per_m_token: Option<u64>,
    pub cache_read_nano_usd_per_m_token: u64,
}

#[derive(Clone, Copy, Debug, uniffi::Record)]
pub struct TokenPricingBuckets {
    pub input_tokens: u64,
    pub output_tokens: u64,
    pub cache_creation_tokens: u64,
    pub cache_read_tokens: u64,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct LegacyKimiPricingResult {
    pub model: String,
    pub total_tokens: u64,
    pub cost_nano_usd: u64,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PricingFfiError {
    #[error("pricing arithmetic overflow")]
    ArithmeticOverflow,
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
    #[error("the CloudVault input exceeds its bounded contract")]
    InputTooLarge,
    #[error("cloud vault search text exceeds 1048576 UTF-8 bytes")]
    SearchTextTooLarge,
    #[error("cloud vault search limits must not exceed 1024")]
    SearchLimitTooLarge,
    #[error("cloud vault search input exceeds 4096 extracted tokens")]
    SearchTooManyTokens,
    #[error("the new vault key id does not match the new key")]
    NewVaultKeyIdMismatch,
    #[error("the document exceeds the rewrap field, field-name, or ciphertext bound")]
    RewrapBoundsExceeded,
    #[error("document field names and envelope field names must be unique and consistent")]
    InvalidRewrapFieldSet,
    #[error("the document rewrap envelope is invalid")]
    InvalidRewrapEnvelope,
    #[error("the caller must supply exactly one unique 12-byte nonce per resealed envelope")]
    InvalidRewrapNoncePlan,
    #[error("the sealed text plaintext is not valid UTF-8")]
    InvalidRewrapText,
    #[error("the source envelope integrity hash did not verify")]
    RewrapIntegrityMismatch,
    #[error("rewrap requires distinct old and new vault keys when any envelope changes")]
    InvalidRewrapKeyRotation,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum PensieveVectorFfiError {
    #[error("Pensieve vault keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("Pensieve vectors must contain between 1 and 4096 finite coordinates")]
    InvalidVector,
    #[error("Pensieve model versions must be non-empty bounded printable strings")]
    InvalidModelVersion,
    #[error("Pensieve embedding text must not exceed 1048576 UTF-8 bytes")]
    TextTooLarge,
    #[error("Pensieve vector key derivation failed")]
    DerivationFailure,
}

#[derive(Clone, Copy, Debug, uniffi::Enum)]
pub enum HermesAadKind {
    Request,
    Key,
    AuthenticatedRequest,
    AuthenticatedKey,
    Chunk,
    MediaSealKey,
    ControlSealKey,
    GatewayEvent,
    GatewayEventKey,
    GatewayMessage,
    GatewayMessageKey,
    GatewayAttachmentKey,
    GatewayAttachmentManifest,
    GatewayAttachmentBody,
}

#[derive(Clone, Debug, uniffi::Record)]
pub struct HermesRatchetPrekeyRequest {
    pub dh1: Vec<u8>,
    pub dh2: Vec<u8>,
    pub dh3: Vec<u8>,
    pub uid: String,
    pub client_id: String,
    pub initiator_role: String,
    pub initiator_identity_public_key_base64: String,
    pub responder_identity_public_key_base64: String,
    pub initiator_signed_prekey_public_key_base64: String,
    pub responder_signed_prekey_public_key_base64: String,
    pub initiator_initial_ratchet_public_key_base64: String,
}

#[derive(Debug, thiserror::Error, uniffi::Error)]
pub enum HermesFfiError {
    #[error("Hermes AAD argument count does not match its domain")]
    InvalidAadArguments,
    #[error("Hermes symmetric keys must be exactly 32 bytes")]
    InvalidKeyLength,
    #[error("Hermes AES-GCM nonces must be exactly 12 bytes")]
    InvalidNonceLength,
    #[error("Hermes ciphertext is malformed")]
    InvalidCiphertext,
    #[error("Hermes AES-GCM authentication failed")]
    AuthenticationFailed,
    #[error("Hermes HKDF output length is invalid")]
    InvalidHkdfLength,
    #[error("Hermes HMAC initialization failed")]
    HmacFailure,
    #[error("Hermes AAD components must not contain pipes or ASCII controls")]
    InvalidAadComponent,
    #[error("Hermes input exceeds its bounded contract")]
    InputTooLarge,
    #[error("Hermes P-256 keys must be exact on-curve 65-byte X9.63 points")]
    InvalidP256PublicKey,
    #[error("Hermes ratchet ECDH outputs must each be exactly 32 bytes")]
    InvalidRatchetSharedSecretLength,
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

const _: [(); 3] = [(); openburnbar_domain_core::DOMAIN_CORE_ABI_VERSION as usize];

#[uniffi::export]
pub fn domain_core_abi_version() -> u32 {
    openburnbar_domain_core::DOMAIN_CORE_ABI_VERSION
}

#[uniffi::export]
pub fn domain_core_version() -> String {
    env!("CARGO_PKG_VERSION").to_owned()
}

#[uniffi::export]
pub fn domain_core_source_fingerprint() -> String {
    env!("OPENBURNBAR_DOMAIN_CORE_SOURCE_FINGERPRINT").to_owned()
}

#[uniffi::export]
pub fn calculate_token_cost_nano_usd(
    rates: TokenPricingRates,
    buckets: TokenPricingBuckets,
) -> Result<u64, PricingFfiError> {
    Ok(pricing::token_cost_nano_usd(rates.into(), buckets.into())?)
}

#[uniffi::export]
pub fn is_legacy_kimi_wire_event(provider: String, model: String) -> bool {
    pricing::is_legacy_kimi_wire_event(&provider, &model)
}

#[uniffi::export]
pub fn price_legacy_kimi_wire_event(
    buckets: TokenPricingBuckets,
) -> Result<LegacyKimiPricingResult, PricingFfiError> {
    Ok(pricing::legacy_kimi_metrics(buckets.into())?.into())
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
pub fn cloud_vault_sha256_hex(data: Vec<u8>) -> Result<String, CloudVaultFfiError> {
    cloudvault::sha256_hex(&data).map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_key_id(mut key: Vec<u8>) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::vault_key_id(&key).map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_keyed_hash_hex(
    mut data: Vec<u8>,
    mut key: Vec<u8>,
    purpose: CloudVaultHashPurpose,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::keyed_hash_hex(&data, &key, purpose.into()).map_err(Into::into);
    data.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_expected_session_body_hash(
    mut data: Vec<u8>,
    mut key: Vec<u8>,
    body_hash_version: u32,
) -> Result<String, CloudVaultFfiError> {
    let result =
        cloudvault::expected_session_body_hash(&data, &key, body_hash_version).map_err(Into::into);
    data.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_project_memory_doc_id(
    mut slug: String,
    mut key: Vec<u8>,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::project_memory_doc_id(&slug, &key).map_err(Into::into);
    slug.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_pensieve_dedup_hash(
    mut plaintext: String,
    mut key: Vec<u8>,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::pensieve_dedup_hash(&plaintext, &key).map_err(Into::into);
    plaintext.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_pensieve_slug_hmac(
    mut slug: String,
    mut key: Vec<u8>,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::pensieve_slug_hmac(&slug, &key).map_err(Into::into);
    slug.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_subscription_doc_id(
    mut agent_uri: String,
    mut topic_id: String,
    mut key: Vec<u8>,
) -> Result<String, CloudVaultFfiError> {
    let result = cloudvault::subscription_doc_id(&agent_uri, &topic_id, &key).map_err(Into::into);
    agent_uri.zeroize();
    topic_id.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn pensieve_l2_normalize(mut vector: Vec<f64>) -> Result<Vec<f64>, PensieveVectorFfiError> {
    let result = pensieve_vectors::l2_normalize(&vector).map_err(Into::into);
    vector.zeroize();
    result
}

#[uniffi::export]
pub fn pensieve_vector_cloak(
    mut vector: Vec<f64>,
    mut vault_key: Vec<u8>,
    model_version: String,
) -> Result<Vec<f64>, PensieveVectorFfiError> {
    let result = pensieve_vectors::cloak(&vector, &vault_key, &model_version).map_err(Into::into);
    vector.zeroize();
    vault_key.zeroize();
    result
}

#[uniffi::export]
pub fn pensieve_deterministic_embed(
    mut text: String,
    dimensions: u32,
    is_query: bool,
) -> Result<Vec<f64>, PensieveVectorFfiError> {
    let dimensions =
        usize::try_from(dimensions).map_err(|_| PensieveVectorFfiError::InvalidVector)?;
    let result =
        pensieve_vectors::deterministic_embed(&text, dimensions, is_query).map_err(Into::into);
    text.zeroize();
    result
}

#[uniffi::export]
pub fn pensieve_deterministic_embed_and_cloak(
    mut text: String,
    dimensions: u32,
    is_query: bool,
    mut vault_key: Vec<u8>,
    model_version: String,
) -> Result<Vec<f64>, PensieveVectorFfiError> {
    let dimensions =
        usize::try_from(dimensions).map_err(|_| PensieveVectorFfiError::InvalidVector)?;
    let result = pensieve_vectors::deterministic_embed_and_cloak(
        &text,
        dimensions,
        is_query,
        &vault_key,
        &model_version,
    )
    .map_err(Into::into);
    text.zeroize();
    vault_key.zeroize();
    result
}

#[uniffi::export]
pub fn hermes_relay_aad(
    kind: HermesAadKind,
    arguments: Vec<String>,
) -> Result<Vec<u8>, HermesFfiError> {
    hermes::aad(kind.into(), &arguments).map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_key_wrap_info_v1(aad: Vec<u8>) -> Result<Vec<u8>, HermesFfiError> {
    hermes::key_wrap_info_v1(&aad).map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_key_wrap_info_v2(
    aad: Vec<u8>,
    enc: Vec<u8>,
    recipient_public_key: Vec<u8>,
    sender_public_key: Vec<u8>,
) -> Result<Vec<u8>, HermesFfiError> {
    hermes::key_wrap_info_v2(&aad, &enc, &recipient_public_key, &sender_public_key)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_hpke_v3_info(aad: Vec<u8>) -> Result<Vec<u8>, HermesFfiError> {
    hermes::hpke_v3_info(&aad).map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_hkdf_sha256(
    mut input_key_material: Vec<u8>,
    salt: Vec<u8>,
    info: Vec<u8>,
    output_byte_count: u32,
) -> Result<Vec<u8>, HermesFfiError> {
    let result = hermes::hkdf_sha256(
        &input_key_material,
        &salt,
        &info,
        output_byte_count as usize,
    )
    .map(|output| output.to_vec())
    .map_err(Into::into);
    input_key_material.zeroize();
    result
}

#[uniffi::export]
pub fn hermes_sha256(bytes: Vec<u8>) -> Result<Vec<u8>, HermesFfiError> {
    hermes::sha256(&bytes).map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_hmac_sha256(mut key: Vec<u8>, data: Vec<u8>) -> Result<Vec<u8>, HermesFfiError> {
    let output = hermes::hmac_sha256(&key, &data).map_err(Into::into);
    key.zeroize();
    output
}

#[uniffi::export]
// reason: explicit fields preserve the versioned ratchet wire contract across UniFFI.
#[allow(clippy::too_many_arguments, reason = "wire fields")]
pub fn hermes_ratchet_envelope_aad(
    associated_data: Vec<u8>,
    algorithm: String,
    session_id: String,
    sender_device_id: String,
    receiver_device_id: String,
    ratchet_public_key_base64: String,
    version: u64,
    previous_chain_length: u64,
    message_number: u64,
    epoch: u64,
) -> Result<Vec<u8>, HermesFfiError> {
    hermes::ratchet_envelope_aad(
        &associated_data,
        &algorithm,
        &session_id,
        &sender_device_id,
        &receiver_device_id,
        &ratchet_public_key_base64,
        version,
        previous_chain_length,
        message_number,
        epoch,
    )
    .map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_ratchet_prekey_shared_secret(
    mut request: HermesRatchetPrekeyRequest,
) -> Result<Vec<u8>, HermesFfiError> {
    let result = hermes::ratchet_prekey_shared_secret(hermes::RatchetPrekeyRequest {
        dh1: &request.dh1,
        dh2: &request.dh2,
        dh3: &request.dh3,
        uid: &request.uid,
        client_id: &request.client_id,
        initiator_role: &request.initiator_role,
        initiator_identity_public_key_base64: &request.initiator_identity_public_key_base64,
        responder_identity_public_key_base64: &request.responder_identity_public_key_base64,
        initiator_signed_prekey_public_key_base64: &request
            .initiator_signed_prekey_public_key_base64,
        responder_signed_prekey_public_key_base64: &request
            .responder_signed_prekey_public_key_base64,
        initiator_initial_ratchet_public_key_base64: &request
            .initiator_initial_ratchet_public_key_base64,
    })
    .map(|secret| secret.to_vec())
    .map_err(Into::into);
    request.dh1.zeroize();
    request.dh2.zeroize();
    request.dh3.zeroize();
    result
}

#[uniffi::export]
pub fn hermes_gateway_relay_safety_code(
    agent_public_key: Vec<u8>,
    phone_public_key: Vec<u8>,
) -> Result<String, HermesFfiError> {
    hermes::gateway_relay_safety_code(&agent_public_key, &phone_public_key).map_err(Into::into)
}

#[uniffi::export]
pub fn hermes_seal_base64(
    mut plaintext: Vec<u8>,
    mut key: Vec<u8>,
    aad: Vec<u8>,
    nonce: Vec<u8>,
) -> Result<String, HermesFfiError> {
    let result = hermes::seal_base64(&plaintext, &key, &aad, &nonce).map_err(Into::into);
    plaintext.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_aes_gcm_seal_detached(
    mut plaintext: Vec<u8>,
    mut key: Vec<u8>,
    nonce: Vec<u8>,
    aad: Vec<u8>,
) -> Result<CloudVaultAesGcmDetachedBox, CloudVaultFfiError> {
    let result = cloudvault::aes_gcm_seal_detached(&plaintext, &key, &nonce, &aad)
        .map(Into::into)
        .map_err(Into::into);
    plaintext.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn hermes_open_base64(
    ciphertext: String,
    mut key: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, HermesFfiError> {
    let result = hermes::open_base64(&ciphertext, &key, &aad).map_err(Into::into);
    key.zeroize();
    result
}

#[uniffi::export]
pub fn hermes_seal_combined(
    mut plaintext: Vec<u8>,
    mut key: Vec<u8>,
    aad: Vec<u8>,
    nonce: Vec<u8>,
) -> Result<Vec<u8>, HermesFfiError> {
    let result = hermes::seal_combined(&plaintext, &key, &aad, &nonce).map_err(Into::into);
    plaintext.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_aes_gcm_seal_combined(
    mut plaintext: Vec<u8>,
    mut key: Vec<u8>,
    nonce: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, CloudVaultFfiError> {
    let result =
        cloudvault::aes_gcm_seal_combined(&plaintext, &key, &nonce, &aad).map_err(Into::into);
    plaintext.zeroize();
    key.zeroize();
    result
}

#[uniffi::export]
pub fn hermes_open_combined(
    combined: Vec<u8>,
    mut key: Vec<u8>,
    aad: Vec<u8>,
) -> Result<Vec<u8>, HermesFfiError> {
    let result = hermes::open_combined(&combined, &key, &aad).map_err(Into::into);
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
pub fn cloud_vault_base64_encode(data: Vec<u8>) -> Result<String, CloudVaultFfiError> {
    cloudvault::base64_encode_checked(&data).map_err(Into::into)
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

#[uniffi::export]
pub fn cloud_vault_rewrap_document(
    request: CloudVaultDocumentRewrapRequest,
    old_key: Vec<u8>,
    new_key: Vec<u8>,
    new_vault_key_id: String,
) -> Result<CloudVaultDocumentRewrapResult, CloudVaultFfiError> {
    let old_key = Zeroizing::new(old_key);
    let new_key = Zeroizing::new(new_key);
    let request = request.try_into()?;
    cloudvault_rewrap::rewrap_document(&request, &old_key, &new_key, &new_vault_key_id)
        .map(Into::into)
        .map_err(Into::into)
}

#[uniffi::export]
pub fn cloud_vault_search_analyze(
    mut text: String,
) -> Result<CloudVaultSearchAnalysis, CloudVaultFfiError> {
    let result = cloudvault_search::analyze(&text)
        .map(Into::into)
        .map_err(Into::into);
    text.zeroize();
    result
}

#[uniffi::export]
pub fn cloud_vault_search(
    mut request: CloudVaultSearchRequest,
) -> Result<CloudVaultSearchResult, CloudVaultFfiError> {
    let result = cloudvault_search::search(
        request.operation.into(),
        &request.text,
        &request.vault_key,
        request.limit,
    )
    .map(Into::into)
    .map_err(Into::into);
    request.vault_key.zeroize();
    request.text.zeroize();
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

impl From<HermesAadKind> for hermes::AadKind {
    fn from(value: HermesAadKind) -> Self {
        match value {
            HermesAadKind::Request => Self::Request,
            HermesAadKind::Key => Self::Key,
            HermesAadKind::AuthenticatedRequest => Self::AuthenticatedRequest,
            HermesAadKind::AuthenticatedKey => Self::AuthenticatedKey,
            HermesAadKind::Chunk => Self::Chunk,
            HermesAadKind::MediaSealKey => Self::MediaSealKey,
            HermesAadKind::ControlSealKey => Self::ControlSealKey,
            HermesAadKind::GatewayEvent => Self::GatewayEvent,
            HermesAadKind::GatewayEventKey => Self::GatewayEventKey,
            HermesAadKind::GatewayMessage => Self::GatewayMessage,
            HermesAadKind::GatewayMessageKey => Self::GatewayMessageKey,
            HermesAadKind::GatewayAttachmentKey => Self::GatewayAttachmentKey,
            HermesAadKind::GatewayAttachmentManifest => Self::GatewayAttachmentManifest,
            HermesAadKind::GatewayAttachmentBody => Self::GatewayAttachmentBody,
        }
    }
}

impl From<TokenPricingRates> for pricing::TokenRates {
    fn from(value: TokenPricingRates) -> Self {
        Self {
            input_nano_usd_per_m_token: value.input_nano_usd_per_m_token,
            output_nano_usd_per_m_token: value.output_nano_usd_per_m_token,
            cache_creation_nano_usd_per_m_token: value.cache_creation_nano_usd_per_m_token,
            cache_read_nano_usd_per_m_token: value.cache_read_nano_usd_per_m_token,
        }
    }
}

impl From<hermes::HermesError> for HermesFfiError {
    fn from(value: hermes::HermesError) -> Self {
        match value {
            hermes::HermesError::InvalidAadArguments => Self::InvalidAadArguments,
            hermes::HermesError::InvalidKeyLength => Self::InvalidKeyLength,
            hermes::HermesError::InvalidNonceLength => Self::InvalidNonceLength,
            hermes::HermesError::InvalidCiphertext => Self::InvalidCiphertext,
            hermes::HermesError::AuthenticationFailed => Self::AuthenticationFailed,
            hermes::HermesError::InvalidHkdfLength => Self::InvalidHkdfLength,
            hermes::HermesError::HmacFailure => Self::HmacFailure,
            hermes::HermesError::InvalidAadComponent => Self::InvalidAadComponent,
            hermes::HermesError::InputTooLarge => Self::InputTooLarge,
            hermes::HermesError::InvalidP256PublicKey => Self::InvalidP256PublicKey,
            hermes::HermesError::InvalidRatchetSharedSecretLength => {
                Self::InvalidRatchetSharedSecretLength
            }
        }
    }
}

impl From<TokenPricingBuckets> for pricing::TokenBuckets {
    fn from(value: TokenPricingBuckets) -> Self {
        Self {
            input_tokens: value.input_tokens,
            output_tokens: value.output_tokens,
            cache_creation_tokens: value.cache_creation_tokens,
            cache_read_tokens: value.cache_read_tokens,
        }
    }
}

impl From<pricing::LegacyKimiMetrics> for LegacyKimiPricingResult {
    fn from(value: pricing::LegacyKimiMetrics) -> Self {
        Self {
            model: value.model,
            total_tokens: value.total_tokens,
            cost_nano_usd: value.cost_nano_usd,
        }
    }
}

impl From<pricing::PricingError> for PricingFfiError {
    fn from(value: pricing::PricingError) -> Self {
        match value {
            pricing::PricingError::ArithmeticOverflow => Self::ArithmeticOverflow,
        }
    }
}

impl From<pensieve_vectors::PensieveVectorError> for PensieveVectorFfiError {
    fn from(value: pensieve_vectors::PensieveVectorError) -> Self {
        match value {
            pensieve_vectors::PensieveVectorError::InvalidKeyLength => Self::InvalidKeyLength,
            pensieve_vectors::PensieveVectorError::InvalidVector => Self::InvalidVector,
            pensieve_vectors::PensieveVectorError::InvalidModelVersion => Self::InvalidModelVersion,
            pensieve_vectors::PensieveVectorError::TextTooLarge => Self::TextTooLarge,
            pensieve_vectors::PensieveVectorError::DerivationFailure => Self::DerivationFailure,
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
            cloudvault::CloudVaultError::InputTooLarge => Self::InputTooLarge,
        }
    }
}

impl From<CloudVaultSearchOperation> for cloudvault_search::CloudVaultSearchOperation {
    fn from(value: CloudVaultSearchOperation) -> Self {
        match value {
            CloudVaultSearchOperation::Token => Self::Token,
            CloudVaultSearchOperation::Index => Self::Index,
            CloudVaultSearchOperation::Query => Self::Query,
            CloudVaultSearchOperation::Semantic => Self::Semantic,
        }
    }
}

impl From<cloudvault_search::CloudVaultSearchOperation> for CloudVaultSearchOperation {
    fn from(value: cloudvault_search::CloudVaultSearchOperation) -> Self {
        match value {
            cloudvault_search::CloudVaultSearchOperation::Token => Self::Token,
            cloudvault_search::CloudVaultSearchOperation::Index => Self::Index,
            cloudvault_search::CloudVaultSearchOperation::Query => Self::Query,
            cloudvault_search::CloudVaultSearchOperation::Semantic => Self::Semantic,
        }
    }
}

impl From<cloudvault_search::CloudVaultSearchAnalysis> for CloudVaultSearchAnalysis {
    fn from(value: cloudvault_search::CloudVaultSearchAnalysis) -> Self {
        Self {
            normalized_tokens: value.normalized_tokens,
            exact_phrase_tokens: value.exact_phrase_tokens,
            semantic_features: value.semantic_features,
        }
    }
}

impl From<cloudvault_search::CloudVaultSearchResult> for CloudVaultSearchResult {
    fn from(value: cloudvault_search::CloudVaultSearchResult) -> Self {
        Self {
            operation: value.operation.into(),
            hashes: value.hashes,
        }
    }
}

impl From<cloudvault_search::CloudVaultSearchError> for CloudVaultFfiError {
    fn from(value: cloudvault_search::CloudVaultSearchError) -> Self {
        match value {
            cloudvault_search::CloudVaultSearchError::InvalidKeyLength => Self::InvalidKeyLength,
            cloudvault_search::CloudVaultSearchError::TextTooLarge => Self::SearchTextTooLarge,
            cloudvault_search::CloudVaultSearchError::LimitTooLarge => Self::SearchLimitTooLarge,
            cloudvault_search::CloudVaultSearchError::TooManyTokens => Self::SearchTooManyTokens,
            cloudvault_search::CloudVaultSearchError::DerivationFailure => Self::DerivationFailure,
        }
    }
}

impl From<cloudvault_rewrap::CloudVaultDocumentRewrapError> for CloudVaultFfiError {
    fn from(value: cloudvault_rewrap::CloudVaultDocumentRewrapError) -> Self {
        match value {
            cloudvault_rewrap::CloudVaultDocumentRewrapError::Crypto(error) => error.into(),
            cloudvault_rewrap::CloudVaultDocumentRewrapError::NewVaultKeyIdMismatch => {
                Self::NewVaultKeyIdMismatch
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::BoundsExceeded => {
                Self::RewrapBoundsExceeded
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::InvalidFieldSet => {
                Self::InvalidRewrapFieldSet
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::InvalidEnvelope => {
                Self::InvalidRewrapEnvelope
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::InvalidNoncePlan => {
                Self::InvalidRewrapNoncePlan
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::InvalidText => {
                Self::InvalidRewrapText
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::IntegrityMismatch => {
                Self::RewrapIntegrityMismatch
            }
            cloudvault_rewrap::CloudVaultDocumentRewrapError::InvalidKeyRotation => {
                Self::InvalidRewrapKeyRotation
            }
        }
    }
}

impl TryFrom<CloudVaultDocumentRewrapRequest>
    for cloudvault_rewrap::CloudVaultDocumentRewrapRequest
{
    type Error = CloudVaultFfiError;

    fn try_from(value: CloudVaultDocumentRewrapRequest) -> Result<Self, Self::Error> {
        Ok(Self {
            uid: value.uid,
            collection: value.collection,
            doc_id: value.doc_id,
            document_field_names: value.document_field_names,
            envelopes: value
                .envelopes
                .into_iter()
                .map(TryInto::try_into)
                .collect::<Result<Vec<_>, _>>()?,
            reseal_nonce_plan: value
                .reseal_nonce_plan
                .into_iter()
                .map(Into::into)
                .collect(),
            vault_generation: value.vault_generation,
            rotation_job_id: value.rotation_job_id,
        })
    }
}

impl From<CloudVaultResealNonce> for cloudvault_rewrap::CloudVaultResealNonce {
    fn from(value: CloudVaultResealNonce) -> Self {
        Self {
            field_name: value.field_name,
            nonce: value.nonce,
        }
    }
}

impl TryFrom<CloudVaultDocumentEnvelope> for cloudvault_rewrap::CloudVaultDocumentEnvelope {
    type Error = CloudVaultFfiError;

    fn try_from(value: CloudVaultDocumentEnvelope) -> Result<Self, Self::Error> {
        let CloudVaultDocumentEnvelope {
            kind,
            field_name,
            schema_version,
            algorithm,
            key_version,
            vault_key_id,
            nonce,
            ciphertext,
            tag,
            sealed_box_base64,
            plaintext_sha256,
            plaintext_hmac,
            integrity_hash_version,
            aad,
            has_created_at,
        } = value;
        match kind {
            CloudVaultDocumentEnvelopeKind::SealedPayload => {
                if nonce.is_some()
                    || ciphertext.is_some()
                    || tag.is_some()
                    || plaintext_sha256.is_some()
                    || plaintext_hmac.is_some()
                    || integrity_hash_version.is_some()
                    || has_created_at
                {
                    return Err(CloudVaultFfiError::InvalidRewrapEnvelope);
                }
                Ok(Self::SealedPayload {
                    field_name,
                    schema_version: schema_version
                        .ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    algorithm,
                    key_version,
                    vault_key_id: vault_key_id.ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    sealed_box_base64: sealed_box_base64
                        .ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    aad,
                })
            }
            CloudVaultDocumentEnvelopeKind::SealedText => {
                if vault_key_id.is_some()
                    || sealed_box_base64.is_some()
                    || plaintext_sha256.is_some()
                    || plaintext_hmac.is_some()
                    || integrity_hash_version.is_some()
                    || has_created_at
                {
                    return Err(CloudVaultFfiError::InvalidRewrapEnvelope);
                }
                Ok(Self::SealedText {
                    field_name,
                    schema_version,
                    algorithm,
                    key_version,
                    nonce: nonce.ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    ciphertext: ciphertext.ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    tag: tag.ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    aad,
                })
            }
            CloudVaultDocumentEnvelopeKind::Blob => {
                if vault_key_id.is_some()
                    || nonce.is_some()
                    || ciphertext.is_some()
                    || tag.is_some()
                {
                    return Err(CloudVaultFfiError::InvalidRewrapEnvelope);
                }
                Ok(Self::Blob {
                    field_name,
                    schema_version: schema_version
                        .ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    algorithm,
                    key_version,
                    plaintext_sha256,
                    plaintext_hmac,
                    integrity_hash_version,
                    sealed_box_base64: sealed_box_base64
                        .ok_or(CloudVaultFfiError::InvalidRewrapEnvelope)?,
                    aad,
                    has_created_at,
                })
            }
        }
    }
}

impl From<cloudvault_rewrap::CloudVaultDocumentRewrapResult> for CloudVaultDocumentRewrapResult {
    fn from(value: cloudvault_rewrap::CloudVaultDocumentRewrapResult) -> Self {
        Self {
            changed_fields: value.changed_fields,
            skipped_fields: value.skipped_fields,
            rewrapped_envelopes: value
                .rewrapped_envelopes
                .into_iter()
                .map(Into::into)
                .collect(),
            companion_update_intents: value
                .companion_update_intents
                .into_iter()
                .map(Into::into)
                .collect(),
            preserved_member_intents: value
                .preserved_member_intents
                .into_iter()
                .map(Into::into)
                .collect(),
            vault_generation_update: value.vault_generation_update,
            rotation_job_id_update: value.rotation_job_id_update,
        }
    }
}

impl From<cloudvault_rewrap::CloudVaultPreservedEnvelopeMemberIntent>
    for CloudVaultPreservedEnvelopeMemberIntent
{
    fn from(value: cloudvault_rewrap::CloudVaultPreservedEnvelopeMemberIntent) -> Self {
        Self {
            source_field_name: value.source_field_name,
            member_name: value.member_name,
        }
    }
}

impl From<cloudvault_rewrap::CloudVaultCompanionUpdateIntent> for CloudVaultCompanionUpdateIntent {
    fn from(value: cloudvault_rewrap::CloudVaultCompanionUpdateIntent) -> Self {
        Self {
            source_field_name: value.source_field_name,
            companion_field_name: value.companion_field_name,
            vault_key_id: value.vault_key_id,
        }
    }
}

impl From<cloudvault_rewrap::CloudVaultDocumentEnvelope> for CloudVaultDocumentEnvelope {
    fn from(value: cloudvault_rewrap::CloudVaultDocumentEnvelope) -> Self {
        match value {
            cloudvault_rewrap::CloudVaultDocumentEnvelope::SealedPayload {
                field_name,
                schema_version,
                algorithm,
                key_version,
                vault_key_id,
                sealed_box_base64,
                aad,
            } => Self {
                kind: CloudVaultDocumentEnvelopeKind::SealedPayload,
                field_name,
                schema_version: Some(schema_version),
                algorithm,
                key_version,
                vault_key_id: Some(vault_key_id),
                nonce: None,
                ciphertext: None,
                tag: None,
                sealed_box_base64: Some(sealed_box_base64),
                plaintext_sha256: None,
                plaintext_hmac: None,
                integrity_hash_version: None,
                aad,
                has_created_at: false,
            },
            cloudvault_rewrap::CloudVaultDocumentEnvelope::SealedText {
                field_name,
                schema_version,
                algorithm,
                key_version,
                nonce,
                ciphertext,
                tag,
                aad,
            } => Self {
                kind: CloudVaultDocumentEnvelopeKind::SealedText,
                field_name,
                schema_version,
                algorithm,
                key_version,
                vault_key_id: None,
                nonce: Some(nonce),
                ciphertext: Some(ciphertext),
                tag: Some(tag),
                sealed_box_base64: None,
                plaintext_sha256: None,
                plaintext_hmac: None,
                integrity_hash_version: None,
                aad,
                has_created_at: false,
            },
            cloudvault_rewrap::CloudVaultDocumentEnvelope::Blob {
                field_name,
                schema_version,
                algorithm,
                key_version,
                plaintext_sha256,
                plaintext_hmac,
                integrity_hash_version,
                sealed_box_base64,
                aad,
                has_created_at,
            } => Self {
                kind: CloudVaultDocumentEnvelopeKind::Blob,
                field_name,
                schema_version: Some(schema_version),
                algorithm,
                key_version,
                vault_key_id: None,
                nonce: None,
                ciphertext: None,
                tag: None,
                sealed_box_base64: Some(sealed_box_base64),
                plaintext_sha256,
                plaintext_hmac,
                integrity_hash_version,
                aad,
                has_created_at,
            },
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
    fn ffi_surface_reports_reviewed_source_fingerprint() -> Result<(), serde_json::Error> {
        let manifest: serde_json::Value =
            serde_json::from_str(include_str!("../../union-abi-manifest.json"))?;

        let loaded = domain_core_source_fingerprint();
        assert_eq!(loaded.len(), 64);
        assert_eq!(
            Some(loaded.as_str()),
            manifest
                .get("sourceSha256")
                .and_then(serde_json::Value::as_str)
        );
        Ok(())
    }

    #[test]
    fn ffi_surface_uses_shared_domain_core_abi_authority() {
        assert_eq!(
            domain_core_abi_version(),
            openburnbar_domain_core::DOMAIN_CORE_ABI_VERSION
        );
    }

    #[test]
    fn ffi_pensieve_l2_normalize_preserves_the_public_contract(
    ) -> Result<(), PensieveVectorFfiError> {
        assert_eq!(pensieve_l2_normalize(vec![3.0, 4.0])?, vec![0.6, 0.8]);
        assert_eq!(pensieve_l2_normalize(Vec::new())?, Vec::<f64>::new());
        Ok(())
    }

    #[test]
    fn ffi_surface_reports_version_and_parses_without_throwing() -> Result<(), CloudVaultFfiError> {
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
            cloud_vault_sha256_hex(b"OpenBurnBar".to_vec())?,
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

    #[test]
    fn crypto_ffi_fails_closed_on_malformed_and_unauthenticated_inputs(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let key = vec![0x11; 32];
        let nonce = vec![0x22; 12];
        let aad = b"bound-context".to_vec();

        assert!(matches!(
            cloud_vault_aes_gcm_seal_combined(
                b"secret".to_vec(),
                key.clone(),
                vec![0; 11],
                aad.clone(),
            ),
            Err(CloudVaultFfiError::InvalidNonceLength)
        ));
        let cloudvault = cloud_vault_aes_gcm_seal_combined(
            b"secret".to_vec(),
            key.clone(),
            nonce.clone(),
            aad.clone(),
        )?;
        assert!(matches!(
            cloud_vault_aes_gcm_open_combined(
                cloudvault.clone(),
                key.clone(),
                b"wrong-context".to_vec(),
            ),
            Err(CloudVaultFfiError::AuthenticationFailed)
        ));
        let mut tampered_cloudvault = cloudvault;
        let last = tampered_cloudvault
            .last_mut()
            .ok_or_else(|| std::io::Error::other("CloudVault test envelope unexpectedly empty"))?;
        *last ^= 1;
        assert!(matches!(
            cloud_vault_aes_gcm_open_combined(tampered_cloudvault, key.clone(), aad.clone()),
            Err(CloudVaultFfiError::AuthenticationFailed)
        ));

        assert!(matches!(
            hermes_hkdf_sha256(vec![1], vec![], vec![], 0),
            Err(HermesFfiError::InvalidHkdfLength)
        ));
        assert!(matches!(
            hermes_hkdf_sha256(vec![1], vec![], vec![], 255 * 32 + 1),
            Err(HermesFfiError::InvalidHkdfLength)
        ));
        assert!(matches!(
            hermes_seal_combined(b"secret".to_vec(), key.clone(), aad.clone(), vec![0; 11],),
            Err(HermesFfiError::InvalidNonceLength)
        ));
        let hermes = hermes_seal_combined(b"secret".to_vec(), key.clone(), aad.clone(), nonce)?;
        assert!(matches!(
            hermes_open_combined(hermes.clone(), key.clone(), b"wrong-context".to_vec()),
            Err(HermesFfiError::AuthenticationFailed)
        ));
        let mut tampered_hermes = hermes;
        let last = tampered_hermes
            .last_mut()
            .ok_or_else(|| std::io::Error::other("Hermes test envelope unexpectedly empty"))?;
        *last ^= 1;
        assert!(matches!(
            hermes_open_combined(tampered_hermes, key, aad),
            Err(HermesFfiError::AuthenticationFailed)
        ));
        Ok(())
    }

    #[test]
    fn opaque_identifier_ffi_matches_wire_vectors() -> Result<(), Box<dyn std::error::Error>> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../../tests/fixtures/domain-core/cloudvault/v1/opaque-identifiers-kat.json"
        ))?;
        let key = decode_hex(
            fixture["vaultKeyHex"]
                .as_str()
                .ok_or_else(|| std::io::Error::other("fixture key must be a string"))?,
        );
        assert_eq!(
            cloud_vault_project_memory_doc_id(
                fixture["projectMemory"]["slug"]
                    .as_str()
                    .ok_or_else(|| std::io::Error::other("fixture slug must be a string"))?
                    .to_owned(),
                key.clone(),
            )?,
            fixture["projectMemory"]["documentID"]
        );
        assert_eq!(
            cloud_vault_pensieve_dedup_hash(
                fixture["pensieve"]["plaintext"]
                    .as_str()
                    .ok_or_else(|| std::io::Error::other("fixture plaintext must be a string"))?
                    .to_owned(),
                key.clone(),
            )?,
            fixture["pensieve"]["dedupHash"]
        );
        assert_eq!(
            cloud_vault_pensieve_slug_hmac(
                fixture["pensieve"]["slug"]
                    .as_str()
                    .ok_or_else(|| std::io::Error::other("fixture slug must be a string"))?
                    .to_owned(),
                key.clone(),
            )?,
            fixture["pensieve"]["slugHmac"]
        );
        assert_eq!(
            cloud_vault_subscription_doc_id(
                fixture["subscription"]["agentURI"]
                    .as_str()
                    .ok_or_else(|| std::io::Error::other("fixture agentURI must be a string"))?
                    .to_owned(),
                fixture["subscription"]["topicID"]
                    .as_str()
                    .ok_or_else(|| std::io::Error::other("fixture topicID must be a string"))?
                    .to_owned(),
                key,
            )?,
            fixture["subscription"]["documentID"]
        );
        assert!(matches!(
            cloud_vault_project_memory_doc_id("slug".to_owned(), vec![0; 31]),
            Err(CloudVaultFfiError::InvalidKeyLength)
        ));
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
