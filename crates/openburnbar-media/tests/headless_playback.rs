#![cfg(feature = "gstreamer")]

use openburnbar_media::{AudioPlaybackPipeline, DecodeSinkMode, MediaError};

#[test]
fn decodes_opus_packets_into_fake_sink() {
    let packets = harvest_opus_packets(12);
    assert!(packets.len() >= 12, "expected at least 12 Opus packets");

    let pipeline = AudioPlaybackPipeline::new(DecodeSinkMode::Fake).expect("audio playback");
    for (index, packet) in packets.iter().enumerate() {
        pipeline
            .push_packet(packet, (index as u64) * 20)
            .expect("push Opus packet");
    }
    pipeline.flush().expect("audio playback EOS");
    assert!(
        pipeline.fake_sink_buffer_count() >= 12,
        "expected fake sink to receive packets, got {}",
        pipeline.fake_sink_buffer_count()
    );
    pipeline.stop().expect("audio playback stop");
}

#[test]
fn rejects_empty_and_oversized_opus_packets_before_gstreamer_push() {
    let pipeline = AudioPlaybackPipeline::new(DecodeSinkMode::Fake).expect("audio playback");
    assert!(matches!(
        pipeline.push_packet(&[], 0),
        Err(MediaError::InvalidArgument { .. })
    ));
    let payload = vec![0_u8; openburnbar_media::playback::MAX_OPUS_PACKET_BYTES + 1];
    assert!(matches!(
        pipeline.push_packet(&payload, 0),
        Err(MediaError::InvalidArgument { .. })
    ));
    pipeline.stop().expect("audio playback stop");
}

#[test]
fn restarts_after_eos_and_remains_bounded() {
    let packets = harvest_opus_packets(2);
    assert!(packets.len() >= 2, "expected at least two Opus packets");
    let pipeline = AudioPlaybackPipeline::new(DecodeSinkMode::Fake).expect("audio playback");
    pipeline.push_packet(&packets[0], 0).expect("first packet");
    pipeline.flush().expect("first EOS");
    let first_count = pipeline.fake_sink_buffer_count();
    assert!(first_count >= 1);
    assert!(matches!(
        pipeline.push_packet(&packets[1], 20),
        Err(MediaError::StateChange { .. })
    ));
    pipeline.restart().expect("restart audio playback");
    pipeline
        .push_packet(&packets[1], 20)
        .expect("reconnect packet");
    pipeline.flush().expect("second EOS");
    assert!(pipeline.fake_sink_buffer_count() > first_count);
    pipeline.flush().expect("idempotent EOS");
    pipeline.stop().expect("audio playback stop");
}

fn harvest_opus_packets(count: u32) -> Vec<Vec<u8>> {
    use gst::prelude::*;
    use gst_app::AppSink;

    gst::init().expect("gstreamer init");
    let description = format!(
        "audiotestsrc num-buffers={} is-live=false wave=sine ! audio/x-raw,rate=48000,channels=1 ! opusenc bitrate=64000 ! appsink name=sink emit-signals=false sync=false",
        count * 2
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
    let mut packets = Vec::new();
    loop {
        if let Some(sample) = appsink.try_pull_sample(gst::ClockTime::from_seconds(2)) {
            let buffer = sample.buffer().expect("sample buffer");
            let map = buffer.map_readable().expect("readable buffer");
            packets.push(map.as_slice().to_vec());
            if packets.len() >= count as usize {
                break;
            }
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
    packets
}
