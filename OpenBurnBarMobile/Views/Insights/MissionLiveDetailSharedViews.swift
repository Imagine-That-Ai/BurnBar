import SwiftUI
import OpenBurnBarCore
#if canImport(UIKit)
import UIKit
#endif
#if canImport(AVFoundation)
import AVFoundation
#endif

struct MissionLiveDetailView: View {
    let mission: CLIAgentMissionSnapshot
    let onApprovalResponse: (Bool) -> Void
    let onFloat: (() -> Void)?
    let onPictureInPicture: (() -> Void)?
    @State private var activeFilters: Set<MissionEventFilter> = Set(MissionEventFilter.allCases)

    init(
        mission: CLIAgentMissionSnapshot,
        onApprovalResponse: @escaping (Bool) -> Void,
        onFloat: (() -> Void)? = nil,
        onPictureInPicture: (() -> Void)? = nil
    ) {
        self.mission = mission
        self.onApprovalResponse = onApprovalResponse
        self.onFloat = onFloat
        self.onPictureInPicture = onPictureInPicture
    }

    private var visibleEvents: [CLIAgentMissionEvent] {
        mission.events.filter { event in
            activeFilters.contains(MissionEventFilter(event: event))
        }
    }

    var body: some View {
        NavigationStack {
            ScrollView {
                VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                    VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.xs) {
                        Text(mission.title)
                            .font(UnifiedDesignSystem.Typography.title)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        Text(mission.displayLiveSummary?.nilIfEmpty ?? mission.displayStatus.capitalized)
                            .font(UnifiedDesignSystem.Typography.caption)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    }

                    ScrollView(.horizontal, showsIndicators: false) {
                        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                            MissionDetailChip(label: mission.displayStatus.uppercased(), systemImage: mission.isTerminal ? "checkmark.circle" : "dot.radiowaves.left.and.right")
                            MissionDetailChip(label: mission.runtimeLabel, systemImage: "desktopcomputer")
                            MissionDetailChip(label: mission.currentStepLabel, systemImage: "arrow.triangle.2.circlepath")
                            if let skillRunID = mission.skillRunID {
                                MissionDetailChip(label: skillRunID.displayName, systemImage: "sparkles")
                            }
                            MissionDetailChip(label: mission.deliveryMode.displayName, systemImage: "bell.badge")
                            if let tool = mission.activeToolName {
                                MissionDetailChip(label: tool, systemImage: "hammer")
                            }
                            if let artifact = mission.latestArtifactLabel {
                                MissionDetailChip(label: artifact, systemImage: "doc.text")
                            }
                        }
                    }

                    if onFloat != nil || onPictureInPicture != nil {
                        HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                            if let onFloat {
                                Button {
                                    onFloat()
                                } label: {
                                    Label("Float", systemImage: "rectangle.on.rectangle")
                                }
                                .buttonStyle(.bordered)
                            }
                            if let onPictureInPicture {
                                Button {
                                    onPictureInPicture()
                                } label: {
                                    Label("PiP", systemImage: "pip.enter")
                                }
                                .buttonStyle(.borderedProminent)
                                .tint(UnifiedDesignSystem.Colors.hermesAureate)
                            }
                        }
                    }

                    if mission.isWaitingForApproval {
                        MissionDetailSection(title: mission.approvalTitle?.nilIfEmpty ?? "Approval Required") {
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                Text(mission.approvalMessage?.nilIfEmpty ?? "The Mac is waiting for approval before continuing this mission.")
                                    .font(UnifiedDesignSystem.Typography.caption)
                                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                                HStack(spacing: UnifiedDesignSystem.Spacing.sm) {
                                    Button {
                                        onApprovalResponse(true)
                                    } label: {
                                        Label("Approve", systemImage: "checkmark.circle.fill")
                                    }
                                    .buttonStyle(.borderedProminent)
                                    .tint(UnifiedDesignSystem.Colors.success)

                                    Button(role: .destructive) {
                                        onApprovalResponse(false)
                                    } label: {
                                        Label("Reject", systemImage: "xmark.octagon")
                                    }
                                    .buttonStyle(.bordered)
                                }
                            }
                        }
                    }

                    if let sessionID = mission.sessionID?.nilIfEmpty {
                        MissionDetailSection(title: "Session") {
                            Text(sessionID)
                                .font(UnifiedDesignSystem.Typography.monoTiny)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                                .textSelection(.enabled)
                        }
                    }

                    MissionDetailSection(title: "Live Timeline") {
                        if mission.events.isEmpty {
                            Text("Waiting for the Mac agent to report progress.")
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        } else {
                            MissionEventFilterBar(activeFilters: $activeFilters)
                            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
                                ForEach(visibleEvents) { event in
                                    MissionTimelineRow(event: event)
                                }
                            }
                        }
                    }

                    if let result = mission.resultPreview?.nilIfEmpty {
                        MissionDetailSection(title: "Result") {
                            Text(result)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                                .textSelection(.enabled)
                        }
                    }

                    if let error = mission.errorMessage?.nilIfEmpty {
                        MissionDetailSection(title: "Failure") {
                            Text(error)
                                .font(UnifiedDesignSystem.Typography.caption)
                                .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                                .textSelection(.enabled)
                        }
                    }
                }
                .padding(UnifiedDesignSystem.Spacing.lg)
            }
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle("Mission Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

enum MissionEventFilter: String, CaseIterable, Identifiable {
    case llm
    case tools
    case errors
    case approvals
    case artifacts
    case status

    var id: String { rawValue }

    init(event: CLIAgentMissionEvent) {
        if event.isError || event.kind == "error" || event.phase == "failed" {
            self = .errors
        } else if event.kind == "tool_call" || event.kind == "tool_result" || event.phase == "tool_use" {
            self = .tools
        } else if event.kind == "approval_request" || event.phase.contains("approval") {
            self = .approvals
        } else if event.kind == "artifact" || event.kind == "changed_file" || event.artifactPath != nil || event.changedFilePath != nil {
            self = .artifacts
        } else if event.kind == "llm_response" || event.kind == "assistant_message" || event.kind == "final_answer" || event.phase == "assistant_response" {
            self = .llm
        } else {
            self = .status
        }
    }

    var label: String {
        switch self {
        case .llm: return "LLM"
        case .tools: return "Tools"
        case .errors: return "Errors"
        case .approvals: return "Approvals"
        case .artifacts: return "Artifacts"
        case .status: return "Status"
        }
    }
}

struct MissionEventFilterBar: View {
    @Binding var activeFilters: Set<MissionEventFilter>

    var body: some View {
        ScrollView(.horizontal, showsIndicators: false) {
            HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                ForEach(MissionEventFilter.allCases) { filter in
                    Button {
                        if activeFilters.contains(filter), activeFilters.count > 1 {
                            activeFilters.remove(filter)
                        } else {
                            activeFilters.insert(filter)
                        }
                    } label: {
                        Text(filter.label)
                            .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                            .foregroundStyle(activeFilters.contains(filter) ? Color.white : UnifiedDesignSystem.Colors.textSecondary)
                            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
                            .padding(.vertical, 6)
                            .background(activeFilters.contains(filter) ? UnifiedDesignSystem.Colors.ember : UnifiedDesignSystem.Colors.surface)
                            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm))
                    }
                    .buttonStyle(.plain)
                }
            }
        }
    }
}

struct MissionQueuedDetailView: View {
    let title: String
    let runtime: String
    let detail: String

    var body: some View {
        NavigationStack {
            VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.lg) {
                Text(title)
                    .font(UnifiedDesignSystem.Typography.title)
                MissionDetailChip(label: runtime, systemImage: "desktopcomputer")
                Text(detail)
                    .font(UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                Spacer()
            }
            .padding(UnifiedDesignSystem.Spacing.lg)
            .frame(maxWidth: .infinity, alignment: .leading)
            .background(UnifiedDesignSystem.Colors.background)
            .navigationTitle("Mission Live")
            .navigationBarTitleDisplayMode(.inline)
        }
    }
}

struct MissionDetailChip: View {
    let label: String
    let systemImage: String

    var body: some View {
        Label(label, systemImage: systemImage)
            .font(UnifiedDesignSystem.Typography.tiny.weight(.semibold))
            .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
            .padding(.horizontal, UnifiedDesignSystem.Spacing.sm)
            .padding(.vertical, 6)
            .background(UnifiedDesignSystem.Colors.surface)
            .clipShape(RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm))
    }
}

struct MissionDetailSection<Content: View>: View {
    let title: String
    @ViewBuilder var content: Content

    var body: some View {
        VStack(alignment: .leading, spacing: UnifiedDesignSystem.Spacing.sm) {
            Text(title)
                .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
            content
        }
    }
}

struct MissionTimelineRow: View {
    let event: CLIAgentMissionEvent

    var body: some View {
        HStack(alignment: .top, spacing: UnifiedDesignSystem.Spacing.sm) {
            Image(systemName: iconName)
                .font(.system(size: 13, weight: .semibold))
                .foregroundStyle(iconColor)
                .frame(width: 18, height: 18)
            VStack(alignment: .leading, spacing: 3) {
                HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                    Text((event.title?.nilIfEmpty ?? event.phase.replacingOccurrences(of: "_", with: " ")).uppercased())
                        .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    if let runtime = event.runtime?.nilIfEmpty {
                        Text(runtime)
                            .font(UnifiedDesignSystem.Typography.monoTiny)
                            .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                    }
                }
                Text(event.displayMessage)
                    .font(event.prefersMonospace ? UnifiedDesignSystem.Typography.monoTiny : UnifiedDesignSystem.Typography.caption)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                    .textSelection(.enabled)
                    .fixedSize(horizontal: false, vertical: true)
                    .padding(event.prefersMonospace ? 10 : 0)
                    .background {
                        if event.prefersMonospace {
                            RoundedRectangle(cornerRadius: UnifiedDesignSystem.Radius.sm)
                                .fill(UnifiedDesignSystem.Colors.surface.opacity(0.72))
                        }
                    }
                if event.messageTruncated {
                    Text("Showing redacted mobile payload capped at \(event.messageLength ?? event.displayMessage.count) chars.")
                        .font(UnifiedDesignSystem.Typography.monoTiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.warning)
                }
                if event.toolName?.nilIfEmpty != nil || event.artifactPath?.nilIfEmpty != nil || event.changedFilePath?.nilIfEmpty != nil {
                    HStack(spacing: UnifiedDesignSystem.Spacing.xs) {
                        if let toolName = event.toolName?.nilIfEmpty {
                            MissionDetailChip(label: toolName, systemImage: "hammer")
                        }
                        if let artifactPath = event.artifactPath?.nilIfEmpty {
                            MissionDetailChip(label: artifactPath, systemImage: "doc.text")
                        }
                        if let changedFilePath = event.changedFilePath?.nilIfEmpty {
                            MissionDetailChip(label: changedFilePath, systemImage: "pencil.and.list.clipboard")
                        }
                    }
                }
                Text(event.timestamp)
                    .font(UnifiedDesignSystem.Typography.monoTiny)
                    .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
            }
        }
    }

    private var iconName: String {
        switch event.phase {
        case "agent_launch_failed": return "xmark.octagon.fill"
        case "tool_use", "tool_result": return "hammer"
        case "assistant_response": return "text.bubble"
        case "completed": return "checkmark.circle.fill"
        case "failed": return "exclamationmark.triangle.fill"
        default: return "circle.dotted"
        }
    }

    private var iconColor: Color {
        if event.isError { return UnifiedDesignSystem.Colors.warning }
        switch event.phase {
        case "completed": return UnifiedDesignSystem.Colors.success
        case "failed": return UnifiedDesignSystem.Colors.warning
        case "tool_use", "tool_result": return UnifiedDesignSystem.Colors.ember
        default: return UnifiedDesignSystem.Colors.whimsy
        }
    }
}

extension CLIAgentMissionEvent {
    var displayMessage: String {
        fullMessage?.nilIfEmpty ?? message
    }

    var prefersMonospace: Bool {
        kind == "tool_call"
            || kind == "tool_result"
            || kind == "llm_response"
            || kind == "assistant_message"
            || kind == "final_answer"
            || displayMessage.contains("\n")
    }
}

#if canImport(UIKit) && canImport(AVFoundation)
@MainActor
final class SkillRunTextPiPController: ObservableObject {
    @Published private(set) var isActive = false
    @Published private(set) var lastStartSucceeded = false

    private let displayLayer = AVSampleBufferDisplayLayer()
    private let controller = ScreenSharePiPController()
    private var attached = false
    private var lastMissionID: String?

    init() {
        displayLayer.videoGravity = .resizeAspect
    }

    func start(mission: CLIAgentMissionSnapshot) {
        attachIfNeeded()
        update(mission: mission)
        controller.onDidStart = { [weak self] in self?.isActive = true }
        controller.onDidStop = { [weak self] in self?.isActive = false }
        lastStartSucceeded = controller.start()
    }

    func update(mission: CLIAgentMissionSnapshot?) {
        guard let mission else { return }
        lastMissionID = mission.id
        if displayLayer.status == .failed {
            displayLayer.flush()
        }
        if let sampleBuffer = SkillRunPiPFrameRenderer.makeSampleBuffer(for: mission) {
            displayLayer.enqueue(sampleBuffer)
        }
    }

    func stop() {
        controller.stop()
        isActive = false
    }

    private func attachIfNeeded() {
        guard !attached else { return }
        controller.attach(displayLayer: displayLayer)
        attached = true
    }
}

enum SkillRunPiPFrameRenderer {
    static let frameSize = CGSize(width: 960, height: 540)

    static func makeSampleBuffer(for mission: CLIAgentMissionSnapshot) -> CMSampleBuffer? {
        guard let pixelBuffer = makePixelBuffer(for: mission) else { return nil }
        var formatDescription: CMVideoFormatDescription?
        guard CMVideoFormatDescriptionCreateForImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescriptionOut: &formatDescription
        ) == noErr, let formatDescription else {
            return nil
        }

        var timing = CMSampleTimingInfo(
            duration: CMTime(value: 1, timescale: 30),
            presentationTimeStamp: CMClockGetTime(CMClockGetHostTimeClock()),
            decodeTimeStamp: .invalid
        )
        var sampleBuffer: CMSampleBuffer?
        let status = CMSampleBufferCreateReadyWithImageBuffer(
            allocator: kCFAllocatorDefault,
            imageBuffer: pixelBuffer,
            formatDescription: formatDescription,
            sampleTiming: &timing,
            sampleBufferOut: &sampleBuffer
        )
        return status == noErr ? sampleBuffer : nil
    }

    private static func makePixelBuffer(for mission: CLIAgentMissionSnapshot) -> CVPixelBuffer? {
        let width = Int(frameSize.width)
        let height = Int(frameSize.height)
        let attributes: [CFString: Any] = [
            kCVPixelBufferCGImageCompatibilityKey: true,
            kCVPixelBufferCGBitmapContextCompatibilityKey: true,
            kCVPixelBufferIOSurfacePropertiesKey: [:]
        ]
        var pixelBuffer: CVPixelBuffer?
        guard CVPixelBufferCreate(
            kCFAllocatorDefault,
            width,
            height,
            kCVPixelFormatType_32BGRA,
            attributes as CFDictionary,
            &pixelBuffer
        ) == kCVReturnSuccess, let pixelBuffer else {
            return nil
        }

        CVPixelBufferLockBaseAddress(pixelBuffer, [])
        defer { CVPixelBufferUnlockBaseAddress(pixelBuffer, []) }

        guard let baseAddress = CVPixelBufferGetBaseAddress(pixelBuffer) else { return nil }
        let bytesPerRow = CVPixelBufferGetBytesPerRow(pixelBuffer)
        let colorSpace = CGColorSpaceCreateDeviceRGB()
        let bitmapInfo = CGBitmapInfo.byteOrder32Little.rawValue | CGImageAlphaInfo.premultipliedFirst.rawValue
        guard let context = CGContext(
            data: baseAddress,
            width: width,
            height: height,
            bitsPerComponent: 8,
            bytesPerRow: bytesPerRow,
            space: colorSpace,
            bitmapInfo: bitmapInfo
        ) else {
            return nil
        }

        UIGraphicsPushContext(context)
        draw(mission: mission, in: CGRect(origin: .zero, size: frameSize))
        UIGraphicsPopContext()
        return pixelBuffer
    }

    private static func draw(mission: CLIAgentMissionSnapshot, in rect: CGRect) {
        let cg = UIGraphicsGetCurrentContext()
        cg?.setFillColor(UIColor(red: 0.04, green: 0.035, blue: 0.03, alpha: 1).cgColor)
        cg?.fill(rect)

        let accent = UIColor(red: 1.0, green: 0.54, blue: 0.20, alpha: 1)
        let panel = CGRect(x: 56, y: 54, width: rect.width - 112, height: rect.height - 108)
        let path = UIBezierPath(roundedRect: panel, cornerRadius: 28)
        UIColor(red: 0.10, green: 0.09, blue: 0.08, alpha: 0.96).setFill()
        path.fill()
        accent.withAlphaComponent(0.75).setStroke()
        path.lineWidth = 3
        path.stroke()

        let title = mission.skillRunID?.displayName ?? "Hermes Skill Run"
        drawText(title, at: CGPoint(x: 92, y: 86), size: 44, weight: .bold, color: .white)
        drawText(mission.title, at: CGPoint(x: 94, y: 145), size: 27, weight: .semibold, color: UIColor.white.withAlphaComponent(0.86), maxWidth: 760)

        let status = mission.isWaitingForApproval ? "APPROVAL NEEDED" : mission.displayStatus.uppercased()
        let statusColor = mission.isWaitingForApproval ? UIColor(red: 1.0, green: 0.79, blue: 0.28, alpha: 1) :
            (mission.isTerminal ? UIColor(red: 0.36, green: 0.88, blue: 0.57, alpha: 1) : accent)
        drawPill(status, at: CGPoint(x: 92, y: 206), color: statusColor)
        drawPill(mission.deliveryMode.displayName.uppercased(), at: CGPoint(x: 92, y: 262), color: UIColor(red: 0.54, green: 0.70, blue: 1.0, alpha: 1))

        let latest = mission.events.last?.displayMessage.nilIfEmpty
            ?? mission.displayLiveSummary?.nilIfEmpty
            ?? mission.currentStepLabel
        drawText(latest, at: CGPoint(x: 94, y: 336), size: 24, weight: .regular, color: UIColor.white.withAlphaComponent(0.78), maxWidth: 760)

        let footer = mission.isWaitingForApproval ? "Open BurnBar to approve or reject" : "Tap PiP to return to BurnBar"
        drawText(footer, at: CGPoint(x: 94, y: 450), size: 22, weight: .medium, color: UIColor.white.withAlphaComponent(0.58), maxWidth: 760)
    }

    private static func drawPill(_ text: String, at point: CGPoint, color: UIColor) {
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.monospacedSystemFont(ofSize: 21, weight: .bold),
            .foregroundColor: color
        ]
        let size = (text as NSString).size(withAttributes: attributes)
        let rect = CGRect(x: point.x, y: point.y, width: size.width + 30, height: 38)
        let path = UIBezierPath(roundedRect: rect, cornerRadius: 14)
        color.withAlphaComponent(0.13).setFill()
        path.fill()
        color.withAlphaComponent(0.65).setStroke()
        path.lineWidth = 1.5
        path.stroke()
        (text as NSString).draw(at: CGPoint(x: point.x + 15, y: point.y + 7), withAttributes: attributes)
    }

    private static func drawText(
        _ text: String,
        at point: CGPoint,
        size: CGFloat,
        weight: UIFont.Weight,
        color: UIColor,
        maxWidth: CGFloat = 820
    ) {
        let paragraph = NSMutableParagraphStyle()
        paragraph.lineBreakMode = .byTruncatingTail
        let attributes: [NSAttributedString.Key: Any] = [
            .font: UIFont.systemFont(ofSize: size, weight: weight),
            .foregroundColor: color,
            .paragraphStyle: paragraph
        ]
        (text as NSString).draw(
            with: CGRect(x: point.x, y: point.y, width: maxWidth, height: size * 2.4),
            options: [.usesLineFragmentOrigin, .truncatesLastVisibleLine],
            attributes: attributes,
            context: nil
        )
    }
}

@MainActor
final class SkillRunLiveStagePresenter: ObservableObject {
    enum Corner: String, Equatable, Sendable, CaseIterable {
        case topLeading
        case topTrailing
        case bottomLeading
        case bottomTrailing
    }

    @Published var isVisible = false
    @Published var focusedMissionID: String?
    @Published var dockCorner: Corner = .bottomLeading
    private var dismissedNotificationKeys: [String: String] = [:]

    func reconcile(missions: [CLIAgentMissionSnapshot]) {
        guard let mission = resolveMission(from: missions) else {
            isVisible = false
            focusedMissionID = nil
            return
        }
        if focusedMissionID == nil || !missions.contains(where: { $0.id == focusedMissionID && !isDismissed($0) }) {
            focusedMissionID = mission.id
        }
        guard !isDismissed(mission), shouldAutoOpen(mission) else { return }
        isVisible = true
    }

    func show(_ mission: CLIAgentMissionSnapshot) {
        dismissedNotificationKeys[mission.id] = nil
        focusedMissionID = mission.id
        isVisible = true
    }

    func dismiss(_ mission: CLIAgentMissionSnapshot?) {
        if let mission {
            dismissedNotificationKeys[mission.id] = notificationKey(for: mission)
        }
        isVisible = false
    }

    func resolveMission(from missions: [CLIAgentMissionSnapshot]) -> CLIAgentMissionSnapshot? {
        let visible = missions.filter { !isDismissed($0) }
        if let focusedMissionID, let focused = visible.first(where: { $0.id == focusedMissionID }) {
            return focused
        }
        return visible.first { !$0.isTerminal } ?? visible.first
    }

    func snapDock(to corner: Corner) {
        dockCorner = corner
    }

    static func nearestCorner(for point: CGPoint, in size: CGSize) -> Corner {
        let isLeading = point.x < size.width / 2
        let isTop = point.y < size.height / 2
        switch (isTop, isLeading) {
        case (true, true): return .topLeading
        case (true, false): return .topTrailing
        case (false, true): return .bottomLeading
        case (false, false): return .bottomTrailing
        }
    }

    private func shouldAutoOpen(_ mission: CLIAgentMissionSnapshot) -> Bool {
        switch mission.deliveryMode {
        case .fullStream:
            return true
        case .actionOnly:
            return mission.isWaitingForApproval || mission.isTerminal || mission.events.last?.eventImportance == .actionRequired || mission.events.last?.eventImportance == .terminal
        case .muted:
            return false
        }
    }

    private func isDismissed(_ mission: CLIAgentMissionSnapshot) -> Bool {
        dismissedNotificationKeys[mission.id] == notificationKey(for: mission)
    }

    private func notificationKey(for mission: CLIAgentMissionSnapshot) -> String {
        let latest = mission.events.last
        let shouldResurface = mission.isWaitingForApproval
            || mission.isTerminal
            || latest?.eventImportance == .actionRequired
            || latest?.eventImportance == .terminal
        guard shouldResurface else {
            return [
                mission.id,
                mission.deliveryMode.rawValue,
                "passive"
            ].joined(separator: "|")
        }
        return [
            mission.id,
            mission.status,
            mission.deliveryMode.rawValue,
            mission.approvalStatus ?? "none",
            "\(latest?.sequence ?? -1)",
            latest?.eventImportance.rawValue ?? "none",
            latest?.phase ?? "none"
        ].joined(separator: "|")
    }
}

struct SkillRunLiveStage: View {
    @Bindable var host: MobileMissionConsoleHost
    @ObservedObject var pipController: SkillRunTextPiPController
    @StateObject private var presenter = SkillRunLiveStagePresenter()
    @State private var showDetail = false
    @State private var dragOffset: CGSize = .zero
    @State private var dragStart: CGSize?
    @Environment(\.accessibilityReduceMotion) private var reduceMotion

    private var mission: CLIAgentMissionSnapshot? {
        presenter.resolveMission(from: host.skillRunMissions)
    }

    private var missionKey: String {
        host.skillRunMissions.map { "\($0.id):\($0.status):\($0.events.count):\($0.deliveryMode.rawValue)" }.joined(separator: "|")
    }

    var body: some View {
        GeometryReader { proxy in
            ZStack(alignment: alignment(for: presenter.dockCorner)) {
                if let mission, presenter.isVisible {
                    SkillRunLiveStageTile(
                        mission: mission,
                        pipActive: pipController.isActive,
                        onOpen: { showDetail = true },
                        onPiP: { pipController.start(mission: mission) },
                        onDismiss: { presenter.dismiss(mission) },
                        onApprove: { Task { await host.respond(to: mission.id, approve: true) } },
                        onReject: { Task { await host.respond(to: mission.id, approve: false) } }
                    )
                    .frame(width: proxy.size.width > 700 ? 370 : 326)
                    .offset(dragOffset)
                    .padding(18)
                    .transition(.scale(scale: 0.72, anchor: .bottomLeading).combined(with: .opacity))
                    .gesture(dragGesture(in: proxy.size))
                }
            }
            .frame(maxWidth: .infinity, maxHeight: .infinity)
        }
        .allowsHitTesting(presenter.isVisible)
        .animation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.82), value: presenter.isVisible)
        .onAppear { presenter.reconcile(missions: host.skillRunMissions) }
        .onChange(of: missionKey) { _, _ in
            presenter.reconcile(missions: host.skillRunMissions)
            pipController.update(mission: mission)
        }
        .sheet(isPresented: $showDetail) {
            if let mission {
                MissionLiveDetailView(
                    mission: mission,
                    onApprovalResponse: { approve in
                        Task { await host.respond(to: mission.id, approve: approve) }
                    },
                    onFloat: { presenter.show(mission) },
                    onPictureInPicture: { pipController.start(mission: mission) }
                )
                .presentationDetents([.medium, .large])
            }
        }
    }

    private func alignment(for corner: SkillRunLiveStagePresenter.Corner) -> Alignment {
        switch corner {
        case .topLeading: return .topLeading
        case .topTrailing: return .topTrailing
        case .bottomLeading: return .bottomLeading
        case .bottomTrailing: return .bottomTrailing
        }
    }

    private func dragGesture(in size: CGSize) -> some Gesture {
        DragGesture(minimumDistance: 6)
            .onChanged { value in
                if dragStart == nil { dragStart = dragOffset }
                let start = dragStart ?? .zero
                dragOffset = CGSize(width: start.width + value.translation.width, height: start.height + value.translation.height)
            }
            .onEnded { value in
                dragStart = nil
                let corner = SkillRunLiveStagePresenter.nearestCorner(for: value.predictedEndLocation, in: size)
                withAnimation(reduceMotion ? .easeInOut(duration: 0.18) : .spring(response: 0.42, dampingFraction: 0.78)) {
                    presenter.snapDock(to: corner)
                    dragOffset = .zero
                }
            }
    }
}

private struct SkillRunLiveStageTile: View {
    let mission: CLIAgentMissionSnapshot
    let pipActive: Bool
    let onOpen: () -> Void
    let onPiP: () -> Void
    let onDismiss: () -> Void
    let onApprove: () -> Void
    let onReject: () -> Void

    var body: some View {
        VStack(alignment: .leading, spacing: 10) {
            HStack(spacing: 8) {
                Image(systemName: "sparkles")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                Text(mission.skillRunID?.displayName ?? "Skill Run")
                    .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                    .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                    .lineLimit(1)
                Spacer(minLength: 0)
                Button(action: onPiP) {
                    Image(systemName: pipActive ? "pip.fill" : "pip.enter")
                        .font(.system(size: 13, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(UnifiedDesignSystem.Colors.hermesAureate)
                .accessibilityLabel("Open Skill Run in Picture in Picture")
                Button(action: onDismiss) {
                    Image(systemName: "xmark")
                        .font(.system(size: 12, weight: .bold))
                }
                .buttonStyle(.plain)
                .foregroundStyle(UnifiedDesignSystem.Colors.textMuted)
                .accessibilityLabel("Dismiss floating Skill Run")
            }

            Button(action: onOpen) {
                VStack(alignment: .leading, spacing: 7) {
                    Text(mission.title)
                        .font(UnifiedDesignSystem.Typography.caption.weight(.semibold))
                        .foregroundStyle(UnifiedDesignSystem.Colors.textPrimary)
                        .lineLimit(2)
                    Text(mission.events.last?.displayMessage.nilIfEmpty ?? mission.displayLiveSummary?.nilIfEmpty ?? mission.currentStepLabel)
                        .font(UnifiedDesignSystem.Typography.tiny)
                        .foregroundStyle(UnifiedDesignSystem.Colors.textSecondary)
                        .lineLimit(3)
                    HStack(spacing: 7) {
                        SkillRunStagePill(text: mission.displayStatus.uppercased(), color: statusColor)
                        SkillRunStagePill(text: mission.deliveryMode.displayName, color: UnifiedDesignSystem.Colors.whimsy)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
            }
            .buttonStyle(.plain)

            if mission.isWaitingForApproval {
                HStack(spacing: 8) {
                    Button("Approve", action: onApprove)
                        .buttonStyle(.borderedProminent)
                        .tint(UnifiedDesignSystem.Colors.success)
                    Button("Reject", role: .destructive, action: onReject)
                        .buttonStyle(.bordered)
                }
                .font(UnifiedDesignSystem.Typography.tiny.weight(.semibold))
            }
        }
        .padding(14)
        .background(.ultraThinMaterial)
        .clipShape(RoundedRectangle(cornerRadius: 16, style: .continuous))
        .overlay(
            RoundedRectangle(cornerRadius: 16, style: .continuous)
                .stroke(borderColor.opacity(0.78), lineWidth: 1)
        )
        .shadow(color: .black.opacity(0.34), radius: 18, y: 10)
        .accessibilityElement(children: .combine)
        .accessibilityLabel("Floating Skill Run. \(mission.title). \(mission.displayStatus).")
    }

    private var statusColor: Color {
        if mission.isWaitingForApproval { return UnifiedDesignSystem.Colors.hermesAureate }
        if mission.isTerminal { return UnifiedDesignSystem.Colors.success }
        return UnifiedDesignSystem.Colors.ember
    }

    private var borderColor: Color {
        if mission.isWaitingForApproval { return UnifiedDesignSystem.Colors.hermesAureate }
        if mission.isTerminal { return UnifiedDesignSystem.Colors.success }
        return UnifiedDesignSystem.Colors.ember
    }
}

private struct SkillRunStagePill: View {
    let text: String
    let color: Color

    var body: some View {
        Text(text)
            .font(UnifiedDesignSystem.Typography.monoTiny.weight(.semibold))
            .foregroundStyle(color)
            .lineLimit(1)
            .padding(.horizontal, 8)
            .padding(.vertical, 4)
            .background(color.opacity(0.12))
            .clipShape(RoundedRectangle(cornerRadius: 8, style: .continuous))
    }
}
#endif

private extension String {
    var nilIfEmpty: String? { trimmingCharacters(in: .whitespacesAndNewlines).isEmpty ? nil : self }
}
