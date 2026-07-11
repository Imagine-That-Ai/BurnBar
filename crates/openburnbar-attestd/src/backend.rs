use std::os::fd::OwnedFd;

use crate::auth::AuthorizedPeer;
use crate::error::{BrokerError, ErrorCode};
use crate::protocol::{AttestRequest, Attestation, Binding};

#[derive(Debug)]
pub struct AttestationResult {
    pub attestation: Attestation,
    pub evidence_bundle: OwnedFd,
}

pub trait AttestationBackend: Send + Sync {
    fn describe(&self, peer: &AuthorizedPeer) -> Result<Binding, BrokerError>;

    fn attest(
        &self,
        request: &AttestRequest,
        peer: &AuthorizedPeer,
    ) -> Result<AttestationResult, BrokerError>;
}

#[derive(Clone, Copy, Debug, Default)]
pub struct UnsupportedAttestationBackend;

impl AttestationBackend for UnsupportedAttestationBackend {
    fn describe(&self, _peer: &AuthorizedPeer) -> Result<Binding, BrokerError> {
        Err(unsupported())
    }

    fn attest(
        &self,
        _request: &AttestRequest,
        _peer: &AuthorizedPeer,
    ) -> Result<AttestationResult, BrokerError> {
        Err(unsupported())
    }
}

const fn unsupported() -> BrokerError {
    BrokerError::new(
        ErrorCode::AttestationUnsupported,
        "TPM2 and IMA attestation is not configured on this broker",
        false,
    )
}
