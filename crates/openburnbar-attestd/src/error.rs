use std::fmt;
use std::io;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub enum ErrorCode {
    InvalidFrame,
    RequestTooLarge,
    ResponseTooLarge,
    MalformedRequest,
    UnsupportedProtocol,
    InvalidRequest,
    UnauthorizedPeer,
    ManifestSignatureInvalid,
    RateLimited,
    AttestationUnsupported,
    AttestationFailed,
    Internal,
}

impl ErrorCode {
    pub const fn as_str(self) -> &'static str {
        match self {
            Self::InvalidFrame => "invalid_frame",
            Self::RequestTooLarge => "request_too_large",
            Self::ResponseTooLarge => "response_too_large",
            Self::MalformedRequest => "malformed_request",
            Self::UnsupportedProtocol => "unsupported_protocol",
            Self::InvalidRequest => "invalid_request",
            Self::UnauthorizedPeer => "unauthorized_peer",
            Self::ManifestSignatureInvalid => "manifest_signature_invalid",
            Self::RateLimited => "rate_limited",
            Self::AttestationUnsupported => "attestation_unsupported",
            Self::AttestationFailed => "attestation_failed",
            Self::Internal => "internal",
        }
    }
}

#[derive(Debug)]
pub struct BrokerError {
    code: ErrorCode,
    message: &'static str,
    retryable: bool,
    source: Option<io::Error>,
}

impl BrokerError {
    pub const fn new(code: ErrorCode, message: &'static str, retryable: bool) -> Self {
        Self {
            code,
            message,
            retryable,
            source: None,
        }
    }

    pub fn io(code: ErrorCode, message: &'static str, source: io::Error) -> Self {
        Self {
            code,
            message,
            retryable: false,
            source: Some(source),
        }
    }

    pub const fn code(&self) -> ErrorCode {
        self.code
    }

    pub const fn public_message(&self) -> &'static str {
        self.message
    }

    pub const fn retryable(&self) -> bool {
        self.retryable
    }
}

impl fmt::Display for BrokerError {
    fn fmt(&self, formatter: &mut fmt::Formatter<'_>) -> fmt::Result {
        write!(formatter, "{}: {}", self.code.as_str(), self.message)
    }
}

impl std::error::Error for BrokerError {
    fn source(&self) -> Option<&(dyn std::error::Error + 'static)> {
        self.source
            .as_ref()
            .map(|source| source as &(dyn std::error::Error + 'static))
    }
}
