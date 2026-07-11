use std::os::fd::OwnedFd;
use std::time::Duration;

use crate::auth::{AuthorizedPeer, PeerAuthorizer, PeerCredentials};
use crate::backend::{AttestationBackend, AttestationResult};
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{
    qualifying_data_sha256, AttestRequest, Binding, Request, Response, MAX_FRAME_BYTES,
};
use crate::rate_limit::RequestRateLimiter;

pub const DEFAULT_IO_DEADLINE: Duration = Duration::from_secs(5);
pub const FRAME_PREFIX_BYTES: usize = 4;
pub const MAX_PACKET_BYTES: usize = FRAME_PREFIX_BYTES + MAX_FRAME_BYTES;

#[derive(Debug)]
pub struct BrokerReply {
    pub response: Response,
    pub evidence_bundle: Option<OwnedFd>,
}

pub struct Broker<A, B, R> {
    authorizer: A,
    backend: B,
    rate_limiter: R,
}

impl BrokerReply {
    pub fn failure(request_id: String, error: &BrokerError) -> Self {
        Self {
            response: Response::failure(request_id, error),
            evidence_bundle: None,
        }
    }

    pub fn validate(&self) -> Result<(), BrokerError> {
        match (
            self.response.ok,
            self.response.binding.as_ref(),
            self.response.attestation.as_ref(),
            self.response.error.as_ref(),
            self.evidence_bundle.as_ref(),
        ) {
            (true, Some(binding), None, None, None) => {
                binding.validate().map_err(|_| invalid_backend_response())
            }
            (true, None, Some(attestation), None, Some(fd)) => {
                attestation.validate()?;
                validate_evidence_fd(fd, &attestation.evidence_bundle)
            }
            (false, None, None, Some(_), None) => Ok(()),
            _ => Err(invalid_backend_response()),
        }
    }
}

impl<A, B, R> Broker<A, B, R>
where
    A: PeerAuthorizer,
    B: AttestationBackend,
    R: RequestRateLimiter,
{
    pub const fn new(authorizer: A, backend: B, rate_limiter: R) -> Self {
        Self {
            authorizer,
            backend,
            rate_limiter,
        }
    }

    pub fn process_packet(&self, packet: &[u8], peer: PeerCredentials) -> BrokerReply {
        match self.process_packet_inner(packet, peer) {
            Ok(reply) => reply,
            Err(error) => BrokerReply::failure(String::new(), &error),
        }
    }

    fn process_packet_inner(
        &self,
        packet: &[u8],
        peer: PeerCredentials,
    ) -> Result<BrokerReply, BrokerError> {
        self.rate_limiter.check(peer.uid)?;
        let authorized_peer = self.authorizer.authorize(peer)?;
        let bytes = decode_packet(packet)?;
        let request = Request::parse(bytes)?;
        let request_id = request.request_id().to_owned();
        let result = match request {
            Request::DescribeBinding(_) => self.describe(request_id.clone(), &authorized_peer),
            Request::Attest(request) => self.attest(request_id.clone(), &request, &authorized_peer),
        };
        match result {
            Ok(reply) => match reply.validate() {
                Ok(()) => Ok(reply),
                Err(error) => Ok(BrokerReply::failure(request_id, &error)),
            },
            Err(error) => Ok(BrokerReply::failure(request_id, &error)),
        }
    }

    fn describe(
        &self,
        request_id: String,
        peer: &AuthorizedPeer,
    ) -> Result<BrokerReply, BrokerError> {
        let binding = self.backend.describe(peer)?;
        validate_installed_release_binding(&binding, peer)?;
        Ok(BrokerReply {
            response: Response::binding_success(request_id, binding),
            evidence_bundle: None,
        })
    }

    fn attest(
        &self,
        request_id: String,
        request: &AttestRequest,
        peer: &AuthorizedPeer,
    ) -> Result<BrokerReply, BrokerError> {
        let current_binding = self.backend.describe(peer)?;
        validate_installed_release_binding(&current_binding, peer)?;
        if request.binding != current_binding {
            return Err(BrokerError::new(
                ErrorCode::InvalidRequest,
                "attestation binding does not match the installed release or enrolled device",
                false,
            ));
        }
        let AttestationResult {
            attestation,
            evidence_bundle,
        } = self.backend.attest(request, peer)?;
        if attestation.challenge_id != request.challenge.challenge_id
            || attestation.challenge != request.challenge.challenge
            || attestation.evidence.device_id != current_binding.device_id
            || attestation.evidence.qualifying_data_sha256
                != qualifying_data_sha256(&request.challenge.challenge, &current_binding)?
        {
            return Err(invalid_backend_response());
        }
        Ok(BrokerReply {
            response: Response::attestation_success(request_id, attestation),
            evidence_bundle: Some(evidence_bundle),
        })
    }
}

pub fn decode_packet(packet: &[u8]) -> Result<&[u8], BrokerError> {
    if packet.len() < FRAME_PREFIX_BYTES {
        return Err(BrokerError::new(
            ErrorCode::InvalidFrame,
            "broker frame ended before its length prefix",
            false,
        ));
    }
    let prefix: [u8; FRAME_PREFIX_BYTES] = packet[..FRAME_PREFIX_BYTES]
        .try_into()
        .map_err(|_| invalid_frame())?;
    let length = u32::from_be_bytes(prefix) as usize;
    if length == 0 {
        return Err(BrokerError::new(
            ErrorCode::InvalidFrame,
            "broker frame must not be empty",
            false,
        ));
    }
    if length > MAX_FRAME_BYTES {
        return Err(BrokerError::new(
            ErrorCode::RequestTooLarge,
            "broker request exceeds 64 KiB",
            false,
        ));
    }
    if packet.len() != FRAME_PREFIX_BYTES + length {
        return Err(BrokerError::new(
            ErrorCode::InvalidFrame,
            "broker packet does not match its declared frame length",
            false,
        ));
    }
    Ok(&packet[FRAME_PREFIX_BYTES..])
}

pub fn encode_response(response: &Response) -> Result<Vec<u8>, BrokerError> {
    let payload = serde_json::to_vec(response).map_err(|_| {
        BrokerError::new(
            ErrorCode::Internal,
            "broker response serialization failed",
            false,
        )
    })?;
    if payload.len() > MAX_FRAME_BYTES {
        return Err(BrokerError::new(
            ErrorCode::ResponseTooLarge,
            "broker response exceeds 64 KiB",
            false,
        ));
    }
    let length = u32::try_from(payload.len()).map_err(|_| {
        BrokerError::new(
            ErrorCode::ResponseTooLarge,
            "broker response exceeds 64 KiB",
            false,
        )
    })?;
    let mut packet = Vec::with_capacity(FRAME_PREFIX_BYTES + payload.len());
    packet.extend_from_slice(&length.to_be_bytes());
    packet.extend_from_slice(&payload);
    Ok(packet)
}

fn validate_installed_release_binding(
    binding: &Binding,
    peer: &AuthorizedPeer,
) -> Result<(), BrokerError> {
    binding.validate().map_err(|_| invalid_backend_response())?;
    let release = &peer.installed_release;
    if binding.app_id != release.firebase_app_id
        || binding.app_version != release.app_version
        || binding.architecture != release.architecture
        || binding.release_digest_sha256 != release.release_digest_sha256
        || binding.policy_id != release.policy_id
        || binding.attestation_kind != release.attestation_kind
    {
        return Err(invalid_backend_response());
    }
    Ok(())
}

#[cfg(target_os = "linux")]
fn validate_evidence_fd(
    fd: &OwnedFd,
    bundle: &crate::protocol::EvidenceBundle,
) -> Result<(), BrokerError> {
    crate::linux::validate_evidence_bundle_fd(fd, bundle)
}

#[cfg(not(target_os = "linux"))]
fn validate_evidence_fd(
    _fd: &OwnedFd,
    _bundle: &crate::protocol::EvidenceBundle,
) -> Result<(), BrokerError> {
    Err(BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 and IMA attestation is available only on Linux",
        false,
    ))
}

const fn invalid_frame() -> BrokerError {
    BrokerError::new(ErrorCode::InvalidFrame, "broker frame is invalid", false)
}

const fn invalid_backend_response() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationFailed,
        "attestation backend returned invalid evidence",
        false,
    )
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::auth::InstalledReleaseIdentity;
    use crate::backend::UnsupportedAttestationBackend;
    use crate::protocol::{ATTESTATION_KIND, PROTOCOL_VERSION};

    #[derive(Clone, Copy)]
    struct AllowAuthorizer;

    impl PeerAuthorizer for AllowAuthorizer {
        fn authorize(&self, peer: PeerCredentials) -> Result<AuthorizedPeer, BrokerError> {
            Ok(AuthorizedPeer {
                credentials: peer,
                executable_sha256: "a".repeat(64),
                installed_release: InstalledReleaseIdentity {
                    firebase_app_id: "1:123456789:web:abcdef0123456789".to_owned(),
                    app_version: "1.0.30".to_owned(),
                    architecture: "x86_64".to_owned(),
                    release_digest_sha256: "a".repeat(64),
                    policy_id: "openburnbar-linux-tpm2-ima-v1".to_owned(),
                    attestation_kind: ATTESTATION_KIND.to_owned(),
                },
            })
        }
    }

    #[derive(Clone, Copy)]
    struct AllowRate;

    impl RequestRateLimiter for AllowRate {
        fn check(&self, _uid: u32) -> Result<(), BrokerError> {
            Ok(())
        }
    }

    fn peer() -> PeerCredentials {
        PeerCredentials {
            pid: 42,
            uid: 1_000,
            gid: 1_000,
        }
    }

    fn golden_value(key: &str) -> Result<serde_json::Value, serde_json::Error> {
        let fixture: serde_json::Value = serde_json::from_str(include_str!(
            "../../../tests/fixtures/linux-attestation/broker-v2-golden.json"
        ))?;
        Ok(fixture.get(key).cloned().unwrap_or(serde_json::Value::Null))
    }

    fn framed(payload: &[u8]) -> Vec<u8> {
        let mut bytes = u32::try_from(payload.len())
            .unwrap_or_default()
            .to_be_bytes()
            .to_vec();
        bytes.extend_from_slice(payload);
        bytes
    }

    fn broker() -> Broker<AllowAuthorizer, UnsupportedAttestationBackend, AllowRate> {
        Broker::new(AllowAuthorizer, UnsupportedAttestationBackend, AllowRate)
    }

    #[test]
    fn both_operations_get_exact_typed_unsupported_response(
    ) -> Result<(), Box<dyn std::error::Error>> {
        for (key, request_id) in [
            ("describeBindingRequest", "describe-0001"),
            ("attestRequest", "attest-0001"),
        ] {
            let request = serde_json::to_vec(&golden_value(key)?)?;
            let reply = broker().process_packet(&framed(&request), peer());
            assert_eq!(reply.response.protocol_version, PROTOCOL_VERSION);
            assert_eq!(reply.response.request_id, request_id);
            assert!(!reply.response.ok);
            assert!(reply.evidence_bundle.is_none());
            if key == "describeBindingRequest" {
                assert_eq!(
                    serde_json::to_value(&reply.response)?,
                    golden_value("unsupportedResponse")?
                );
            }
            assert_eq!(
                reply.response.error.map(|error| error.code),
                Some("attestation_unsupported".to_owned())
            );
        }
        Ok(())
    }

    #[test]
    fn malformed_json_gets_typed_failure() {
        let reply = broker().process_packet(&framed(b"{not-json"), peer());
        assert_eq!(
            reply.response.error.map(|error| error.code),
            Some("malformed_request".to_owned())
        );
    }

    #[test]
    fn oversized_empty_partial_and_trailing_frames_are_rejected() {
        let oversized = (u32::try_from(MAX_FRAME_BYTES + 1).unwrap_or(u32::MAX)).to_be_bytes();
        assert_eq!(
            decode_packet(&oversized).err().map(|error| error.code()),
            Some(ErrorCode::RequestTooLarge)
        );
        for packet in [
            vec![0, 0, 0, 0],
            vec![0, 0, 0],
            vec![0, 0, 0, 4, b'a', b'b'],
            vec![0, 0, 0, 1, b'a', b'b'],
        ] {
            assert_eq!(
                decode_packet(&packet).err().map(|error| error.code()),
                Some(ErrorCode::InvalidFrame)
            );
        }
    }

    #[test]
    fn response_fd_cardinality_is_fail_closed() -> Result<(), serde_json::Error> {
        let response: Response = serde_json::from_value(golden_value("attestResponse")?)?;
        let reply = BrokerReply {
            response,
            evidence_bundle: None,
        };
        assert_eq!(
            reply.validate().err().map(|error| error.code()),
            Some(ErrorCode::AttestationFailed)
        );
        Ok(())
    }

    #[cfg(target_os = "linux")]
    struct SealedFixtureBackend {
        bundle: Vec<u8>,
        corrupt_qualifying_data: bool,
    }

    #[cfg(target_os = "linux")]
    impl AttestationBackend for SealedFixtureBackend {
        fn describe(&self, peer: &AuthorizedPeer) -> Result<Binding, BrokerError> {
            let release = &peer.installed_release;
            Ok(Binding {
                app_id: release.firebase_app_id.clone(),
                device_id:
                    "ak-sha256:0123456789abcdef0123456789abcdef0123456789abcdef0123456789abcdef"
                        .to_owned(),
                app_version: release.app_version.clone(),
                architecture: release.architecture.clone(),
                release_digest_sha256: release.release_digest_sha256.clone(),
                policy_id: release.policy_id.clone(),
                attestation_kind: release.attestation_kind.clone(),
            })
        }

        fn attest(
            &self,
            request: &AttestRequest,
            peer: &AuthorizedPeer,
        ) -> Result<AttestationResult, BrokerError> {
            use sha2::{Digest, Sha256};

            use crate::protocol::{
                Attestation, EvidenceBundle, QuoteEvidence, EVIDENCE_BUNDLE_FORMAT,
            };

            let binding = self.describe(peer)?;
            let digest = format!("{:x}", Sha256::digest(&self.bundle));
            let mut qualifying_data_sha256 =
                qualifying_data_sha256(&request.challenge.challenge, &binding)?;
            if self.corrupt_qualifying_data {
                qualifying_data_sha256 = "0".repeat(64);
            }
            Ok(AttestationResult {
                attestation: Attestation {
                    challenge_id: request.challenge.challenge_id.clone(),
                    challenge: request.challenge.challenge.clone(),
                    kind: ATTESTATION_KIND.to_owned(),
                    evidence: QuoteEvidence {
                        schema_version: 1,
                        device_id: binding.device_id,
                        quote_attestation_base64: "cXVvdGUtYXR0ZXN0YXRpb24=".to_owned(),
                        quote_signature_base64: "cXVvdGUtc2lnbmF0dXJl".to_owned(),
                        quote_pcr_values_base64: "cXVvdGUtcGNyLXZhbHVlcw==".to_owned(),
                        pcr_bank: "sha256".to_owned(),
                        pcr_selection: [0, 2, 4, 7, 10],
                        qualifying_data_sha256,
                    },
                    evidence_bundle: EvidenceBundle {
                        descriptor_index: 0,
                        format: EVIDENCE_BUNDLE_FORMAT.to_owned(),
                        byte_length: self.bundle.len() as u64,
                        sha256: digest,
                    },
                },
                evidence_bundle: crate::linux::create_sealed_memfd(&self.bundle)?,
            })
        }
    }

    #[cfg(target_os = "linux")]
    fn fixture_evidence_bundle() -> Result<Vec<u8>, serde_json::Error> {
        use sha2::{Digest, Sha256};

        let records = [
            ("ima_ascii_runtime_measurements", b"ima".as_slice()),
            ("uefi_binary_bios_measurements", b"uefi".as_slice()),
            ("installed_manifest", b"manifest".as_slice()),
            ("installed_manifest_signature", b"signature".as_slice()),
        ];
        let mut header_length = 0_usize;
        for _ in 0..16 {
            let mut offset = 12_usize.saturating_add(header_length);
            let mut header_records = Vec::with_capacity(records.len());
            for (kind, bytes) in records {
                header_records.push(serde_json::json!({
                    "kind": kind,
                    "offset": offset,
                    "byteLength": bytes.len(),
                    "sha256": format!("{:x}", Sha256::digest(bytes))
                }));
                offset = offset.saturating_add(bytes.len());
            }
            let header = serde_json::to_vec(&serde_json::json!({
                "schemaVersion": 1,
                "records": header_records
            }))?;
            if header.len() == header_length {
                let mut bundle = b"OBBATST1".to_vec();
                bundle.extend_from_slice(&(header.len() as u32).to_be_bytes());
                bundle.extend_from_slice(&header);
                for (_, bytes) in records {
                    bundle.extend_from_slice(bytes);
                }
                return Ok(bundle);
            }
            header_length = header.len();
        }
        Ok(Vec::new())
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn sealed_fixture_backend_plumbs_one_validated_descriptor(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let request = serde_json::to_vec(&golden_value("attestRequest")?)?;
        let bundle = fixture_evidence_bundle()?;
        assert!(!bundle.is_empty());
        let broker = Broker::new(
            AllowAuthorizer,
            SealedFixtureBackend {
                bundle: bundle.clone(),
                corrupt_qualifying_data: false,
            },
            AllowRate,
        );
        let reply = broker.process_packet(&framed(&request), peer());
        assert!(reply.response.ok);
        assert!(reply.response.error.is_none());
        assert_eq!(
            reply
                .response
                .attestation
                .as_ref()
                .map(|attestation| attestation.evidence_bundle.byte_length),
            Some(bundle.len() as u64)
        );
        assert!(reply.evidence_bundle.is_some());
        assert!(reply.validate().is_ok());
        Ok(())
    }

    #[cfg(target_os = "linux")]
    #[test]
    fn broker_rejects_backend_quote_with_wrong_qualifying_data(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let request = serde_json::to_vec(&golden_value("attestRequest")?)?;
        let broker = Broker::new(
            AllowAuthorizer,
            SealedFixtureBackend {
                bundle: fixture_evidence_bundle()?,
                corrupt_qualifying_data: true,
            },
            AllowRate,
        );
        let reply = broker.process_packet(&framed(&request), peer());
        assert!(!reply.response.ok);
        assert!(reply.evidence_bundle.is_none());
        assert_eq!(
            reply.response.error.map(|error| error.code),
            Some("attestation_failed".to_owned())
        );
        Ok(())
    }
}
