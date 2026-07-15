pub mod capability;
pub mod capture;
pub mod decode;

pub use capability::{
    media_capability_probe, probe, viewer_probe, MediaCapabilities, MediaViewerCapabilities,
};
pub use capture::{
    media_audio_capture_start, media_capture_set_bitrate, media_capture_start, media_capture_stop,
    CaptureCodec, CaptureFrameCallback, CapturePipeline,
};
pub use decode::{DecodePipeline, DecodeSinkMode};

pub const MEDIA_FRAME_FLAG_KEYFRAME: u8 = 1 << 0;

#[derive(Debug, Clone, PartialEq, Eq)]
pub enum MediaError {
    Unavailable { detail: String },
    InvalidArgument { detail: String },
    Pipeline { detail: String },
    StateChange { detail: String },
    Bus { detail: String },
}

impl MediaError {
    pub fn unavailable(detail: impl Into<String>) -> Self {
        Self::Unavailable {
            detail: detail.into(),
        }
    }

    pub fn invalid_argument(detail: impl Into<String>) -> Self {
        Self::InvalidArgument {
            detail: detail.into(),
        }
    }

    pub fn pipeline(detail: impl Into<String>) -> Self {
        Self::Pipeline {
            detail: detail.into(),
        }
    }

    pub fn state_change(detail: impl Into<String>) -> Self {
        Self::StateChange {
            detail: detail.into(),
        }
    }

    pub fn bus(detail: impl Into<String>) -> Self {
        Self::Bus {
            detail: detail.into(),
        }
    }
}

impl std::fmt::Display for MediaError {
    fn fmt(&self, formatter: &mut std::fmt::Formatter<'_>) -> std::fmt::Result {
        match self {
            Self::Unavailable { detail } => write!(formatter, "media unavailable: {detail}"),
            Self::InvalidArgument { detail } => {
                write!(formatter, "invalid media argument: {detail}")
            }
            Self::Pipeline { detail } => write!(formatter, "media pipeline failed: {detail}"),
            Self::StateChange { detail } => {
                write!(formatter, "media state change failed: {detail}")
            }
            Self::Bus { detail } => write!(formatter, "media bus error: {detail}"),
        }
    }
}

impl std::error::Error for MediaError {}

pub type Result<T> = std::result::Result<T, MediaError>;

#[cfg(feature = "gstreamer")]
pub(crate) mod gst_runtime {
    use std::sync::OnceLock;
    use std::thread;

    use gst::prelude::GstObjectExt;

    use crate::{MediaError, Result};

    static GLIB_LOOP: OnceLock<glib::MainLoop> = OnceLock::new();

    pub(crate) fn ensure() -> Result<()> {
        gst::init().map_err(|error| MediaError::pipeline(error.to_string()))?;
        GLIB_LOOP.get_or_init(|| {
            let context = glib::MainContext::new();
            let main_loop = glib::MainLoop::new(Some(&context), false);
            let thread_loop = main_loop.clone();
            thread::Builder::new()
                .name("openburnbar-media-glib".to_string())
                .spawn(move || {
                    context
                        .with_thread_default(|| {
                            thread_loop.run();
                        })
                        .ok();
                })
                .ok();
            main_loop
        });
        Ok(())
    }

    pub(crate) fn bus_error_detail(message: &gst::Message) -> Option<String> {
        match message.view() {
            gst::MessageView::Error(error) => Some(format!(
                "{}: {} ({:?})",
                error
                    .src()
                    .map(|source| source.path_string())
                    .unwrap_or_else(|| "unknown".into()),
                error.error(),
                error.debug()
            )),
            _ => None,
        }
    }
}
