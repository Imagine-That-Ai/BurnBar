pub use burnbar_remote_media::{HardwareDecoder, Renderer, UpscaleMode, Upscaler};
pub use burnbar_remote_network::{AuthorizedConnection, IrohTransportManager, ReliableChannel};

pub struct ClientEngine<D, R, U> {
    pub decoder: D,
    pub renderer: R,
    pub upscaler: Option<U>,
}

impl<D, R, U> ClientEngine<D, R, U>
where
    D: HardwareDecoder,
    R: Renderer,
    U: Upscaler,
{
    pub fn new(decoder: D, renderer: R, upscaler: Option<U>) -> Self {
        Self {
            decoder,
            renderer,
            upscaler,
        }
    }
}
