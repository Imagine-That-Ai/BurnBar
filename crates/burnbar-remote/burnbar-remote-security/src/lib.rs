use std::collections::HashMap;
use std::fs::{self, OpenOptions};
use std::io::Write;
use std::path::{Path, PathBuf};
use std::sync::atomic::{AtomicBool, Ordering};
use std::sync::RwLock;
use std::time::Duration;

use async_trait::async_trait;
use burnbar_remote_core::{
    AccountId, DeviceId, EndpointId, GrantId, InputEvent, PermissionSet, SessionDescriptor,
    SessionId, SessionMode, TimestampMicros, WorkspaceId,
};
use ed25519_dalek::{Signature, Signer, SigningKey, Verifier, VerifyingKey};
use serde::{Deserialize, Serialize};
use sha2::{Digest, Sha256};
use thiserror::Error;
use zeroize::Zeroizing;

const SESSION_GRANT_SIGNING_CONTEXT: &[u8] = b"openburnbar.remote.session-grant.v1";
const AUDIT_CHAIN_SCHEMA_VERSION: u16 = 1;
pub const AUDIT_GENESIS_PARENT_HASH_HEX: &str =
    "0000000000000000000000000000000000000000000000000000000000000000";

#[cfg(all(target_os = "macos", feature = "macos-keychain"))]
const ERR_SEC_ITEM_NOT_FOUND: i32 = -25300;

#[derive(Debug, Error, Clone, PartialEq, Eq)]
pub enum AuthorizationError {
    #[error("peer endpoint is not authorized")]
    UnknownPeer,
    #[error("device has been revoked")]
    RevokedDevice,
    #[error("account or workspace binding does not match")]
    BindingMismatch,
    #[error("local consent is required before starting this session")]
    MissingLocalConsent,
    #[error("requested permissions exceed the authorized grant")]
    PermissionDenied,
    #[error("session grant is expired")]
    ExpiredGrant,
    #[error("replay detected for session {session_id}")]
    ReplayDetected { session_id: SessionId },
    #[error("security store lock poisoned")]
    StorePoisoned,
    #[error("pairing ticket is expired")]
    PairingExpired,
    #[error("secure key is unavailable")]
    KeyUnavailable,
    #[error("signature verification failed")]
    SignatureVerificationFailed,
    #[error("signature material is invalid")]
    InvalidSignatureMaterial,
    #[error("session grant signer is not trusted")]
    UntrustedSigner,
    #[error("session grant signer has been revoked")]
    RevokedSigner,
    #[error("session grant signer binding does not match grant account/workspace")]
    SignerBindingMismatch,
    #[error("rate limit exceeded for {scope}")]
    RateLimited { scope: String },
    #[error("high-risk action requires explicit confirmation")]
    HighRiskActionRequiresConfirmation,
    #[error("local kill switch is active")]
    KillSwitchActive,
    #[error("secure key name is invalid")]
    InvalidKeyName,
    #[error("secure storage failed: {0}")]
    SecureStorage(String),
    #[error("audit chain failed: {0}")]
    AuditChain(String),
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum DeviceTrustState {
    Paired,
    Trusted,
    Revoked,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuthorizedDeviceRecord {
    pub device_id: DeviceId,
    pub endpoint_id: EndpointId,
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub trust_state: DeviceTrustState,
    pub allowed_modes: Vec<SessionMode>,
    pub permissions: PermissionSet,
    pub local_consent_required: bool,
    pub max_session_ttl_micros: u64,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SessionGrant {
    pub grant_id: GrantId,
    pub descriptor: SessionDescriptor,
    pub signed_policy_hash: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct SignedSessionGrant {
    pub grant: SessionGrant,
    pub signer_key_id: String,
    pub public_key: Vec<u8>,
    pub signature: Vec<u8>,
}

impl SignedSessionGrant {
    pub fn sign(
        grant: SessionGrant,
        signer_key_id: impl Into<String>,
        signing_key_bytes: [u8; 32],
    ) -> Result<Self, AuthorizationError> {
        let signing_key = SigningKey::from_bytes(&signing_key_bytes);
        let payload = grant_signing_payload(&grant)?;
        let signature = signing_key.sign(&payload);
        Ok(Self {
            grant,
            signer_key_id: signer_key_id.into(),
            public_key: signing_key.verifying_key().to_bytes().to_vec(),
            signature: signature.to_bytes().to_vec(),
        })
    }

    /// Verifies cryptographic integrity against the public key embedded in the
    /// envelope. This is not authorization; callers must use
    /// `verify_with_trusted_signer` or a `SessionGrantVerifier` before accepting
    /// a grant for a control session.
    pub fn verify_untrusted_signature_only(&self) -> Result<(), AuthorizationError> {
        self.verify_with_public_key(&self.public_key)
    }

    pub fn verify_with_trusted_signer(
        &self,
        signer: &TrustedSignerRecord,
    ) -> Result<(), AuthorizationError> {
        if signer.revoked {
            return Err(AuthorizationError::RevokedSigner);
        }
        if self.signer_key_id != signer.signer_key_id {
            return Err(AuthorizationError::UntrustedSigner);
        }
        if self.grant.descriptor.account_id != signer.account_id
            || self.grant.descriptor.workspace_id != signer.workspace_id
        {
            return Err(AuthorizationError::SignerBindingMismatch);
        }
        if self.public_key != signer.public_key {
            return Err(AuthorizationError::SignatureVerificationFailed);
        }
        self.verify_with_public_key(&signer.public_key)
    }

    fn verify_with_public_key(&self, public_key: &[u8]) -> Result<(), AuthorizationError> {
        let public_key: [u8; 32] = public_key
            .try_into()
            .map_err(|_| AuthorizationError::InvalidSignatureMaterial)?;
        let signature: [u8; 64] = self
            .signature
            .as_slice()
            .try_into()
            .map_err(|_| AuthorizationError::InvalidSignatureMaterial)?;
        let verifying_key = VerifyingKey::from_bytes(&public_key)
            .map_err(|_| AuthorizationError::InvalidSignatureMaterial)?;
        let signature = Signature::from_bytes(&signature);
        verifying_key
            .verify(&grant_signing_payload(&self.grant)?, &signature)
            .map_err(|_| AuthorizationError::SignatureVerificationFailed)
    }
}

pub trait SessionGrantSigner: Send + Sync {
    fn sign_session_grant(
        &self,
        grant: SessionGrant,
    ) -> Result<SignedSessionGrant, AuthorizationError>;
}

pub trait SessionGrantVerifier: Send + Sync {
    fn verify_session_grant(&self, grant: &SignedSessionGrant) -> Result<(), AuthorizationError>;
}

pub struct Ed25519SessionGrantSigner {
    signer_key_id: String,
    signing_key_bytes: Zeroizing<[u8; 32]>,
}

impl Ed25519SessionGrantSigner {
    pub fn new(signer_key_id: impl Into<String>, signing_key_bytes: [u8; 32]) -> Self {
        Self {
            signer_key_id: signer_key_id.into(),
            signing_key_bytes: Zeroizing::new(signing_key_bytes),
        }
    }

    pub fn signer_key_id(&self) -> &str {
        &self.signer_key_id
    }

    pub fn public_key(&self) -> Vec<u8> {
        SigningKey::from_bytes(&self.signing_key_bytes)
            .verifying_key()
            .to_bytes()
            .to_vec()
    }
}

impl SessionGrantSigner for Ed25519SessionGrantSigner {
    fn sign_session_grant(
        &self,
        grant: SessionGrant,
    ) -> Result<SignedSessionGrant, AuthorizationError> {
        SignedSessionGrant::sign(
            grant,
            self.signer_key_id.clone(),
            *self.signing_key_bytes,
        )
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct TrustedSignerRecord {
    pub signer_key_id: String,
    pub public_key: Vec<u8>,
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub revoked: bool,
}

#[derive(Default)]
pub struct InMemoryTrustedSignerStore {
    signers_by_key_id: RwLock<HashMap<String, TrustedSignerRecord>>,
}

impl InMemoryTrustedSignerStore {
    pub fn upsert_signer(&self, signer: TrustedSignerRecord) -> Result<(), AuthorizationError> {
        self.signers_by_key_id
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .insert(signer.signer_key_id.clone(), signer);
        Ok(())
    }

    pub fn revoke_signer(&self, signer_key_id: &str) -> Result<(), AuthorizationError> {
        let mut guard = self
            .signers_by_key_id
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?;
        if let Some(record) = guard.get_mut(signer_key_id) {
            record.revoked = true;
        }
        Ok(())
    }
}

impl SessionGrantVerifier for InMemoryTrustedSignerStore {
    fn verify_session_grant(&self, grant: &SignedSessionGrant) -> Result<(), AuthorizationError> {
        let signer = self
            .signers_by_key_id
            .read()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .get(&grant.signer_key_id)
            .cloned()
            .ok_or(AuthorizationError::UntrustedSigner)?;
        grant.verify_with_trusted_signer(&signer)
    }
}

fn grant_signing_payload(grant: &SessionGrant) -> Result<Vec<u8>, AuthorizationError> {
    let encoded =
        postcard::to_stdvec(grant).map_err(|_| AuthorizationError::InvalidSignatureMaterial)?;
    let mut payload = Vec::with_capacity(SESSION_GRANT_SIGNING_CONTEXT.len() + 1 + encoded.len());
    payload.extend_from_slice(SESSION_GRANT_SIGNING_CONTEXT);
    payload.push(0);
    payload.extend_from_slice(&encoded);
    Ok(payload)
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct DeviceIdentity {
    pub device_id: DeviceId,
    pub endpoint_id: EndpointId,
    pub public_key: Vec<u8>,
    pub created_at: TimestampMicros,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PairingTicket {
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub device_id: DeviceId,
    pub endpoint_id: EndpointId,
    pub nonce: String,
    pub issued_at: TimestampMicros,
    pub expires_at: TimestampMicros,
    pub allowed_modes: Vec<SessionMode>,
    pub permissions: PermissionSet,
}

impl PairingTicket {
    pub fn is_expired(&self, now: TimestampMicros) -> bool {
        now > self.expires_at
    }

    pub fn into_authorized_record(
        self,
        now: TimestampMicros,
        local_consent_required: bool,
        max_session_ttl: Duration,
    ) -> Result<AuthorizedDeviceRecord, AuthorizationError> {
        if self.is_expired(now) {
            return Err(AuthorizationError::PairingExpired);
        }
        Ok(AuthorizedDeviceRecord {
            device_id: self.device_id,
            endpoint_id: self.endpoint_id,
            account_id: self.account_id,
            workspace_id: self.workspace_id,
            trust_state: DeviceTrustState::Paired,
            allowed_modes: self.allowed_modes,
            permissions: self.permissions,
            local_consent_required,
            max_session_ttl_micros: max_session_ttl.as_micros().min(u64::MAX as u128) as u64,
        })
    }
}

#[async_trait]
pub trait SecureKeyStore: Send + Sync {
    async fn read_key(&self, name: &str) -> Result<Zeroizing<Vec<u8>>, AuthorizationError>;
    async fn write_key(&self, name: &str, key: &[u8]) -> Result<(), AuthorizationError>;
    async fn delete_key(&self, name: &str) -> Result<(), AuthorizationError>;
}

#[derive(Default)]
pub struct InMemorySecureKeyStore {
    keys: RwLock<HashMap<String, Vec<u8>>>,
}

#[async_trait]
impl SecureKeyStore for InMemorySecureKeyStore {
    async fn read_key(&self, name: &str) -> Result<Zeroizing<Vec<u8>>, AuthorizationError> {
        validate_secure_key_name(name)?;
        self.keys
            .read()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .get(name)
            .cloned()
            .map(Zeroizing::new)
            .ok_or(AuthorizationError::KeyUnavailable)
    }

    async fn write_key(&self, name: &str, key: &[u8]) -> Result<(), AuthorizationError> {
        validate_secure_key_name(name)?;
        self.keys
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .insert(name.to_string(), key.to_vec());
        Ok(())
    }

    async fn delete_key(&self, name: &str) -> Result<(), AuthorizationError> {
        validate_secure_key_name(name)?;
        self.keys
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .remove(name);
        Ok(())
    }
}

fn validate_secure_key_name(name: &str) -> Result<(), AuthorizationError> {
    if name.is_empty()
        || name.len() > 128
        || !name
            .bytes()
            .all(|byte| byte.is_ascii_alphanumeric() || matches!(byte, b'.' | b'_' | b':' | b'-'))
    {
        return Err(AuthorizationError::InvalidKeyName);
    }
    Ok(())
}

#[cfg(all(target_os = "macos", feature = "macos-keychain"))]
#[derive(Clone, Debug)]
pub struct MacOsKeychainSecureKeyStore {
    service: String,
    account_prefix: String,
}

#[cfg(all(target_os = "macos", feature = "macos-keychain"))]
impl MacOsKeychainSecureKeyStore {
    pub fn new(account_prefix: impl Into<String>) -> Self {
        Self {
            service: "com.openburnbar.remote".to_string(),
            account_prefix: account_prefix.into(),
        }
    }

    fn account_for_name(&self, name: &str) -> Result<String, AuthorizationError> {
        validate_secure_key_name(name)?;
        Ok(format!("{}:{name}", self.account_prefix))
    }
}

#[cfg(all(target_os = "macos", feature = "macos-keychain"))]
#[async_trait]
impl SecureKeyStore for MacOsKeychainSecureKeyStore {
    async fn read_key(&self, name: &str) -> Result<Zeroizing<Vec<u8>>, AuthorizationError> {
        let service = self.service.clone();
        let account = self.account_for_name(name)?;
        let bytes = tokio::task::spawn_blocking(move || {
            let mut options =
                security_framework::passwords::PasswordOptions::new_generic_password(
                    &service, &account,
                );
            options.set_access_synchronized(Some(false));
            security_framework::passwords::generic_password(options)
        })
        .await
        .map_err(|err| AuthorizationError::SecureStorage(err.to_string()))?
        .map_err(map_keychain_error)?;
        Ok(Zeroizing::new(bytes))
    }

    async fn write_key(&self, name: &str, key: &[u8]) -> Result<(), AuthorizationError> {
        let service = self.service.clone();
        let account = self.account_for_name(name)?;
        let key = Zeroizing::new(key.to_vec());
        tokio::task::spawn_blocking(move || {
            let mut options =
                security_framework::passwords::PasswordOptions::new_generic_password(
                    &service, &account,
                );
            options.set_access_synchronized(Some(false));
            options.set_label("OpenBurnBar Remote Device Key");
            security_framework::passwords::set_generic_password_options(&key, options)
        })
        .await
        .map_err(|err| AuthorizationError::SecureStorage(err.to_string()))?
        .map_err(map_keychain_error)
    }

    async fn delete_key(&self, name: &str) -> Result<(), AuthorizationError> {
        let service = self.service.clone();
        let account = self.account_for_name(name)?;
        tokio::task::spawn_blocking(move || {
            let mut options =
                security_framework::passwords::PasswordOptions::new_generic_password(
                    &service, &account,
                );
            options.set_access_synchronized(Some(false));
            security_framework::passwords::delete_generic_password_options(options)
        })
        .await
        .map_err(|err| AuthorizationError::SecureStorage(err.to_string()))?
        .or_else(|err| {
            if err.code() == ERR_SEC_ITEM_NOT_FOUND {
                Ok(())
            } else {
                Err(map_keychain_error(err))
            }
        })
    }
}

#[cfg(all(target_os = "macos", feature = "macos-keychain"))]
fn map_keychain_error(err: security_framework::Error) -> AuthorizationError {
    if err.code() == ERR_SEC_ITEM_NOT_FOUND {
        AuthorizationError::KeyUnavailable
    } else {
        AuthorizationError::SecureStorage(format!("keychain status {}", err.code()))
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerAuthorizationRequest {
    pub remote_endpoint_id: EndpointId,
    pub requested_device_id: DeviceId,
    pub requested_account_id: AccountId,
    pub requested_workspace_id: WorkspaceId,
    pub host_device_id: DeviceId,
    pub requested_mode: SessionMode,
    pub local_consent_granted: bool,
    pub now: TimestampMicros,
}

#[derive(Clone, Debug, PartialEq)]
pub struct ControlAuthorizationRequest {
    pub grant: SessionGrant,
    pub event: InputEvent,
    pub now: TimestampMicros,
}

#[async_trait]
pub trait SessionAuthorizer: Send + Sync {
    async fn authorize_peer(
        &self,
        request: PeerAuthorizationRequest,
    ) -> Result<SessionGrant, AuthorizationError>;

    async fn authorize_control(
        &self,
        request: ControlAuthorizationRequest,
    ) -> Result<(), AuthorizationError>;
}

#[derive(Default)]
pub struct LocalKillSwitch {
    active: AtomicBool,
}

impl LocalKillSwitch {
    pub fn activate(&self) {
        self.active.store(true, Ordering::SeqCst);
    }

    pub fn deactivate(&self) {
        self.active.store(false, Ordering::SeqCst);
    }

    pub fn is_active(&self) -> bool {
        self.active.load(Ordering::SeqCst)
    }

    pub fn ensure_allowed(&self) -> Result<(), AuthorizationError> {
        if self.is_active() {
            Err(AuthorizationError::KillSwitchActive)
        } else {
            Ok(())
        }
    }
}

pub struct ControlPolicyGate {
    replay: AntiReplayWindow,
    rate_limiter: RateLimiter,
    high_risk_policy: HighRiskPolicy,
    kill_switch: LocalKillSwitch,
}

impl ControlPolicyGate {
    pub fn new(rate_limiter: RateLimiter, high_risk_policy: HighRiskPolicy) -> Self {
        Self {
            replay: AntiReplayWindow::default(),
            rate_limiter,
            high_risk_policy,
            kill_switch: LocalKillSwitch::default(),
        }
    }

    pub fn kill_switch(&self) -> &LocalKillSwitch {
        &self.kill_switch
    }

    pub async fn authorize<A: SessionAuthorizer + ?Sized>(
        &mut self,
        authorizer: &A,
        request: ControlAuthorizationRequest,
        high_risk_confirmed: bool,
    ) -> Result<(), AuthorizationError> {
        self.kill_switch.ensure_allowed()?;
        if self
            .high_risk_policy
            .required_confirmation(&request.event)
            .is_some()
            && !high_risk_confirmed
        {
            return Err(AuthorizationError::HighRiskActionRequiresConfirmation);
        }
        let session_id = request.grant.descriptor.session_id.clone();
        let sequence = request.event.sequence().0;
        self.replay
            .check_and_advance(session_id.clone(), sequence)?;
        self.rate_limiter
            .check(&session_id, "control", request.now)?;
        authorizer.authorize_control(request).await
    }
}

#[derive(Default)]
pub struct InMemorySessionAuthorizer {
    devices_by_endpoint: RwLock<HashMap<EndpointId, AuthorizedDeviceRecord>>,
}

impl InMemorySessionAuthorizer {
    pub fn upsert_device(&self, record: AuthorizedDeviceRecord) -> Result<(), AuthorizationError> {
        self.devices_by_endpoint
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .insert(record.endpoint_id.clone(), record);
        Ok(())
    }

    pub fn revoke_endpoint(&self, endpoint_id: &EndpointId) -> Result<(), AuthorizationError> {
        let mut guard = self
            .devices_by_endpoint
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?;
        if let Some(record) = guard.get_mut(endpoint_id) {
            record.trust_state = DeviceTrustState::Revoked;
        }
        Ok(())
    }
}

#[async_trait]
impl SessionAuthorizer for InMemorySessionAuthorizer {
    async fn authorize_peer(
        &self,
        request: PeerAuthorizationRequest,
    ) -> Result<SessionGrant, AuthorizationError> {
        let record = self
            .devices_by_endpoint
            .read()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .get(&request.remote_endpoint_id)
            .cloned()
            .ok_or(AuthorizationError::UnknownPeer)?;

        if record.trust_state == DeviceTrustState::Revoked {
            return Err(AuthorizationError::RevokedDevice);
        }
        if record.account_id != request.requested_account_id
            || record.workspace_id != request.requested_workspace_id
            || record.device_id != request.requested_device_id
        {
            return Err(AuthorizationError::BindingMismatch);
        }
        if record.local_consent_required && !request.local_consent_granted {
            return Err(AuthorizationError::MissingLocalConsent);
        }
        if !record.allowed_modes.contains(&request.requested_mode) {
            return Err(AuthorizationError::PermissionDenied);
        }
        let required = request.requested_mode.required_permissions();
        if !record.permissions.is_superset(&required) {
            return Err(AuthorizationError::PermissionDenied);
        }

        let ttl = Duration::from_micros(record.max_session_ttl_micros.max(1));
        let descriptor = SessionDescriptor {
            session_id: SessionId::new(format!(
                "remote-{}-{}",
                record.device_id.as_str(),
                request.now.0
            )),
            account_id: record.account_id.clone(),
            workspace_id: record.workspace_id.clone(),
            host_device_id: request.host_device_id,
            client_device_id: record.device_id.clone(),
            mode: request.requested_mode,
            permissions: record.permissions.clone(),
            issued_at: request.now,
            expires_at: request.now.saturating_add_duration(ttl),
        };
        Ok(SessionGrant {
            grant_id: GrantId::new(format!("grant-{}", descriptor.session_id.as_str())),
            descriptor,
            signed_policy_hash: "unsigned-in-memory-policy".to_string(),
        })
    }

    async fn authorize_control(
        &self,
        request: ControlAuthorizationRequest,
    ) -> Result<(), AuthorizationError> {
        if request.now > request.grant.descriptor.expires_at {
            return Err(AuthorizationError::ExpiredGrant);
        }
        let required = request.event.required_permissions();
        if !request.grant.descriptor.permissions.is_superset(&required) {
            return Err(AuthorizationError::PermissionDenied);
        }
        Ok(())
    }
}

#[derive(Default)]
pub struct AntiReplayWindow {
    latest_sequence_by_session: HashMap<SessionId, u64>,
}

impl AntiReplayWindow {
    pub fn check_and_advance(
        &mut self,
        session_id: SessionId,
        sequence: u64,
    ) -> Result<(), AuthorizationError> {
        let latest = self
            .latest_sequence_by_session
            .entry(session_id.clone())
            .or_default();
        if sequence <= *latest {
            return Err(AuthorizationError::ReplayDetected { session_id });
        }
        *latest = sequence;
        Ok(())
    }
}

#[derive(Clone, Debug)]
struct RateBucket {
    window_started_at: TimestampMicros,
    count: u32,
}

#[derive(Clone, Debug)]
pub struct RateLimiter {
    max_events: u32,
    window: Duration,
    buckets: HashMap<String, RateBucket>,
}

impl RateLimiter {
    pub fn new(max_events: u32, window: Duration) -> Self {
        Self {
            max_events: max_events.max(1),
            window,
            buckets: HashMap::new(),
        }
    }

    pub fn check(
        &mut self,
        session_id: &SessionId,
        scope: &str,
        now: TimestampMicros,
    ) -> Result<(), AuthorizationError> {
        let key = format!("{}:{scope}", session_id.as_str());
        let bucket = self.buckets.entry(key.clone()).or_insert(RateBucket {
            window_started_at: now,
            count: 0,
        });
        if now.saturating_duration_since(bucket.window_started_at) > self.window {
            bucket.window_started_at = now;
            bucket.count = 0;
        }
        if bucket.count >= self.max_events {
            return Err(AuthorizationError::RateLimited { scope: key });
        }
        bucket.count += 1;
        Ok(())
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum HighRiskAction {
    ClipboardWrite,
    TextInjection,
    SystemControl,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct HighRiskPolicy {
    pub require_clipboard_confirmation: bool,
    pub require_text_confirmation_over_bytes: usize,
    pub require_system_confirmation: bool,
}

impl Default for HighRiskPolicy {
    fn default() -> Self {
        Self {
            require_clipboard_confirmation: true,
            require_text_confirmation_over_bytes: 256,
            require_system_confirmation: true,
        }
    }
}

impl HighRiskPolicy {
    pub fn required_confirmation(&self, event: &InputEvent) -> Option<HighRiskAction> {
        match event {
            InputEvent::Clipboard { .. } if self.require_clipboard_confirmation => {
                Some(HighRiskAction::ClipboardWrite)
            }
            InputEvent::Text { text, .. }
                if text.len() > self.require_text_confirmation_over_bytes =>
            {
                Some(HighRiskAction::TextInjection)
            }
            _ => None,
        }
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuditEventKind {
    PairingIssued,
    SessionAuthorized,
    ControlAuthorized,
    ControlDenied,
    DeviceRevoked,
    KillSwitchActivated,
    HighRiskConfirmationRequired,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditEvent {
    pub kind: AuditEventKind,
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub session_id: Option<SessionId>,
    pub device_id: Option<DeviceId>,
    pub endpoint_id: Option<EndpointId>,
    pub at: TimestampMicros,
    pub detail: String,
}

#[async_trait]
pub trait AuditSink: Send + Sync {
    async fn append(&self, event: AuditEvent) -> Result<(), AuthorizationError>;
}

#[derive(Default)]
pub struct InMemoryAuditSink {
    events: RwLock<Vec<AuditEvent>>,
}

impl InMemoryAuditSink {
    pub fn snapshot(&self) -> Result<Vec<AuditEvent>, AuthorizationError> {
        Ok(self
            .events
            .read()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .clone())
    }
}

#[async_trait]
impl AuditSink for InMemoryAuditSink {
    async fn append(&self, event: AuditEvent) -> Result<(), AuthorizationError> {
        self.events
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .push(event);
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditChainEntry {
    pub schema_version: u16,
    pub entry_index: u64,
    pub kind: AuditEventKind,
    pub account_id: AccountId,
    pub workspace_id: WorkspaceId,
    pub session_id: Option<SessionId>,
    pub device_id: Option<DeviceId>,
    pub endpoint_id: Option<EndpointId>,
    pub timestamp_micros: TimestampMicros,
    pub detail_hash_hex: String,
    pub parent_entry_hash_hex: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditChainHead {
    pub schema_version: u16,
    pub hash_algorithm: String,
    pub entry_count: u64,
    pub head_hash_hex: Option<String>,
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum AuditInvalidReason {
    DecodeFailure,
    UnsupportedSchema,
    UnexpectedEntryIndex,
    ParentHashMismatch,
    TruncatedFile,
    HeadHashMismatch,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct AuditValidationReport {
    pub entry_count: u64,
    pub is_valid: bool,
    pub first_invalid_entry_index: Option<u64>,
    pub first_invalid_reason: Option<AuditInvalidReason>,
    pub head_hash_hex: Option<String>,
}

#[derive(Clone, Debug)]
pub struct TamperEvidentAuditLog {
    path: PathBuf,
}

impl TamperEvidentAuditLog {
    pub fn new(path: impl Into<PathBuf>) -> Self {
        Self { path: path.into() }
    }

    pub fn path(&self) -> &Path {
        &self.path
    }

    pub fn validate(
        &self,
        expected_head_hash_hex: Option<&str>,
    ) -> Result<AuditValidationReport, AuthorizationError> {
        validate_audit_chain_file(&self.path, expected_head_hash_hex)
    }

    pub fn head(&self) -> Result<AuditChainHead, AuthorizationError> {
        let report = self.validate(None)?;
        Ok(AuditChainHead {
            schema_version: AUDIT_CHAIN_SCHEMA_VERSION,
            hash_algorithm: "sha256".to_string(),
            entry_count: report.entry_count,
            head_hash_hex: report.head_hash_hex,
        })
    }
}

#[async_trait]
impl AuditSink for TamperEvidentAuditLog {
    async fn append(&self, event: AuditEvent) -> Result<(), AuthorizationError> {
        append_audit_event(&self.path, event)
    }
}

fn append_audit_event(path: &Path, event: AuditEvent) -> Result<(), AuthorizationError> {
    if let Some(parent) = path.parent() {
        fs::create_dir_all(parent).map_err(|err| AuthorizationError::AuditChain(err.to_string()))?;
    }
    let report = validate_audit_chain_file(path, None)?;
    if !report.is_valid {
        return Err(AuthorizationError::AuditChain(format!(
            "refusing to append to invalid audit chain: {:?}",
            report.first_invalid_reason
        )));
    }
    let entry = AuditChainEntry {
        schema_version: AUDIT_CHAIN_SCHEMA_VERSION,
        entry_index: report.entry_count,
        kind: event.kind,
        account_id: event.account_id,
        workspace_id: event.workspace_id,
        session_id: event.session_id,
        device_id: event.device_id,
        endpoint_id: event.endpoint_id,
        timestamp_micros: event.at,
        detail_hash_hex: sha256_hex(event.detail.as_bytes()),
        parent_entry_hash_hex: report
            .head_hash_hex
            .unwrap_or_else(|| AUDIT_GENESIS_PARENT_HASH_HEX.to_string()),
    };
    let bytes = canonical_json_bytes(&entry)?;
    let mut file = OpenOptions::new()
        .create(true)
        .append(true)
        .open(path)
        .map_err(|err| AuthorizationError::AuditChain(err.to_string()))?;
    file.write_all(&bytes)
        .and_then(|_| file.write_all(b"\n"))
        .map_err(|err| AuthorizationError::AuditChain(err.to_string()))
}

fn validate_audit_chain_file(
    path: &Path,
    expected_head_hash_hex: Option<&str>,
) -> Result<AuditValidationReport, AuthorizationError> {
    let raw = match fs::read(path) {
        Ok(raw) => raw,
        Err(err) if err.kind() == std::io::ErrorKind::NotFound => {
            return Ok(AuditValidationReport {
                entry_count: 0,
                is_valid: expected_head_hash_hex.is_none(),
                first_invalid_entry_index: None,
                first_invalid_reason: expected_head_hash_hex
                    .map(|_| AuditInvalidReason::HeadHashMismatch),
                head_hash_hex: None,
            });
        }
        Err(err) => return Err(AuthorizationError::AuditChain(err.to_string())),
    };
    if raw.is_empty() {
        return Ok(AuditValidationReport {
            entry_count: 0,
            is_valid: expected_head_hash_hex.is_none(),
            first_invalid_entry_index: None,
            first_invalid_reason: expected_head_hash_hex.map(|_| AuditInvalidReason::HeadHashMismatch),
            head_hash_hex: None,
        });
    }
    if !raw.ends_with(b"\n") {
        return Ok(AuditValidationReport {
            entry_count: 0,
            is_valid: false,
            first_invalid_entry_index: None,
            first_invalid_reason: Some(AuditInvalidReason::TruncatedFile),
            head_hash_hex: None,
        });
    }
    let text = std::str::from_utf8(&raw).map_err(|err| AuthorizationError::AuditChain(err.to_string()))?;
    let mut expected_index = 0u64;
    let mut parent_hash = AUDIT_GENESIS_PARENT_HASH_HEX.to_string();
    let mut head_hash = None;
    for line in text.lines().filter(|line| !line.is_empty()) {
        let entry: AuditChainEntry = match serde_json::from_str(line) {
            Ok(entry) => entry,
            Err(_) => {
                return Ok(invalid_audit_report(
                    expected_index,
                    AuditInvalidReason::DecodeFailure,
                    head_hash,
                ));
            }
        };
        if entry.schema_version != AUDIT_CHAIN_SCHEMA_VERSION {
            return Ok(invalid_audit_report(
                expected_index,
                AuditInvalidReason::UnsupportedSchema,
                head_hash,
            ));
        }
        if entry.entry_index != expected_index {
            return Ok(invalid_audit_report(
                expected_index,
                AuditInvalidReason::UnexpectedEntryIndex,
                head_hash,
            ));
        }
        if entry.parent_entry_hash_hex != parent_hash {
            return Ok(invalid_audit_report(
                expected_index,
                AuditInvalidReason::ParentHashMismatch,
                head_hash,
            ));
        }
        let entry_hash = sha256_hex(&canonical_json_bytes(&entry)?);
        parent_hash = entry_hash.clone();
        head_hash = Some(entry_hash);
        expected_index = expected_index.saturating_add(1);
    }
    if let Some(expected) = expected_head_hash_hex {
        if head_hash.as_deref() != Some(expected) {
            return Ok(AuditValidationReport {
                entry_count: expected_index,
                is_valid: false,
                first_invalid_entry_index: expected_index.checked_sub(1),
                first_invalid_reason: Some(AuditInvalidReason::HeadHashMismatch),
                head_hash_hex: head_hash,
            });
        }
    }
    Ok(AuditValidationReport {
        entry_count: expected_index,
        is_valid: true,
        first_invalid_entry_index: None,
        first_invalid_reason: None,
        head_hash_hex: head_hash,
    })
}

fn invalid_audit_report(
    entry_index: u64,
    reason: AuditInvalidReason,
    head_hash_hex: Option<String>,
) -> AuditValidationReport {
    AuditValidationReport {
        entry_count: entry_index,
        is_valid: false,
        first_invalid_entry_index: Some(entry_index),
        first_invalid_reason: Some(reason),
        head_hash_hex,
    }
}

fn canonical_json_bytes<T: Serialize>(value: &T) -> Result<Vec<u8>, AuthorizationError> {
    let value =
        serde_json::to_value(value).map_err(|err| AuthorizationError::AuditChain(err.to_string()))?;
    serde_json::to_vec(&value).map_err(|err| AuthorizationError::AuditChain(err.to_string()))
}

fn sha256_hex(bytes: &[u8]) -> String {
    let digest = Sha256::digest(bytes);
    let mut out = String::with_capacity(digest.len() * 2);
    for byte in digest {
        use std::fmt::Write as _;
        let _ = write!(&mut out, "{byte:02x}");
    }
    out
}

#[cfg(test)]
mod tests {
    use super::*;
    use burnbar_remote_core::Permission;

    fn record() -> AuthorizedDeviceRecord {
        AuthorizedDeviceRecord {
            device_id: DeviceId::new("client"),
            endpoint_id: EndpointId::new("endpoint"),
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            trust_state: DeviceTrustState::Trusted,
            allowed_modes: vec![SessionMode::ViewOnly, SessionMode::Control],
            permissions: PermissionSet::from_iter([
                Permission::ViewScreen,
                Permission::InjectInput,
            ]),
            local_consent_required: true,
            max_session_ttl_micros: 5_000_000,
        }
    }

    #[tokio::test]
    async fn consent_is_not_optional() {
        let auth = InMemorySessionAuthorizer::default();
        auth.upsert_device(record()).unwrap();
        let err = auth
            .authorize_peer(PeerAuthorizationRequest {
                remote_endpoint_id: EndpointId::new("endpoint"),
                requested_device_id: DeviceId::new("client"),
                requested_account_id: AccountId::new("account"),
                requested_workspace_id: WorkspaceId::new("workspace"),
                host_device_id: DeviceId::new("host"),
                requested_mode: SessionMode::Control,
                local_consent_granted: false,
                now: TimestampMicros(1),
            })
            .await
            .unwrap_err();
        assert_eq!(err, AuthorizationError::MissingLocalConsent);
    }

    #[test]
    fn replay_window_rejects_old_sequences() {
        let mut window = AntiReplayWindow::default();
        let session_id = SessionId::new("s");
        window.check_and_advance(session_id.clone(), 10).unwrap();
        assert!(matches!(
            window.check_and_advance(session_id, 10),
            Err(AuthorizationError::ReplayDetected { .. })
        ));
    }

    #[test]
    fn pairing_ticket_expires_before_authorization_record() {
        let ticket = PairingTicket {
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            device_id: DeviceId::new("client"),
            endpoint_id: EndpointId::new("endpoint"),
            nonce: "nonce".into(),
            issued_at: TimestampMicros(10),
            expires_at: TimestampMicros(20),
            allowed_modes: vec![SessionMode::ViewOnly],
            permissions: PermissionSet::from_iter([Permission::ViewScreen]),
        };
        let err = ticket
            .into_authorized_record(TimestampMicros(21), true, Duration::from_secs(60))
            .unwrap_err();
        assert_eq!(err, AuthorizationError::PairingExpired);
    }

    #[tokio::test]
    async fn secure_key_store_round_trips_and_deletes() {
        let store = InMemorySecureKeyStore::default();
        store.write_key("device", b"secret").await.unwrap();
        assert_eq!(store.read_key("device").await.unwrap().as_slice(), b"secret");
        store.delete_key("device").await.unwrap();
        assert_eq!(
            store.read_key("device").await.unwrap_err(),
            AuthorizationError::KeyUnavailable
        );
    }

    #[test]
    fn rate_limiter_enforces_window() {
        let mut limiter = RateLimiter::new(2, Duration::from_millis(10));
        let session = SessionId::new("s");
        limiter
            .check(&session, "input", TimestampMicros(1))
            .unwrap();
        limiter
            .check(&session, "input", TimestampMicros(2))
            .unwrap();
        assert!(matches!(
            limiter.check(&session, "input", TimestampMicros(3)),
            Err(AuthorizationError::RateLimited { .. })
        ));
        limiter
            .check(&session, "input", TimestampMicros(20_000))
            .unwrap();
    }

    #[test]
    fn high_risk_policy_requires_confirmation_for_clipboard() {
        let policy = HighRiskPolicy::default();
        let event = InputEvent::Clipboard {
            mime_type: "text/plain".into(),
            byte_len: 32,
            sequence: burnbar_remote_core::SequenceNumber(1),
        };
        assert_eq!(
            policy.required_confirmation(&event),
            Some(HighRiskAction::ClipboardWrite)
        );
    }

    #[tokio::test]
    async fn audit_sink_appends_events() {
        let sink = InMemoryAuditSink::default();
        sink.append(AuditEvent {
            kind: AuditEventKind::SessionAuthorized,
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            session_id: Some(SessionId::new("session")),
            device_id: Some(DeviceId::new("device")),
            endpoint_id: Some(EndpointId::new("endpoint")),
            at: TimestampMicros(1),
            detail: "ok".into(),
        })
        .await
        .unwrap();
        assert_eq!(sink.snapshot().unwrap().len(), 1);
    }

    #[tokio::test]
    async fn control_policy_gate_blocks_clipboard_without_confirmation() {
        let auth = InMemorySessionAuthorizer::default();
        auth.upsert_device(record()).unwrap();
        let grant = auth
            .authorize_peer(PeerAuthorizationRequest {
                remote_endpoint_id: EndpointId::new("endpoint"),
                requested_device_id: DeviceId::new("client"),
                requested_account_id: AccountId::new("account"),
                requested_workspace_id: WorkspaceId::new("workspace"),
                host_device_id: DeviceId::new("host"),
                requested_mode: SessionMode::Control,
                local_consent_granted: true,
                now: TimestampMicros(1),
            })
            .await
            .unwrap();
        let mut gate = ControlPolicyGate::new(
            RateLimiter::new(10, Duration::from_secs(1)),
            HighRiskPolicy::default(),
        );
        let err = gate
            .authorize(
                &auth,
                ControlAuthorizationRequest {
                    grant,
                    event: InputEvent::Clipboard {
                        mime_type: "text/plain".into(),
                        byte_len: 10,
                        sequence: burnbar_remote_core::SequenceNumber(1),
                    },
                    now: TimestampMicros(2),
                },
                false,
            )
            .await
            .unwrap_err();
        assert_eq!(err, AuthorizationError::HighRiskActionRequiresConfirmation);
    }

    #[tokio::test]
    async fn kill_switch_blocks_control_gate() {
        let auth = InMemorySessionAuthorizer::default();
        auth.upsert_device(record()).unwrap();
        let grant = auth
            .authorize_peer(PeerAuthorizationRequest {
                remote_endpoint_id: EndpointId::new("endpoint"),
                requested_device_id: DeviceId::new("client"),
                requested_account_id: AccountId::new("account"),
                requested_workspace_id: WorkspaceId::new("workspace"),
                host_device_id: DeviceId::new("host"),
                requested_mode: SessionMode::Control,
                local_consent_granted: true,
                now: TimestampMicros(1),
            })
            .await
            .unwrap();
        let mut gate = ControlPolicyGate::new(
            RateLimiter::new(10, Duration::from_secs(1)),
            HighRiskPolicy::default(),
        );
        gate.kill_switch().activate();
        let err = gate
            .authorize(
                &auth,
                ControlAuthorizationRequest {
                    grant,
                    event: InputEvent::RelativeMouse {
                        dx: 1.0,
                        dy: 1.0,
                        sequence: burnbar_remote_core::SequenceNumber(1),
                    },
                    now: TimestampMicros(2),
                },
                true,
            )
            .await
            .unwrap_err();
        assert_eq!(err, AuthorizationError::KillSwitchActive);
    }

    #[test]
    fn signed_session_grant_payload_is_domain_separated() {
        let descriptor = SessionDescriptor {
            session_id: SessionId::new("session"),
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            host_device_id: DeviceId::new("host"),
            client_device_id: DeviceId::new("client"),
            mode: SessionMode::ViewOnly,
            permissions: PermissionSet::from_iter([Permission::ViewScreen]),
            issued_at: TimestampMicros(1),
            expires_at: TimestampMicros(2),
        };
        let grant = SessionGrant {
            grant_id: GrantId::new("grant"),
            descriptor,
            signed_policy_hash: "policy".into(),
        };
        let payload = grant_signing_payload(&grant).unwrap();
        assert!(payload.starts_with(SESSION_GRANT_SIGNING_CONTEXT));
        assert_eq!(payload[SESSION_GRANT_SIGNING_CONTEXT.len()], 0);
    }

    #[test]
    fn signed_session_grant_verifies_and_rejects_tamper() {
        let descriptor = SessionDescriptor {
            session_id: SessionId::new("session"),
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            host_device_id: DeviceId::new("host"),
            client_device_id: DeviceId::new("client"),
            mode: SessionMode::ViewOnly,
            permissions: PermissionSet::from_iter([Permission::ViewScreen]),
            issued_at: TimestampMicros(1),
            expires_at: TimestampMicros(2),
        };
        let grant = SessionGrant {
            grant_id: GrantId::new("grant"),
            descriptor,
            signed_policy_hash: "policy".into(),
        };
        let signed = SignedSessionGrant::sign(grant, "test-key", [7u8; 32]).unwrap();
        signed.verify_untrusted_signature_only().unwrap();

        let mut tampered = signed.clone();
        tampered.grant.signed_policy_hash = "other-policy".into();
        assert_eq!(
            tampered.verify_untrusted_signature_only().unwrap_err(),
            AuthorizationError::SignatureVerificationFailed
        );
    }

    #[test]
    fn trusted_signer_store_rejects_self_signed_grant() {
        let descriptor = SessionDescriptor {
            session_id: SessionId::new("session"),
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            host_device_id: DeviceId::new("host"),
            client_device_id: DeviceId::new("client"),
            mode: SessionMode::ViewOnly,
            permissions: PermissionSet::from_iter([Permission::ViewScreen]),
            issued_at: TimestampMicros(1),
            expires_at: TimestampMicros(2),
        };
        let grant = SessionGrant {
            grant_id: GrantId::new("grant"),
            descriptor,
            signed_policy_hash: "policy".into(),
        };
        let signed = SignedSessionGrant::sign(grant, "attacker", [9u8; 32]).unwrap();
        let store = InMemoryTrustedSignerStore::default();
        assert_eq!(
            store.verify_session_grant(&signed).unwrap_err(),
            AuthorizationError::UntrustedSigner
        );
    }

    #[test]
    fn trusted_signer_store_verifies_and_revokes_grant() {
        let signer = Ed25519SessionGrantSigner::new("host-signer", [7u8; 32]);
        let descriptor = SessionDescriptor {
            session_id: SessionId::new("session"),
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            host_device_id: DeviceId::new("host"),
            client_device_id: DeviceId::new("client"),
            mode: SessionMode::ViewOnly,
            permissions: PermissionSet::from_iter([Permission::ViewScreen]),
            issued_at: TimestampMicros(1),
            expires_at: TimestampMicros(2),
        };
        let grant = SessionGrant {
            grant_id: GrantId::new("grant"),
            descriptor,
            signed_policy_hash: "policy".into(),
        };
        let signed = signer.sign_session_grant(grant).unwrap();
        let store = InMemoryTrustedSignerStore::default();
        store
            .upsert_signer(TrustedSignerRecord {
                signer_key_id: signer.signer_key_id().to_string(),
                public_key: signer.public_key(),
                account_id: AccountId::new("account"),
                workspace_id: WorkspaceId::new("workspace"),
                revoked: false,
            })
            .unwrap();
        store.verify_session_grant(&signed).unwrap();
        store.revoke_signer("host-signer").unwrap();
        assert_eq!(
            store.verify_session_grant(&signed).unwrap_err(),
            AuthorizationError::RevokedSigner
        );
    }

    #[tokio::test]
    async fn secure_key_store_rejects_invalid_key_names() {
        let store = InMemorySecureKeyStore::default();
        assert_eq!(
            store.write_key("../secret", b"secret").await.unwrap_err(),
            AuthorizationError::InvalidKeyName
        );
    }

    #[tokio::test]
    async fn tamper_evident_audit_log_validates_and_hides_details() {
        let dir = tempfile::tempdir().unwrap();
        let path = dir.path().join("chain.jsonl");
        let sink = TamperEvidentAuditLog::new(&path);
        sink.append(AuditEvent {
            kind: AuditEventKind::ControlAuthorized,
            account_id: AccountId::new("account"),
            workspace_id: WorkspaceId::new("workspace"),
            session_id: Some(SessionId::new("session")),
            device_id: Some(DeviceId::new("device")),
            endpoint_id: Some(EndpointId::new("endpoint")),
            at: TimestampMicros(1),
            detail: "clipboard secret text".into(),
        })
        .await
        .unwrap();
        let report = sink.validate(None).unwrap();
        assert!(report.is_valid);
        assert_eq!(report.entry_count, 1);
        let raw = std::fs::read_to_string(&path).unwrap();
        assert!(!raw.contains("clipboard secret text"));

        let head = report.head_hash_hex.unwrap();
        std::fs::write(path, raw.replace("control_authorized", "control_denied")).unwrap();
        let report = sink.validate(Some(&head)).unwrap();
        assert!(!report.is_valid);
    }

    #[cfg(all(target_os = "macos", feature = "macos-keychain"))]
    #[tokio::test]
    async fn macos_keychain_store_round_trips_and_deletes() {
        let nanos = std::time::SystemTime::now()
            .duration_since(std::time::UNIX_EPOCH)
            .unwrap()
            .as_nanos();
        let store = MacOsKeychainSecureKeyStore::new(format!("test-{nanos}"));
        store.write_key("device", b"secret").await.unwrap();
        assert_eq!(store.read_key("device").await.unwrap().as_slice(), b"secret");
        store.delete_key("device").await.unwrap();
        assert_eq!(
            store.read_key("device").await.unwrap_err(),
            AuthorizationError::KeyUnavailable
        );
    }
}
