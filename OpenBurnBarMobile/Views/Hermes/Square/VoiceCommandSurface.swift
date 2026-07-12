import SwiftUI
import Speech
import AVFoundation
import OpenBurnBarCore

// MARK: - Voice Command Surface (Hermes Square §6.7)
//
// Hold-to-talk press-and-speak surface. SFSpeechRecognizer streams
// partial transcripts; on release we resolve the transcript to a
// `VoiceIntent` and emit it to the caller. Phase D default per plan §9.4
// (hold-to-talk first, push-to-talk via toggle).

struct VoiceCommandSurface: View {

    let registry: AgentIdentityRegistry
    let currentThreadAgentURI: String?
    let onIntent: (VoiceIntent) -> Void

    @State private var isPressed: Bool = false
    @State private var transcript: String = ""
    @State private var lastError: String?
    @State private var session = VoiceCaptureSession()
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    var body: some View {
        VStack(spacing: 14) {
            transcriptBox
            captureButton
            errorRow
        }
        .padding(18)
        .frame(maxWidth: .infinity)
        .background(
            RoundedRectangle(cornerRadius: 16)
                .fill(DesignSystemColors.surface.opacity(0.65))
                .overlay(
                    RoundedRectangle(cornerRadius: 16)
                        .stroke(DesignSystemColors.borderSubtle, lineWidth: 0.5)
                )
        )
        .onAppear {
            session.requestAuthorization { granted in
                if !granted { lastError = "Voice access not granted." }
            }
        }
    }

    // MARK: Transcript box

    private var transcriptBox: some View {
        VStack(alignment: .leading, spacing: 4) {
            HStack(spacing: 6) {
                Image(systemName: "mic.fill").foregroundStyle(DesignSystemColors.ember)
                Text(isPressed ? "Listening…" : "Hold to talk")
                    .font(.caption.bold())
                    .foregroundStyle(DesignSystemColors.textSecondary)
                Spacer()
                if isPressed {
                    PulsingDot()
                }
            }
            Text(transcript.isEmpty ? "Say \"open Claude\", \"dispatch the brief to Codex\", or \"what's important?\"" : transcript)
                .font(.body)
                .foregroundStyle(transcript.isEmpty ? DesignSystemColors.textMuted : DesignSystemColors.textPrimary)
                .frame(maxWidth: .infinity, alignment: .leading)
                .padding(.vertical, 8)
        }
        .padding(.horizontal, 12)
        .padding(.vertical, 10)
        .background(
            RoundedRectangle(cornerRadius: 10)
                .fill(DesignSystemColors.surface.opacity(0.6))
        )
    }

    // MARK: Capture button

    private var captureButton: some View {
        // Breathing pulse while idle: a low-frequency sin curve drives a
        // gentle scale + glow halo so the button feels alive without
        // shouting. Locked to a `TimelineView` so we don't run a CPU
        // animation off-screen, and short-circuited when pressed (the
        // active press scale takes over) and when Reduce Motion is on.
        TimelineView(.animation(minimumInterval: 1.0 / 30.0)) { timeline in
            let breathPhase = breathPhase(at: timeline.date)
            let breathScale: CGFloat = reduceMotion ? 1.0
                : (isPressed ? 1.08 : (1.0 + 0.035 * breathPhase))
            let breathGlow: CGFloat = reduceMotion ? 0
                : (isPressed ? 0.45 : 0.10 + 0.10 * breathPhase)
            ZStack {
                // Outer breath halo: a faint ring that pulses with the
                // same phase, so the breath reads even when the button
                // itself is steady (helpful for static screenshots).
                Circle()
                    .stroke(
                        DesignSystemColors.ember.opacity(reduceMotion ? 0 : 0.18 + 0.12 * breathPhase),
                        lineWidth: 2
                    )
                    .frame(width: 116, height: 116)
                    .scaleEffect(reduceMotion ? 1.0 : 1.0 + 0.04 * breathPhase)
                    .opacity(isPressed ? 0 : 1)
                Circle()
                    .fill(
                        LinearGradient(
                            colors: [DesignSystemColors.ember, DesignSystemColors.amber],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 96, height: 96)
                    .scaleEffect(breathScale)
                    .shadow(color: DesignSystemColors.ember.opacity(breathGlow), radius: 14)
                Image(systemName: isPressed ? "waveform" : "mic.fill")
                    .font(.system(size: 36, weight: .bold))
                    .foregroundStyle(.white)
                    .scaleEffect(breathScale)
            }
            .animation(.spring(response: 0.25, dampingFraction: 0.7), value: isPressed)
        }
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    if !isPressed { beginCapture() }
                }
                .onEnded { _ in endCapture() }
        )
        .accessibilityAddTraits(.isButton)
        .accessibilityLabel("Hold to talk")
    }

    /// 0…1 sin-driven breath cycle, period ≈ 3.4s. Pure function so
    /// `TimelineView` re-renders at 30Hz without storing animation state.
    private func breathPhase(at date: Date) -> CGFloat {
        let t = date.timeIntervalSinceReferenceDate
        let period: Double = 3.4
        let normalized = (sin(2 * .pi * t / period) + 1) / 2 // 0…1
        return CGFloat(normalized)
    }

    @ViewBuilder
    private var errorRow: some View {
        if let lastError {
            Text(lastError)
                .font(.caption)
                .foregroundStyle(DesignSystemColors.error)
                .multilineTextAlignment(.center)
        }
    }

    // MARK: Capture lifecycle

    private func beginCapture() {
        guard session.isAvailable else {
            lastError = "Speech recognition isn't available right now."
            return
        }
        isPressed = true
        lastError = nil
        transcript = ""
        Task { @MainActor in
            // Record permission is separate from speech-recognition
            // authorization — without it the engine gets no input (and on
            // some routes an invalid 0 Hz format that would crash
            // `installTap`). Ask before touching the engine.
            guard await session.requestRecordPermission() else {
                isPressed = false
                lastError = "Microphone access is off for OpenBurnBar. Open Settings > OpenBurnBar to allow microphone access."
                return
            }
            // The user may have released the button while the permission
            // prompt was up — don't start a capture nobody is holding.
            guard isPressed else { return }
            session.start(
                onPartial: { partial in transcript = partial },
                onFailure: { msg in
                    lastError = msg
                    isPressed = false
                }
            )
        }
    }

    private func endCapture() {
        guard isPressed else { return }
        isPressed = false
        session.stop()
        let finalTranscript = transcript
        guard !finalTranscript.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty else { return }
        let nameMap = Dictionary(uniqueKeysWithValues: registry.identities.map { ($0.displayName.lowercased(), $0.id) })
        let intent = VoiceIntentResolver.resolve(
            transcript: finalTranscript,
            installedAgentNames: nameMap,
            currentThreadAgentURI: currentThreadAgentURI
        )
        onIntent(intent)
    }
}

// MARK: - Capture session

@MainActor
private final class VoiceCaptureSession {
    private let recognizer = SFSpeechRecognizer(locale: Locale.current)
    private var request: SFSpeechAudioBufferRecognitionRequest?
    private var task: SFSpeechRecognitionTask?
    private let audioEngine = AVAudioEngine()

    var isAvailable: Bool { recognizer?.isAvailable ?? false }

    func requestAuthorization(_ completion: @escaping (Bool) -> Void) {
        SFSpeechRecognizer.requestAuthorization { status in
            DispatchQueue.main.async {
                completion(status == .authorized)
            }
        }
    }

    /// Microphone-record permission — required in addition to
    /// speech-recognition authorization before the audio engine can
    /// deliver input. Fast-paths the already-decided states so the
    /// system prompt only ever appears once.
    func requestRecordPermission() async -> Bool {
        switch AVAudioApplication.shared.recordPermission {
        case .granted:
            return true
        case .denied:
            return false
        case .undetermined:
            return await AVAudioApplication.requestRecordPermission()
        @unknown default:
            return false
        }
    }

    func start(onPartial: @escaping (String) -> Void, onFailure: @escaping (String) -> Void) {
        guard let recognizer, recognizer.isAvailable else {
            onFailure("Speech recognizer offline.")
            return
        }

        // A record-capable session category is mandatory before installing
        // the input tap — without one the input node advertises a 0 Hz
        // format and `installTap` raises an uncatchable NSException. This
        // surface never plays audio back, so plain `.record` is enough.
        let audioSession = AVAudioSession.sharedInstance()
        do {
            try audioSession.setCategory(.record, mode: .measurement, options: .duckOthers)
            try audioSession.setActive(true, options: .notifyOthersOnDeactivation)
        } catch {
            onFailure("Could not activate the microphone: \(error.localizedDescription)")
            return
        }

        let request = SFSpeechAudioBufferRecognitionRequest()
        request.shouldReportPartialResults = true
        self.request = request

        let inputNode = audioEngine.inputNode
        inputNode.removeTap(onBus: 0)
        let format = inputNode.outputFormat(forBus: 0)
        // Belt and braces: an invalid input format (0 Hz / 0 channels —
        // seen when no input route is available) would crash inside
        // `installTap`. Fail soft instead.
        guard format.sampleRate > 0, format.channelCount > 0 else {
            self.request = nil
            onFailure("No usable microphone input is available right now.")
            return
        }
        inputNode.installTap(onBus: 0, bufferSize: 1024, format: format) { buffer, _ in
            request.append(buffer)
        }

        do {
            audioEngine.prepare()
            try audioEngine.start()
        } catch {
            onFailure("Audio engine failed: \(error.localizedDescription)")
            return
        }

        task = recognizer.recognitionTask(with: request) { result, error in
            if let result {
                Task { @MainActor in
                    onPartial(result.bestTranscription.formattedString)
                }
            }
            if let error {
                Task { @MainActor in
                    onFailure(error.localizedDescription)
                }
            }
        }
    }

    func stop() {
        audioEngine.stop()
        audioEngine.inputNode.removeTap(onBus: 0)
        request?.endAudio()
        task?.finish()
        task = nil
        request = nil
        // Hand the audio session back so other audio (Mercury calls,
        // media playback) isn't left ducked behind a dead record session.
        try? AVAudioSession.sharedInstance().setActive(false, options: .notifyOthersOnDeactivation)
    }
}

// MARK: - Helpers

private struct PulsingDot: View {
    @State private var pulse: Bool = false
    var body: some View {
        Circle()
            .fill(DesignSystemColors.ember)
            .frame(width: 8, height: 8)
            .opacity(pulse ? 1.0 : 0.4)
            .onAppear {
                withAnimation(.easeInOut(duration: 0.8).repeatForever(autoreverses: true)) {
                    pulse = true
                }
            }
    }
}
