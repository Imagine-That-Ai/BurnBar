#![cfg(feature = "gstreamer")]

use openburnbar_media::{DecodePipeline, DecodeSinkMode, MediaError, MEDIA_FRAME_FLAG_KEYFRAME};

#[test]
fn decodes_vp9_appsrc_into_fake_sink() {
    let frames = harvest_vp9_frames(30);
    assert!(
        frames.len() >= 30,
        "expected at least 30 encoded VP9 frames"
    );

    let pipeline = DecodePipeline::new("vp9", DecodeSinkMode::Fake).expect("decode pipeline");
    for (index, payload) in frames.iter().enumerate() {
        let flags = if index == 0 {
            MEDIA_FRAME_FLAG_KEYFRAME
        } else {
            0
        };
        pipeline
            .push_frame(payload, (index as u64) * 33, flags)
            .expect("push encoded frame");
    }
    pipeline.flush().expect("decode EOS");
    assert!(
        pipeline.fake_sink_buffer_count() >= 30,
        "expected fake sink to receive at least 30 buffers, got {}",
        pipeline.fake_sink_buffer_count()
    );
    pipeline.stop().expect("decode stop");
}

#[test]
fn requires_keyframe_and_restarts_after_eos() {
    let frames = harvest_vp9_frames(2);
    assert!(
        frames.len() >= 2,
        "expected at least two encoded VP9 frames"
    );

    let pipeline = DecodePipeline::new("vp9", DecodeSinkMode::Fake).expect("decode pipeline");
    let error = pipeline
        .push_frame(&frames[1], 0, 0)
        .expect_err("decoder must reject a delta frame before its first keyframe");
    assert!(
        matches!(&error, MediaError::InvalidArgument { .. }),
        "unexpected keyframe error: {error}"
    );

    pipeline
        .push_frame(&frames[0], 0, MEDIA_FRAME_FLAG_KEYFRAME)
        .expect("push first keyframe");
    pipeline.flush().expect("first decode EOS");
    let first_count = pipeline.fake_sink_buffer_count();
    assert!(first_count >= 1, "first stream produced no decoded buffers");

    // A stream reconnect must be able to reuse the existing native sink. The
    // restart also re-arms keyframe gating for the new stream.
    pipeline.restart().expect("restart decoder");
    let error = pipeline
        .push_frame(&frames[1], 33, 0)
        .expect_err("restarted decoder must wait for a keyframe");
    assert!(matches!(error, MediaError::InvalidArgument { .. }));
    pipeline
        .push_frame(&frames[0], 0, MEDIA_FRAME_FLAG_KEYFRAME)
        .expect("push reconnect keyframe");
    pipeline.flush().expect("second decode EOS");
    assert!(
        pipeline.fake_sink_buffer_count() > first_count,
        "restarted stream did not reach fake sink"
    );

    // EOS is terminal for the current stream, but repeated cleanup should be
    // harmless rather than surfacing a second appsrc EOS error.
    pipeline.flush().expect("idempotent decode EOS");
    pipeline.stop().expect("decode stop");
}

#[test]
fn rejects_oversized_encoded_frames_before_allocating_gstreamer_buffer() {
    let pipeline = DecodePipeline::new("vp9", DecodeSinkMode::Fake).expect("decode pipeline");
    let payload = vec![0_u8; openburnbar_media::decode::MAX_ENCODED_FRAME_BYTES + 1];
    let error = pipeline
        .push_frame(&payload, 0, MEDIA_FRAME_FLAG_KEYFRAME)
        .expect_err("oversized frame must be rejected");
    assert!(matches!(error, MediaError::InvalidArgument { .. }));
    pipeline.stop().expect("decode stop");
}

fn harvest_vp9_frames(count: u32) -> Vec<Vec<u8>> {
    use gst::prelude::*;
    use gst_app::AppSink;

    gst::init().expect("gstreamer init");
    let description = format!(
        "videotestsrc num-buffers={count} is-live=false ! video/x-raw,width=320,height=240,framerate=30/1 ! vp9enc deadline=1 keyframe-max-dist=30 ! appsink name=sink emit-signals=false sync=false"
    );
    let pipeline = gst::parse::launch(&description)
        .expect("encode launch")
        .downcast::<gst::Pipeline>()
        .expect("encode pipeline");
    let appsink = pipeline
        .by_name("sink")
        .expect("appsink")
        .downcast::<AppSink>()
        .expect("appsink type");

    pipeline.set_state(gst::State::Playing).expect("play");
    let mut frames = Vec::new();
    loop {
        if let Some(sample) = appsink.try_pull_sample(gst::ClockTime::from_seconds(2)) {
            let buffer = sample.buffer().expect("sample buffer");
            let map = buffer.map_readable().expect("readable buffer");
            frames.push(map.as_slice().to_vec());
            continue;
        }
        let bus = pipeline.bus().expect("bus");
        if let Some(message) = bus.timed_pop_filtered(
            gst::ClockTime::from_seconds(2),
            &[gst::MessageType::Eos, gst::MessageType::Error],
        ) {
            match message.view() {
                gst::MessageView::Eos(..) => break,
                gst::MessageView::Error(error) => panic!(
                    "encode error from {:?}: {} ({:?})",
                    error.src().map(|source| source.path_string()),
                    error.error(),
                    error.debug()
                ),
                _ => {}
            }
        } else {
            break;
        }
    }
    pipeline.set_state(gst::State::Null).expect("stop");
    frames
}
