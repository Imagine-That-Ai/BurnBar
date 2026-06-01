use std::collections::HashMap;
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
use thiserror::Error;

const SESSION_GRANT_SIGNING_CONTEXT: &[u8] = b"openburnbar.remote.session-grant.v1";

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
    #[error("rate limit exceeded for {scope}")]
    RateLimited { scope: String },
    #[error("high-risk action requires explicit confirmation")]
    HighRiskActionRequiresConfirmation,
    #[error("local kill switch is active")]
    KillSwitchActive,
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

    pub fn verify(&self) -> Result<(), AuthorizationError> {
        let public_key: [u8; 32] = self
            .public_key
            .as_slice()
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
    async fn read_key(&self, name: &str) -> Result<Vec<u8>, AuthorizationError>;
    async fn write_key(&self, name: &str, key: &[u8]) -> Result<(), AuthorizationError>;
    async fn delete_key(&self, name: &str) -> Result<(), AuthorizationError>;
}

#[derive(Default)]
pub struct InMemorySecureKeyStore {
    keys: RwLock<HashMap<String, Vec<u8>>>,
}

#[async_trait]
impl SecureKeyStore for InMemorySecureKeyStore {
    async fn read_key(&self, name: &str) -> Result<Vec<u8>, AuthorizationError> {
        self.keys
            .read()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .get(name)
            .cloned()
            .ok_or(AuthorizationError::KeyUnavailable)
    }

    async fn write_key(&self, name: &str, key: &[u8]) -> Result<(), AuthorizationError> {
        self.keys
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .insert(name.to_string(), key.to_vec());
        Ok(())
    }

    async fn delete_key(&self, name: &str) -> Result<(), AuthorizationError> {
        self.keys
            .write()
            .map_err(|_| AuthorizationError::StorePoisoned)?
            .remove(name);
        Ok(())
    }
}

#[derive(Clone, Debug, PartialEq, Eq)]
pub struct PeerAuthorizationRequest {
    pub remote_endpoint_id: EndpointId,
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
        assert_eq!(store.read_key("device").await.unwrap(), b"secret");
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
        signed.verify().unwrap();

        let mut tampered = signed.clone();
        tampered.grant.signed_policy_hash = "other-policy".into();
        assert_eq!(
            tampered.verify().unwrap_err(),
            AuthorizationError::SignatureVerificationFailed
        );
    }
}
