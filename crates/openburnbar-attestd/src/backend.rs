use crate::auth::AuthorizedPeer;
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{Attestation, Request};

pub trait AttestationBackend: Send + Sync {
    fn attest(&self, request: &Request, peer: &AuthorizedPeer) -> Result<Attestation, BrokerError>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct UnsupportedAttestationBackend;

impl AttestationBackend for UnsupportedAttestationBackend {
    fn attest(
        &self,
        _request: &Request,
        _peer: &AuthorizedPeer,
    ) -> Result<Attestation, BrokerError> {
        Err(BrokerError::new(
            ErrorCode::AttestationUnsupported,
            "TPM2 and IMA attestation is not configured on this broker",
            false,
        ))
    }
}
