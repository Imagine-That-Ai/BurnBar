use std::collections::BTreeMap;
use std::time::Duration;

use burnbar_remote_core::{Dimensions, FrameId, SequenceNumber, SessionId, TimestampMicros};
use serde::{Deserialize, Serialize};

#[derive(Clone, Copy, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub enum PathKind {
    Direct,
    Relay,
    Mixed,
    Unknown,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PathState {
    pub kind: PathKind,
    pub selected: bool,
    pub remote_addr: String,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct NetworkTelemetry {
    pub path_kind: PathKind,
    pub rtt_micros: Option<u64>,
    pub jitter_micros: Option<u64>,
    pub packet_loss_ppm: Option<u32>,
    pub send_queue_bytes: u32,
    pub datagram_send_buffer_space: u32,
    pub dropped_media_datagrams: u64,
    pub relay: bool,
}

impl NetworkTelemetry {
    pub fn direct_good() -> Self {
        Self {
            path_kind: PathKind::Direct,
            rtt_micros: Some(12_000),
            jitter_micros: Some(1_000),
            packet_loss_ppm: Some(0),
            send_queue_bytes: 0,
            datagram_send_buffer_space: 64 * 1024,
            dropped_media_datagrams: 0,
            relay: false,
        }
    }
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct ReceiverReport {
    pub session_id: SessionId,
    pub sequence: SequenceNumber,
    pub highest_contiguous_frame: FrameId,
    pub last_rendered_frame: FrameId,
    pub received_at: TimestampMicros,
    pub decoded_at: TimestampMicros,
    pub rendered_at: TimestampMicros,
    pub displayed_dimensions: Dimensions,
    pub lost_packets: u32,
    pub keyframe_requests: u32,
    pub decode_time_micros: u32,
    pub render_time_micros: u32,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PipelineTiming {
    pub capture_micros: u32,
    pub encode_micros: u32,
    pub packetize_micros: u32,
    pub network_send_micros: u32,
    pub network_receive_micros: u32,
    pub decode_micros: u32,
    pub render_micros: u32,
    pub input_to_effect_micros: Option<u32>,
    pub glass_to_glass_micros: Option<u32>,
}

#[derive(Clone, Debug)]
pub struct LatencyHistogram {
    buckets_micros: &'static [u64],
    counts: Vec<u64>,
    total: u64,
}

impl Default for LatencyHistogram {
    fn default() -> Self {
        const BUCKETS: &[u64] = &[
            2_000, 4_000, 8_000, 12_000, 16_000, 24_000, 33_000, 50_000, 75_000, 100_000, 150_000,
            250_000, 500_000,
        ];
        Self {
            buckets_micros: BUCKETS,
            counts: vec![0; BUCKETS.len() + 1],
            total: 0,
        }
    }
}

impl LatencyHistogram {
    pub fn record(&mut self, latency: Duration) {
        let micros = latency.as_micros().min(u64::MAX as u128) as u64;
        let idx = self
            .buckets_micros
            .iter()
            .position(|bucket| micros <= *bucket)
            .unwrap_or(self.buckets_micros.len());
        self.counts[idx] += 1;
        self.total += 1;
    }

    pub fn percentile_upper_bound(&self, percentile: f64) -> Option<Duration> {
        if self.total == 0 {
            return None;
        }
        let rank = ((self.total as f64) * percentile.clamp(0.0, 1.0)).ceil() as u64;
        let mut cumulative = 0;
        for (idx, count) in self.counts.iter().enumerate() {
            cumulative += count;
            if cumulative >= rank.max(1) {
                let micros = self
                    .buckets_micros
                    .get(idx)
                    .copied()
                    .unwrap_or_else(|| *self.buckets_micros.last().expect("buckets"));
                return Some(Duration::from_micros(micros));
            }
        }
        None
    }
}

#[derive(Clone, Copy, Debug, PartialEq, Eq, PartialOrd, Ord, Serialize, Deserialize)]
pub enum BenchmarkStage {
    Capture,
    Encode,
    Packetize,
    NetworkSend,
    NetworkReceive,
    Decode,
    Render,
    InputToEffect,
    GlassToGlass,
}

#[derive(Clone, Debug, PartialEq, Eq, Serialize, Deserialize)]
pub struct PercentileSummary {
    pub p50_micros: u64,
    pub p95_micros: u64,
    pub p99_micros: u64,
}

#[derive(Clone, Debug, Default)]
pub struct BenchmarkReport {
    stages: BTreeMap<BenchmarkStage, LatencyHistogram>,
}

impl BenchmarkReport {
    pub fn record_stage(&mut self, stage: BenchmarkStage, latency: Duration) {
        self.stages.entry(stage).or_default().record(latency);
    }

    pub fn record_timing(&mut self, timing: PipelineTiming) {
        self.record_stage(
            BenchmarkStage::Capture,
            Duration::from_micros(timing.capture_micros as u64),
        );
        self.record_stage(
            BenchmarkStage::Encode,
            Duration::from_micros(timing.encode_micros as u64),
        );
        self.record_stage(
            BenchmarkStage::Packetize,
            Duration::from_micros(timing.packetize_micros as u64),
        );
        self.record_stage(
            BenchmarkStage::NetworkSend,
            Duration::from_micros(timing.network_send_micros as u64),
        );
        self.record_stage(
            BenchmarkStage::NetworkReceive,
            Duration::from_micros(timing.network_receive_micros as u64),
        );
        self.record_stage(
            BenchmarkStage::Decode,
            Duration::from_micros(timing.decode_micros as u64),
        );
        self.record_stage(
            BenchmarkStage::Render,
            Duration::from_micros(timing.render_micros as u64),
        );
        if let Some(micros) = timing.input_to_effect_micros {
            self.record_stage(
                BenchmarkStage::InputToEffect,
                Duration::from_micros(micros as u64),
            );
        }
        if let Some(micros) = timing.glass_to_glass_micros {
            self.record_stage(
                BenchmarkStage::GlassToGlass,
                Duration::from_micros(micros as u64),
            );
        }
    }

    pub fn summarize(&self) -> BTreeMap<BenchmarkStage, PercentileSummary> {
        self.stages
            .iter()
            .filter_map(|(stage, histogram)| {
                Some((
                    *stage,
                    PercentileSummary {
                        p50_micros: histogram.percentile_upper_bound(0.50)?.as_micros() as u64,
                        p95_micros: histogram.percentile_upper_bound(0.95)?.as_micros() as u64,
                        p99_micros: histogram.percentile_upper_bound(0.99)?.as_micros() as u64,
                    },
                ))
            })
            .collect()
    }
}

#[cfg(test)]
mod tests {
    use super::*;

    #[test]
    fn histogram_reports_upper_bucket_bound() {
        let mut hist = LatencyHistogram::default();
        hist.record(Duration::from_millis(10));
        hist.record(Duration::from_millis(34));
        assert_eq!(
            hist.percentile_upper_bound(0.50),
            Some(Duration::from_micros(12_000))
        );
        assert_eq!(
            hist.percentile_upper_bound(0.99),
            Some(Duration::from_micros(50_000))
        );
    }

    #[test]
    fn benchmark_report_records_pipeline_stages() {
        let mut report = BenchmarkReport::default();
        report.record_timing(PipelineTiming {
            capture_micros: 3_000,
            encode_micros: 6_000,
            packetize_micros: 1_000,
            network_send_micros: 2_000,
            network_receive_micros: 3_000,
            decode_micros: 5_000,
            render_micros: 4_000,
            input_to_effect_micros: Some(12_000),
            glass_to_glass_micros: Some(24_000),
        });
        let summary = report.summarize();
        assert!(summary.contains_key(&BenchmarkStage::GlassToGlass));
        assert_eq!(summary[&BenchmarkStage::Encode].p95_micros, 8_000);
    }
}
