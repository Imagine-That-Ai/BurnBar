#[repr(C)]
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MediaCapabilities {
    pub backend_available: u8,
    pub vp9enc: u8,
    pub vp9dec: u8,
    pub av1enc: u8,
    pub av1dec: u8,
    pub opusenc: u8,
    pub opusdec: u8,
    pub pipewiresrc: u8,
}

/// Capabilities required by the desktop shell's Mercury screen-share viewer.
///
/// This is intentionally separate from `MediaCapabilities`: the daemon's C
/// ABI is consumed by Swift and must remain layout-compatible, while the
/// viewer also needs to know whether a native video sink is registered.
#[derive(Debug, Clone, Copy, Default, PartialEq, Eq)]
pub struct MediaViewerCapabilities {
    pub backend_available: bool,
    pub vp9_decoder_available: bool,
    pub video_sink_available: bool,
}

impl MediaViewerCapabilities {
    pub const fn available(self) -> bool {
        self.backend_available && self.vp9_decoder_available && self.video_sink_available
    }
}

#[cfg(feature = "gstreamer")]
pub fn probe() -> MediaCapabilities {
    if crate::gst_runtime::ensure().is_err() {
        return MediaCapabilities::default();
    }
    MediaCapabilities {
        backend_available: 1,
        vp9enc: has_factory("vp9enc"),
        vp9dec: has_factory("vp9dec"),
        av1enc: has_factory("av1enc"),
        av1dec: has_factory("av1dec"),
        opusenc: has_factory("opusenc"),
        opusdec: has_factory("opusdec"),
        pipewiresrc: has_factory("pipewiresrc"),
    }
}

/// Probe the complete shell-side viewer prerequisite set without creating a
/// pipeline or opening a window. A factory being present does not guarantee a
/// frame can be rendered, but it gives the shell a truthful, side-effect-free
/// status before it accepts a call or screen-share session.
#[cfg(feature = "gstreamer")]
pub fn viewer_probe() -> MediaViewerCapabilities {
    if crate::gst_runtime::ensure().is_err() {
        return MediaViewerCapabilities::default();
    }
    MediaViewerCapabilities {
        backend_available: true,
        vp9_decoder_available: has_factory("vp9dec") != 0,
        video_sink_available: has_factory("autovideosink") != 0,
    }
}

#[cfg(not(feature = "gstreamer"))]
pub fn viewer_probe() -> MediaViewerCapabilities {
    MediaViewerCapabilities::default()
}

#[cfg(feature = "gstreamer")]
fn has_factory(name: &str) -> u8 {
    gst::ElementFactory::find(name).is_some() as u8
}

#[cfg(not(feature = "gstreamer"))]
pub fn probe() -> MediaCapabilities {
    MediaCapabilities::default()
}

#[no_mangle]
pub extern "C" fn media_capability_probe() -> MediaCapabilities {
    probe()
}
