import AppKit
import SwiftUI

struct ChatScrollFollowState: Equatable {
    private(set) var followsLatest = true
    private(set) var isUserScrolling = false
    private var threadID: String?

    var shouldFollow: Bool { followsLatest && !isUserScrolling }

    mutating func userScrolled(distanceToBottom: CGFloat, isScrolling: Bool) {
        followsLatest = distanceToBottom.isFinite && distanceToBottom <= 64
        isUserScrolling = isScrolling
    }

    mutating func pause() { followsLatest = false }
    mutating func resume() {
        followsLatest = true
        isUserScrolling = false
    }

    mutating func switchThread(to threadID: String) {
        guard self.threadID != threadID else { return }
        self.threadID = threadID
        resume()
    }
}

/// AppKit supplies user-scroll provenance on macOS 14 as well as newer releases.
/// Content resizing and programmatic jumps must not disengage sticky-bottom.
struct ChatScrollViewportProbe: NSViewRepresentable {
    let onUserScroll: (CGFloat, Bool) -> Void

    func makeNSView(context: Context) -> ProbeView {
        let view = ProbeView()
        view.onUserScroll = onUserScroll
        return view
    }

    func updateNSView(_ nsView: ProbeView, context: Context) {
        nsView.onUserScroll = onUserScroll
        nsView.attachIfNeeded()
    }

    static func dismantleNSView(_ nsView: ProbeView, coordinator: ()) {
        nsView.detach()
    }

    final class ProbeView: NSView {
        var onUserScroll: ((CGFloat, Bool) -> Void)?
        private weak var observedScrollView: NSScrollView?
        private var observers: [NSObjectProtocol] = []
        private var isLiveScrolling = false

        override func hitTest(_ point: NSPoint) -> NSView? { nil }

        override func viewDidMoveToWindow() {
            super.viewDidMoveToWindow()
            attachIfNeeded()
        }

        override func viewDidMoveToSuperview() {
            super.viewDidMoveToSuperview()
            attachIfNeeded()
        }

        func attachIfNeeded() {
            guard let scrollView = enclosingScrollView else {
                detach()
                return
            }
            guard scrollView !== observedScrollView else { return }
            detach()
            observedScrollView = scrollView
            let center = NotificationCenter.default
            for name in [NSScrollView.willStartLiveScrollNotification, NSScrollView.didEndLiveScrollNotification] {
                observers.append(center.addObserver(forName: name, object: scrollView, queue: .main) { [weak self] _ in
                    MainActor.assumeIsolated {
                        self?.isLiveScrolling = name == NSScrollView.willStartLiveScrollNotification
                        self?.publish()
                    }
                })
            }
            observers.append(center.addObserver(
                forName: NSView.boundsDidChangeNotification,
                object: scrollView.contentView,
                queue: .main
            ) { [weak self] _ in
                MainActor.assumeIsolated {
                    guard let self,
                          self.isLiveScrolling || self.isUserScrollEvent else { return }
                    self.publish()
                }
            })
        }

        func detach() {
            for observer in observers { NotificationCenter.default.removeObserver(observer) }
            observers.removeAll()
            observedScrollView = nil
            isLiveScrolling = false
        }

        private var isUserScrollEvent: Bool {
            guard let event = NSApp.currentEvent, let scrollView = observedScrollView else { return false }
            if event.type == .scrollWheel {
                guard event.window === scrollView.window else { return false }
                return scrollView.bounds.contains(scrollView.convert(event.locationInWindow, from: nil))
            }
            guard event.type == .keyDown,
                  [49, 115, 116, 119, 121, 125, 126].contains(event.keyCode),
                  let responder = scrollView.window?.firstResponder as? NSView else { return false }
            // Space, Home/End, Page Up/Down, and arrows belong to the reader only
            // when focus is inside the transcript, not the composer.
            return responder === scrollView || responder.isDescendant(of: scrollView)
        }

        private func publish() {
            guard let scrollView = observedScrollView, let document = scrollView.documentView else { return }
            let viewport = scrollView.contentView.bounds
            let distance = document.isFlipped
                ? document.frame.maxY - viewport.maxY
                : viewport.minY - document.frame.minY
            onUserScroll?(max(0, distance), isLiveScrolling)
        }
    }
}
