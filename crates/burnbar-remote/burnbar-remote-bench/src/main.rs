use std::time::Duration;

use burnbar_remote_core::Dimensions;
use burnbar_remote_media::{AdaptiveQualityController, ControllerInput, QualityPreference};
use burnbar_remote_observability::{
    BenchmarkReport, BenchmarkStage, NetworkTelemetry, PipelineTiming,
};

fn main() {
    let dimensions = Dimensions::new(1920, 1080).expect("valid dimensions");
    let mut controller = AdaptiveQualityController::new(dimensions, QualityPreference::Balanced);
    let mut report = BenchmarkReport::default();

    for sample in 0..120 {
        let mut telemetry = NetworkTelemetry::direct_good();
        if sample > 30 && sample < 50 {
            telemetry.packet_loss_ppm = Some(35_000);
            telemetry.datagram_send_buffer_space = 512;
        }
        let output = controller.update(ControllerInput {
            network: telemetry,
            receiver_report: None,
            decode_time: Duration::from_millis(5),
            render_time: Duration::from_millis(4),
            received_frame_age: Duration::from_millis(if sample > 30 && sample < 50 {
                120
            } else {
                12
            }),
            active_control: sample % 20 < 8,
            preference: QualityPreference::Balanced,
            current_dimensions: dimensions,
        });
        let network_penalty = if sample > 30 && sample < 50 {
            18_000
        } else {
            4_000
        };
        let encode_micros = (18_000_000 / output.target_bitrate_bps.max(1)).max(3_000);
        let glass_to_glass = 2_500 + encode_micros + network_penalty + 4_500 + 3_000;
        report.record_timing(PipelineTiming {
            capture_micros: 2_500,
            encode_micros,
            packetize_micros: 800,
            network_send_micros: network_penalty / 2,
            network_receive_micros: network_penalty / 2,
            decode_micros: 4_500,
            render_micros: 3_000,
            input_to_effect_micros: Some(if sample % 20 < 8 { 12_000 } else { 18_000 }),
            glass_to_glass_micros: Some(glass_to_glass),
        });
    }

    for (stage, summary) in report.summarize() {
        println!(
            "{stage:?}: p50={}us p95={}us p99={}us",
            summary.p50_micros, summary.p95_micros, summary.p99_micros
        );
    }
    let glass = report
        .summarize()
        .get(&BenchmarkStage::GlassToGlass)
        .cloned()
        .expect("glass-to-glass summary");
    println!(
        "synthetic glass-to-glass p95 upper bound: {}us",
        glass.p95_micros
    );
}
