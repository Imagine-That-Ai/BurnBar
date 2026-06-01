pub use burnbar_remote_media::{
    GpuFrame, HardwareEncoder, InputInjector, Packetizer, ZeroCopyCapture,
};
pub use burnbar_remote_network::{AuthorizedConnection, IrohTransportManager};
pub use burnbar_remote_security::{SessionAuthorizer, SessionGrant};

pub struct HostEngine<C, E, P, I> {
    pub capture: C,
    pub encoder: E,
    pub packetizer: P,
    pub input: I,
}

impl<C, E, P, I> HostEngine<C, E, P, I>
where
    C: ZeroCopyCapture,
    E: HardwareEncoder,
    P: Packetizer,
    I: InputInjector,
{
    pub fn new(capture: C, encoder: E, packetizer: P, input: I) -> Self {
        Self {
            capture,
            encoder,
            packetizer,
            input,
        }
    }
}
