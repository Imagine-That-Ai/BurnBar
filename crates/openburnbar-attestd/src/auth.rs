use crate::error::BrokerError;

#[derive(Clone, Copy, Debug, Eq, PartialEq)]
pub struct PeerCredentials {
    pub pid: u32,
    pub uid: u32,
    pub gid: u32,
}

#[derive(Clone, Debug, Eq, PartialEq)]
pub struct AuthorizedPeer {
    pub credentials: PeerCredentials,
    pub executable_sha256: String,
}

pub trait PeerAuthorizer: Send + Sync {
    fn authorize(&self, peer: PeerCredentials) -> Result<AuthorizedPeer, BrokerError>;
}
