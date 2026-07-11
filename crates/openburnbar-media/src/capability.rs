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
