use std::time::Duration;

use crate::auth::{PeerAuthorizer, PeerCredentials};
use crate::backend::AttestationBackend;
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{Request, Response, MAX_FRAME_BYTES};
use crate::rate_limit::RequestRateLimiter;

pub const DEFAULT_IO_DEADLINE: Duration = Duration::from_secs(5);
pub const FRAME_PREFIX_BYTES: usize = 4;
pub const MAX_PACKET_BYTES: usize = FRAME_PREFIX_BYTES + MAX_FRAME_BYTES;

pub struct Broker<A, B, R> {
    authorizer: A,
    backend: B,
    rate_limiter: R,
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

    pub fn process_packet(&self, packet: &[u8], peer: PeerCredentials) -> Response {
        match self.process_packet_inner(packet, peer) {
            Ok(response) => response,
            Err(error) => Response::failure(String::new(), &error),
        }
    }

    fn process_packet_inner(
        &self,
        packet: &[u8],
        peer: PeerCredentials,
    ) -> Result<Response, BrokerError> {
        self.rate_limiter.check(peer.uid)?;
        let authorized_peer = self.authorizer.authorize(peer)?;
        let bytes = decode_packet(packet)?;
        let request = Request::parse(bytes)?;
        let request_id = request.request_id.clone();
        match self.backend.attest(&request, &authorized_peer) {
            Ok(attestation) => Ok(Response::success(request_id, attestation)),
            Err(error) => Ok(Response::failure(request_id, &error)),
        }
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

const fn invalid_frame() -> BrokerError {
    BrokerError::new(ErrorCode::InvalidFrame, "broker frame is invalid", false)
}

#[cfg(test)]
mod tests {
    use super::*;

    use crate::auth::AuthorizedPeer;
    use crate::backend::UnsupportedAttestationBackend;
    use crate::protocol::PROTOCOL_VERSION;

    #[derive(Clone, Copy)]
    struct AllowAuthorizer;

    impl PeerAuthorizer for AllowAuthorizer {
        fn authorize(&self, peer: PeerCredentials) -> Result<AuthorizedPeer, BrokerError> {
            Ok(AuthorizedPeer {
                credentials: peer,
                executable_sha256: "a".repeat(64),
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

    fn valid_request() -> Result<Vec<u8>, serde_json::Error> {
        serde_json::to_vec(&serde_json::json!({
            "protocolVersion": 1,
            "requestId": "request-1",
            "operation": "attest",
            "challenge": {
                "challengeId": "challenge-1",
                "challenge": "base64url_challenge",
                "expiresAtMillis": 2_000_000_000_000_i64,
                "appId": "1:123:linux:abc",
                "policyId": "openburnbar-linux-tpm2-ima-v1",
                "protocolVersion": 1
            },
            "binding": {
                "appId": "1:123:linux:abc",
                "deviceId": "device-1",
                "appVersion": "1.0.0",
                "architecture": "x86_64",
                "releaseDigestSha256": "a".repeat(64),
                "policyId": "openburnbar-linux-tpm2-ima-v1",
                "attestationKind": "tpm2_ima_signed_verdict_v1"
            }
        }))
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
    fn valid_authorized_peer_gets_explicit_unsupported_response(
    ) -> Result<(), Box<dyn std::error::Error>> {
        let response = broker().process_packet(&framed(&valid_request()?), peer());
        assert_eq!(response.protocol_version, PROTOCOL_VERSION);
        assert_eq!(response.request_id, "request-1");
        assert!(!response.ok);
        assert_eq!(
            response.error.map(|error| error.code),
            Some("attestation_unsupported".to_owned())
        );
        Ok(())
    }

    #[test]
    fn malformed_json_gets_typed_failure() {
        let response = broker().process_packet(&framed(b"{not-json"), peer());
        assert_eq!(
            response.error.map(|error| error.code),
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
    fn invalid_protocol_and_binding_are_rejected() -> Result<(), Box<dyn std::error::Error>> {
        let mut value: serde_json::Value = serde_json::from_slice(&valid_request()?)?;
        value["protocolVersion"] = serde_json::json!(2);
        let protocol = broker().process_packet(&framed(&serde_json::to_vec(&value)?), peer());
        assert_eq!(
            protocol.error.map(|error| error.code),
            Some("unsupported_protocol".to_owned())
        );

        value["protocolVersion"] = serde_json::json!(1);
        value["binding"]["appId"] = serde_json::json!("other-app");
        let binding = broker().process_packet(&framed(&serde_json::to_vec(&value)?), peer());
        assert_eq!(
            binding.error.map(|error| error.code),
            Some("invalid_request".to_owned())
        );
        Ok(())
    }

    #[test]
    fn response_is_one_length_prefixed_packet() {
        let response = broker().process_packet(&framed(b"not-json"), peer());
        let packet = encode_response(&response);
        assert!(packet.is_ok());
        if let Ok(packet) = packet {
            assert!(decode_packet(&packet).is_ok());
        }
    }
}
