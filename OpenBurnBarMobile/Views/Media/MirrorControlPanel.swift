// Floating mirror control panel: tray, docks, and action groups.
// Extracted from ScreenShareViewerView.swift (behavior-preserving split).
import SwiftUI
@preconcurrency import AVKit
@preconcurrency import MediaPlayer
#if canImport(UIKit)
import UIKit
#endif
import OpenBurnBarMedia
import OpenBurnBarCore
import OpenBurnBarComputerUseCore

private struct DragOption {
    let icon: String
    let label: String
    let disabled: Bool
    let action: () -> Void
}

struct MirrorControlPanel: View {
    @Binding var interactionMode: ScreenShareInteractionMode
    @Binding var isCollapsed: Bool
    @Binding var isTyping: Bool
    @Binding var coPilotTarget: (normalizedX: Double, normalizedY: Double, viewPoint: CGPoint)?
    @Binding var edgeScrollEnabled: Bool
    @Binding var hardwareScrollEnabled: Bool
    @Binding var statsVisible: Bool
    @Binding var cursorSize: CGFloat
    @Binding var cursorStyle: MirrorCursorStyle
    let stats: ScreenShareViewerCoordinator.Stats
    let controlStatus: ScreenSharePhoneControlStatus
    let controlInputEnabled: Bool
    let displays: [HermesRealtimeRelayDisplayDescriptor]
    let selectedDisplayId: String?
    let isZoomed: Bool
    let smartZoomMode: SmartZoomMode
    let smartZoomAutoFollowing: Bool
    let setSmartZoomMode: (SmartZoomMode) -> Void
    let zoomIn: () -> Void
    let zoomOut: () -> Void
    let resetZoom: () -> Void
    let focusTyping: () -> Void
    let selectDisplay: (String) -> Void
    let onTrustControlDevice: () -> Void
    let sendScrollButton: (Double) -> Void
    let pasteClipboardToMac: () -> Void
    let grabClipboardFromMac: () -> Void
    let onClose: () -> Void
    let screenSize: CGSize

    @State private var tooltip: String?

    // New tray states
    @State private var trayExpanded = false
    @State private var expansionDirection: ExpansionDirection = .upward
    @State private var activeDragGroup: MirrorControlGroup?
    @State private var hoveredOptionIndex: Int?
    @State private var gestureStartTime = Date()

    // Floating pill states
    @State private var pillOffset: CGSize = .zero
    @State private var activeDragOffset: CGSize = .zero

    enum ExpansionDirection: String, CaseIterable, Sendable {
        case upward
        case sideways
    }

    private enum MirrorControlGroup: String, CaseIterable, Identifiable {
        case mode, zoom, scroll, keyboard, screen
        var id: String { rawValue }

        var title: String {
            switch self {
            case .mode: return "Mode"
            case .zoom: return "Zoom"
            case .scroll: return "Scroll"
            case .keyboard: return "Keys"
            case .screen: return "Screen"
            }
        }

        var hint: String {
            switch self {
            case .mode: return "Interaction mode — cycle on tap, hold for options"
            case .zoom: return "Zoom and Smart Zoom — cycle on tap, hold for options"
            case .scroll: return "Scroll and paging — cycle on tap, hold for options"
            case .keyboard: return "Keyboard and clipboard — cycle on tap, hold for options"
            case .screen: return "Display and stats — cycle on tap, hold for options"
            }
        }

        var icon: String {
            switch self {
            case .mode: return "hand.draw"
            case .zoom: return "arrow.up.left.and.down.right.magnifyingglass"
            case .scroll: return "arrow.up.arrow.down"
            case .keyboard: return "keyboard"
            case .screen: return "macwindow"
            }
        }
    }

    var body: some View {
        VStack(alignment: .center, spacing: 10) {
            statusStrip
            
            if trayExpanded {
                if expansionDirection == .sideways {
                    sidewaysDock
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .opacity
                        ))
                } else {
                    upwardDock
                        .transition(.asymmetric(
                            insertion: .scale(scale: 0.85).combined(with: .opacity),
                            removal: .opacity
                        ))
                }
            } else {
                collapsedHandle
                    .transition(.asymmetric(
                        insertion: .opacity,
                        removal: .scale(scale: 0.85).combined(with: .opacity)
                    ))
            }
        }
        .overlay(alignment: .top) { tooltipBubble }
        .offset(clampOffset(pillOffset + activeDragOffset))
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: trayExpanded)
        .animation(.spring(response: 0.35, dampingFraction: 0.7), value: expansionDirection)
        .onChange(of: trayExpanded) { _, newValue in
            isCollapsed = !newValue
        }
        .onChange(of: isCollapsed) { _, newValue in
            if trayExpanded == newValue {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    trayExpanded = !newValue
                }
            }
        }
        .onAppear {
            isCollapsed = !trayExpanded
        }
        .task(id: tooltip) {
            guard tooltip != nil else { return }
            try? await Task.sleep(nanoseconds: 2_600_000_000)
            withAnimation(.easeOut(duration: 0.2)) { tooltip = nil }
        }
    }

    private func clampOffset(_ offset: CGSize) -> CGSize {
        let minX = -screenSize.width / 2 + 60
        let maxX = screenSize.width / 2 - 60
        let minY = -screenSize.height + 140
        let maxY = 10.0
        
        return CGSize(
            width: min(max(offset.width, minX), maxX),
            height: min(max(offset.height, minY), maxY)
        )
    }

    private var dockDragToCollapseGesture: some Gesture {
        DragGesture(minimumDistance: 20)
            .onChanged { value in
                if value.translation.height > 35 {
                    withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                        trayExpanded = false
                    }
                }
            }
    }

    // MARK: - Collapsed Handle
    private var collapsedHandle: some View {
        HStack(spacing: 8) {
            // Chevron: draggable upwards or tappable to expand vertically
            Image(systemName: "chevron.up")
                .font(.system(size: 15, weight: .black))
                .foregroundStyle(.white)
                .frame(width: 44, height: 44)
                .background(Color.white.opacity(0.12), in: Circle())
                .contentShape(Circle())
                .gesture(
                    DragGesture(minimumDistance: 4)
                        .onChanged { value in
                            let dy = value.translation.height
                            if dy < -8 { // Dragging upwards to the top
                                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                                    expansionDirection = .upward
                                    trayExpanded = true
                                }
                            }
                        }
                )
                .simultaneousGesture(
                    TapGesture().onEnded {
                        withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                            expansionDirection = .upward
                            trayExpanded = true
                        }
                    }
                )

            // Cog: cutely colored settings cog that opens the panel sideways on tap
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    expansionDirection = .sideways
                    trayExpanded = true
                }
            } label: {
                Image(systemName: "gearshape.fill")
                    .font(.system(size: 16, weight: .bold))
                    .foregroundStyle(
                        LinearGradient(
                            colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                            startPoint: .topLeading,
                            endPoint: .bottomTrailing
                        )
                    )
                    .frame(width: 44, height: 44)
                    .background(Color.white.opacity(0.08), in: Circle())
                    .overlay(
                        Circle()
                            .stroke(
                                LinearGradient(
                                    colors: [Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.4), Color(red: 0.56, green: 0.50, blue: 0.85).opacity(0.4)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1
                            )
                    )
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 6)
        .mirrorGlassBackground(cornerRadius: 28)
        .shadow(color: .black.opacity(0.3), radius: 12, x: 0, y: 6)
        .gesture(
            DragGesture()
                .onChanged { value in
                    activeDragOffset = value.translation
                }
                .onEnded { value in
                    pillOffset = clampOffset(pillOffset + value.translation)
                    activeDragOffset = .zero
                }
        )
    }

    // MARK: - Sideways Dock (Horizontal)
    private var sidewaysDock: some View {
        HStack(spacing: 10) {
            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    trayExpanded = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)

            ForEach(MirrorControlGroup.allCases) { group in
                interactiveGroupButton(group)
            }

            Spacer(minLength: 6)

            Button(action: onClose) {
                railIcon("xmark", selected: false, disabled: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close mirror")
            .accessibilityHint("Disconnect and close the mirror")
            .help("Close mirror")
            .simultaneousGesture(longPress("Close mirror and disconnect"))
        }
        .padding(.horizontal, 10)
        .padding(.vertical, 8)
        .frame(maxWidth: .infinity)
        .mirrorGlassBackground(cornerRadius: 24)
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror controls")
        .gesture(dockDragToCollapseGesture)
    }

    // MARK: - Upward Dock (Vertical)
    private var upwardDock: some View {
        VStack(spacing: 10) {
            Button(action: onClose) {
                railIcon("xmark", selected: false, disabled: false)
            }
            .buttonStyle(.plain)
            .accessibilityLabel("Close mirror")
            .accessibilityHint("Disconnect and close the mirror")
            .help("Close mirror")
            .simultaneousGesture(longPress("Close mirror and disconnect"))

            ForEach(MirrorControlGroup.allCases) { group in
                interactiveGroupButton(group)
            }

            Button {
                withAnimation(.spring(response: 0.35, dampingFraction: 0.7)) {
                    trayExpanded = false
                }
            } label: {
                Image(systemName: "chevron.down")
                    .font(.system(size: 14, weight: .bold))
                    .foregroundStyle(.white.opacity(0.7))
                    .frame(width: 42, height: 42)
            }
            .buttonStyle(.plain)
        }
        .padding(.horizontal, 8)
        .padding(.vertical, 10)
        .mirrorGlassBackground(cornerRadius: 24)
        .shadow(color: .black.opacity(0.30), radius: 18, x: 0, y: 10)
        .accessibilityElement(children: .contain)
        .accessibilityLabel("Mirror controls")
        .gesture(dockDragToCollapseGesture)
    }

    // MARK: - Interactive Group Button & Gestures
    private func handleDragChanged(_ value: DragGesture.Value, for group: MirrorControlGroup) {
        if activeDragGroup == nil {
            activeDragGroup = group
            gestureStartTime = Date()
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }
        
        let list = options(for: group)
        if expansionDirection == .sideways {
            let index = Int((-value.translation.height - 30) / 48)
            if index >= 0 && index < list.count {
                if hoveredOptionIndex != index {
                    hoveredOptionIndex = index
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                }
            } else {
                hoveredOptionIndex = nil
            }
        } else {
            let index = Int((-value.translation.width - 30) / 72)
            if index >= 0 && index < list.count {
                if hoveredOptionIndex != index {
                    hoveredOptionIndex = index
                    #if canImport(UIKit)
                    UIImpactFeedbackGenerator(style: .light).impactOccurred()
                    #endif
                }
            } else {
                hoveredOptionIndex = nil
            }
        }
    }

    private func handleDragEnded(_ value: DragGesture.Value, for group: MirrorControlGroup) {
        let duration = Date().timeIntervalSince(gestureStartTime)
        let distance = sqrt(pow(value.translation.width, 2) + pow(value.translation.height, 2))
        
        if duration < 0.3 && distance < 15 {
            switch group {
            case .mode: cycleMode()
            case .zoom: cycleZoom()
            case .scroll: cycleScroll()
            case .keyboard: cycleKeyboard()
            case .screen: cycleScreen()
            }
        } else if let index = hoveredOptionIndex {
            let list = options(for: group)
            if index >= 0 && index < list.count {
                let item = list[index]
                if !item.disabled {
                    item.action()
                    #if canImport(UIKit)
                    UINotificationFeedbackGenerator().notificationOccurred(.success)
                    #endif
                }
            }
        }
        
        withAnimation(.snappy(duration: 0.2)) {
            activeDragGroup = nil
            hoveredOptionIndex = nil
        }
    }

    private func interactiveGroupButton(_ group: MirrorControlGroup) -> some View {
        let isDraggingThis = activeDragGroup == group
        return ZStack {
            railIcon(
                group == .mode ? activeModeIcon : group.icon,
                selected: isDraggingThis || groupActive(group),
                disabled: false
            )
            .background(
                Color.white.opacity(0.001)
            )
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { handleDragChanged($0, for: group) }
                    .onEnded { handleDragEnded($0, for: group) }
            )
        }
        .overlay(alignment: expansionDirection == .sideways ? .bottom : .trailing) {
            if isDraggingThis {
                popOutHUD(for: group)
                    .transition(.opacity.combined(with: .scale(scale: 0.95)))
            }
        }
    }

    // MARK: - Pop Out Option List & UI
    @ViewBuilder
    private func popOutItemBackground(isHovered: Bool, disabled: Bool) -> some View {
        if isHovered {
            if #available(iOS 26.0, *) {
                // The pop-out plate is already Liquid Glass; a material fill on
                // top would block its refraction. The hover highlight rides on
                // the glass as a translucent wash instead.
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(Color.white.opacity(0.16))
            } else {
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .fill(.ultraThinMaterial)
            }
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .stroke(
                    LinearGradient(
                        colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                        startPoint: .topLeading,
                        endPoint: .bottomTrailing
                    ),
                    lineWidth: 1.5
                )
        } else {
            RoundedRectangle(cornerRadius: 10, style: .continuous)
                .fill(Color.white.opacity(disabled ? 0.02 : 0.06))
        }
    }

    @ViewBuilder
    private func popOutHUD(for group: MirrorControlGroup) -> some View {
        let list = options(for: group)
        if expansionDirection == .sideways {
            VStack(spacing: 8) {
                ForEach(0..<list.count, id: \.self) { i in
                    let item = list[i]
                    let isHovered = hoveredOptionIndex == i
                    HStack(spacing: 8) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .bold))
                        Text(item.label)
                            .font(.system(size: 11, weight: .bold, design: .rounded))
                    }
                    .foregroundStyle(isHovered ? .white : .white.opacity(item.disabled ? 0.35 : 0.85))
                    .padding(.horizontal, 12)
                    .frame(height: 40)
                    .background(
                        popOutItemBackground(isHovered: isHovered, disabled: item.disabled)
                    )
                    .scaleEffect(isHovered ? 1.05 : 1.0)
                }
            }
            .padding(6)
            .mirrorGlassBackground(cornerRadius: 16)
            .shadow(color: .black.opacity(0.35), radius: 10)
            .offset(y: -CGFloat(list.count * 48 + 10))
        } else {
            HStack(spacing: 8) {
                ForEach(0..<list.count, id: \.self) { i in
                    let item = list[i]
                    let isHovered = hoveredOptionIndex == i
                    VStack(spacing: 4) {
                        Image(systemName: item.icon)
                            .font(.system(size: 14, weight: .bold))
                        Text(item.label)
                            .font(.system(size: 9, weight: .bold, design: .rounded))
                            .lineLimit(1)
                    }
                    .foregroundStyle(isHovered ? .white : .white.opacity(item.disabled ? 0.35 : 0.85))
                    .padding(.vertical, 6)
                    .frame(width: 64, height: 50)
                    .background(
                        popOutItemBackground(isHovered: isHovered, disabled: item.disabled)
                    )
                    .scaleEffect(isHovered ? 1.05 : 1.0)
                }
            }
            .padding(6)
            .mirrorGlassBackground(cornerRadius: 16)
            .shadow(color: .black.opacity(0.35), radius: 10)
            .offset(x: -CGFloat(list.count * 72 + 10))
        }
    }

    // MARK: - Action Options Map
    private func options(for group: MirrorControlGroup) -> [DragOption] {
        switch group {
        case .mode:
            return [
                DragOption(icon: "hand.draw", label: "View Mode", disabled: false) {
                    interactionMode = .view
                    isTyping = false
                },
                DragOption(icon: "cursorarrow.click.2", label: controlStatus.label, disabled: !controlInputEnabled) {
                    interactionMode = .control
                    isTyping = false
                },
                DragOption(icon: "rectangle.and.hand.point.up.left", label: "Trackpad Mode", disabled: !controlInputEnabled) {
                    interactionMode = .trackpad
                    isTyping = false
                },
                DragOption(icon: "target", label: "Co-Pilot", disabled: !controlInputEnabled) {
                    interactionMode = .coPilot
                    isTyping = false
                    coPilotTarget = nil
                }
            ]
        case .zoom:
            var list = [
                DragOption(icon: "plus.magnifyingglass", label: "Zoom In", disabled: false) {
                    zoomIn()
                },
                DragOption(icon: "minus.magnifyingglass", label: "Zoom Out", disabled: !isZoomed) {
                    zoomOut()
                }
            ]
            if isZoomed {
                list.append(DragOption(icon: "arrow.counterclockwise", label: "Reset Zoom", disabled: false) {
                    resetZoom()
                })
            }
            list.append(DragOption(icon: "sparkles", label: "Smart Zoom", disabled: false) {
                let nextMode: SmartZoomMode = (smartZoomMode == .off) ? .smart : .off
                setSmartZoomMode(nextMode)
            })
            return list
        case .scroll:
            return [
                DragOption(icon: "chevron.up", label: "Scroll Up", disabled: !controlInputEnabled) {
                    sendScrollButton(-0.22)
                },
                DragOption(icon: "chevron.down", label: "Scroll Down", disabled: !controlInputEnabled) {
                    sendScrollButton(0.22)
                },
                DragOption(icon: "arrow.up.to.line", label: "Page Up", disabled: !controlInputEnabled) {
                    sendScrollButton(-0.45)
                },
                DragOption(icon: "arrow.down.to.line", label: "Page Down", disabled: !controlInputEnabled) {
                    sendScrollButton(0.45)
                },
                DragOption(icon: "arrow.left.and.right", label: edgeScrollEnabled ? "Disable Edge" : "Enable Edge", disabled: false) {
                    edgeScrollEnabled.toggle()
                },
                DragOption(icon: "speaker.wave.2", label: hardwareScrollEnabled ? "Disable Vol" : "Enable Vol", disabled: false) {
                    hardwareScrollEnabled.toggle()
                }
            ]
        case .keyboard:
            return [
                DragOption(icon: "keyboard", label: "Keyboard", disabled: !controlInputEnabled) {
                    interactionMode = .control
                    isTyping.toggle()
                    if isTyping { focusTyping() }
                },
                DragOption(icon: "doc.on.clipboard", label: "Paste to Mac", disabled: !controlInputEnabled) {
                    pasteClipboardToMac()
                },
                DragOption(icon: "arrow.down.doc", label: "Copy from Mac", disabled: !controlInputEnabled) {
                    grabClipboardFromMac()
                }
            ]
        case .screen:
            var list: [DragOption] = []
            if displayOptions.count > 1 {
                list.append(DragOption(icon: "rectangle.connected.to.line.below", label: "Switch Display", disabled: false) {
                    let nextIndex = (selectedDisplayIndex + 1) % displayOptions.count
                    selectDisplay(displayOptions[nextIndex].id)
                })
            }
            list.append(DragOption(icon: "cursorarrow", label: "Cursor Style", disabled: false) {
                let nextStyle: MirrorCursorStyle
                switch cursorStyle {
                case .hidden: nextStyle = .mercury
                case .mercury: nextStyle = .ember
                case .ember: nextStyle = .aurora
                case .aurora: nextStyle = .white
                case .white: nextStyle = .hidden
                }
                cursorStyle = nextStyle
            })
            list.append(DragOption(icon: "waveform.path.ecg", label: statsVisible ? "Hide Stats" : "Show Stats", disabled: false) {
                statsVisible.toggle()
            })
            return list
        }
    }

    // MARK: - Option Cycling helpers
    private func cycleMode() {
        let modes: [ScreenShareInteractionMode]
        if controlInputEnabled {
            modes = [.view, .control, .trackpad, .coPilot]
        } else {
            modes = [.view]
        }
        if let index = modes.firstIndex(of: interactionMode) {
            let nextIndex = (index + 1) % modes.count
            withAnimation(.snappy) {
                interactionMode = modes[nextIndex]
                isTyping = false
                if interactionMode == .coPilot {
                    coPilotTarget = nil
                }
            }
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }
    }

    private func cycleZoom() {
        let modes: [SmartZoomMode] = [.off, .smart, .text, .window, .cursor]
        if let index = modes.firstIndex(of: smartZoomMode) {
            let nextIndex = (index + 1) % modes.count
            setSmartZoomMode(modes[nextIndex])
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }
    }

    private func cycleScroll() {
        if !edgeScrollEnabled && !hardwareScrollEnabled {
            edgeScrollEnabled = true
        } else if edgeScrollEnabled && !hardwareScrollEnabled {
            edgeScrollEnabled = false
            hardwareScrollEnabled = true
        } else if !edgeScrollEnabled && hardwareScrollEnabled {
            edgeScrollEnabled = true
            hardwareScrollEnabled = true
        } else {
            edgeScrollEnabled = false
            hardwareScrollEnabled = false
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func cycleKeyboard() {
        guard controlInputEnabled else { return }
        if !isTyping {
            withAnimation(.snappy) {
                interactionMode = .control
                isTyping = true
            }
            focusTyping()
        } else {
            withAnimation(.snappy) {
                isTyping = false
            }
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    private func cycleScreen() {
        if displayOptions.count > 1 {
            let nextIndex = (selectedDisplayIndex + 1) % displayOptions.count
            selectDisplay(displayOptions[nextIndex].id)
        } else {
            statsVisible.toggle()
        }
        #if canImport(UIKit)
        UIImpactFeedbackGenerator(style: .light).impactOccurred()
        #endif
    }

    // MARK: - State queries & view assets
    private func groupActive(_ group: MirrorControlGroup) -> Bool {
        switch group {
        case .mode: return interactionMode != .view
        case .zoom: return isZoomed || smartZoomMode != .off
        case .scroll: return edgeScrollEnabled || hardwareScrollEnabled
        case .keyboard: return isTyping
        case .screen: return statsVisible || cursorStyle != .hidden
        }
    }

    private var fallbackDisplays: [HermesRealtimeRelayDisplayDescriptor] {
        [HermesRealtimeRelayDisplayDescriptor(id: selectedDisplayId ?? "main", name: "Main Display", width: 0, height: 0, isPrimary: true)]
    }

    private var activeModeIcon: String {
        switch interactionMode {
        case .view:
            return "hand.draw"
        case .coPilot:
            return "target"
        case .control:
            return controlInputEnabled ? "cursorarrow.click.2" : "lock"
        case .trackpad:
            return "rectangle.and.hand.point.up.left"
        }
    }

    private var displayOptions: [HermesRealtimeRelayDisplayDescriptor] {
        displays.isEmpty ? fallbackDisplays : displays
    }

    private var selectedDisplayIndex: Int {
        displayOptions.firstIndex {
            $0.id == selectedDisplayId || (selectedDisplayId == nil && $0.isPrimary)
        } ?? 0
    }

    private func longPress(_ text: String) -> some Gesture {
        LongPressGesture(minimumDuration: 0.35).onEnded { _ in
            withAnimation(.snappy(duration: 0.2)) { tooltip = text }
            #if canImport(UIKit)
            UIImpactFeedbackGenerator(style: .light).impactOccurred()
            #endif
        }
    }

    private var tooltipBubble: some View {
        Group {
            if let tooltip {
                Text(tooltip)
                    .font(.system(size: 13, weight: .semibold, design: .rounded))
                    .foregroundStyle(.white)
                    .multilineTextAlignment(.center)
                    .padding(.horizontal, 14)
                    .padding(.vertical, 9)
                    .liquidGlassSurface(in: Capsule())
                    .overlay(Capsule().stroke(Color.white.opacity(0.18), lineWidth: 1))
                    .shadow(color: .black.opacity(0.4), radius: 12, x: 0, y: 4)
                    .frame(maxWidth: 300)
                    .fixedSize(horizontal: false, vertical: true)
                    .offset(y: -54)
                    .transition(.scale(scale: 0.85, anchor: .bottom).combined(with: .opacity))
                    .allowsHitTesting(false)
            }
        }
    }

    private var statusStrip: some View {
        Group {
            if statsVisible || controlStatus.detail != nil {
                HStack(spacing: 8) {
                    if statsVisible {
                        compactStats
                    }
                    if let detail = controlStatus.detail {
                        compactControlStatus(detail)
                    }
                }
                .frame(maxWidth: .infinity, alignment: .leading)
                .transition(.opacity)
            }
        }
    }

    private var compactStats: some View {
        let mbps = Double(stats.bitsPerSecond) / 1_000_000.0
        return HStack(spacing: 8) {
            Text(String(format: "%.2f Mbps", mbps))
            Text("RTT \(stats.roundTripMillis) ms")
        }
        .font(.system(size: 12, weight: .semibold, design: .monospaced))
        .foregroundStyle(.white.opacity(0.86))
        .padding(.horizontal, 12)
        .frame(height: 40)
        .background(Color.white.opacity(0.10), in: Capsule())
    }

    private func compactControlStatus(_ message: String) -> some View {
        Text(shortControlMessage(message))
            .font(.system(size: 12, weight: .semibold, design: .rounded))
            .foregroundStyle(.white.opacity(0.86))
            .lineLimit(1)
            .minimumScaleFactor(0.75)
            .padding(.horizontal, 12)
            .frame(height: 40)
            .background(Color.white.opacity(0.10), in: Capsule())
    }

    private func shortControlMessage(_ message: String) -> String {
        guard message.count > 72 else { return message }
        return String(message.prefix(69)) + "..."
    }

    private func railIcon(_ systemName: String, selected: Bool, disabled: Bool) -> some View {
        Image(systemName: systemName)
            .font(.system(size: 15, weight: .bold))
            .foregroundStyle(selected ? .white : .white.opacity(disabled ? 0.35 : 0.85))
            .frame(width: 42, height: 42)
            .background(
                ZStack {
                    if selected {
                        if #available(iOS 26.0, *) {
                            // Rail icons sit on a Liquid Glass dock plate; the
                            // selected state stays a translucent wash so the
                            // glass underneath keeps refracting.
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(Color.white.opacity(0.18))
                        } else {
                            RoundedRectangle(cornerRadius: 12, style: .continuous)
                                .fill(.ultraThinMaterial)
                        }
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(
                                LinearGradient(
                                    colors: [Color(red: 0.17, green: 0.79, blue: 0.75), Color(red: 0.56, green: 0.50, blue: 0.85)],
                                    startPoint: .topLeading,
                                    endPoint: .bottomTrailing
                                ),
                                lineWidth: 1.5
                            )
                            .shadow(color: Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.5), radius: 6)
                    } else {
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .fill(Color.white.opacity(disabled ? 0.03 : 0.08))
                        RoundedRectangle(cornerRadius: 12, style: .continuous)
                            .stroke(Color.white.opacity(0.12), lineWidth: 1)
                    }
                }
            )
            .shadow(color: selected ? Color(red: 0.17, green: 0.79, blue: 0.75).opacity(0.15) : Color.black.opacity(0.1), radius: 4)
    }
}
