#[test]
#[cfg(feature = "gstreamer")]
fn probe_finds_required_media_factories() {
    let capabilities = openburnbar_media::probe();
    assert_eq!(capabilities.vp9enc, 1, "vp9enc must be installed");
    assert_eq!(capabilities.vp9dec, 1, "vp9dec must be installed");
    assert_eq!(capabilities.opusenc, 1, "opusenc must be installed");
    assert_eq!(capabilities.opusdec, 1, "opusdec must be installed");
    assert_eq!(capabilities.pipewiresrc, 1, "pipewiresrc must be installed");
}

#[test]
#[cfg(feature = "gstreamer")]
fn viewer_probe_requires_decoder_and_native_video_sink() {
    let capabilities = openburnbar_media::viewer_probe();
    assert!(capabilities.backend_available);
    assert!(
        capabilities.vp9_decoder_available,
        "vp9dec must be installed"
    );
    assert!(
        capabilities.video_sink_available,
        "autovideosink must be installed for the shell viewer"
    );
    assert!(capabilities.available());
}

#[test]
#[cfg(not(feature = "gstreamer"))]
fn probe_is_empty_without_gstreamer_feature() {
    let capabilities = openburnbar_media::probe();
    assert_eq!(
        capabilities,
        openburnbar_media::MediaCapabilities::default()
    );
}

#[test]
#[cfg(not(feature = "gstreamer"))]
fn viewer_probe_is_fail_closed_without_gstreamer_feature() {
    let capabilities = openburnbar_media::viewer_probe();
    assert_eq!(
        capabilities,
        openburnbar_media::MediaViewerCapabilities::default()
    );
    assert!(!capabilities.available());
}
