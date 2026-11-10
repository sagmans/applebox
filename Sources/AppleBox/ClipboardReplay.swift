import AppKit
import OSLog
import SwiftUI

/// Keep ownership of the clipboard and the intended app tied to a single replay.
final class ClipboardReplay {
    private let workspace: WorkspaceProtocol
    private let pasteboard: PasteboardProtocol
    private let eventSource: EventSourceProtocol
    private let pasteDelay = DispatchTimeInterval.milliseconds(100)
    private let manualPasteMessage = "Copied. Press ⌘V to paste."
    private let permissionPasteMessage = "Copied. Allow AppleBox in Accessibility settings to paste automatically."
    private let copiedMessage = "Copied to Clipboard."
    private let changedClipboardMessage = "Clipboard changed before paste."
    private let copyFailureMessage = "Couldn't copy the clip. Try again."
    private let logger = Logger(
        subsystem: LogSubsystem.name,
        category: "clipboardReplay"
    )

    private var origin: NSRunningApplication?
    private var pendingPaste: DispatchWorkItem?
    private var feedback: ClipboardPasteFeedback?
    /// Asking on every paste would nag; once per launch is enough to put the app in the Accessibility list.
    private var requestedPostAccess = false

    init(workspace: WorkspaceProtocol, pasteboard: PasteboardProtocol, eventSource: EventSourceProtocol) {
        self.workspace = workspace
        self.pasteboard = pasteboard
        self.eventSource = eventSource
    }

    /// Capture focus before showing AppleBox so switching modes cannot replace the target.
    func begin() {
        pendingPaste?.cancel()
        pendingPaste = nil
        feedback?.hide()
        origin = workspace.frontmostApplication
    }

    func end() {
        origin = nil
    }

    func replay(_ item: ClipboardItem, pasteAutomatically: Bool = true, dismiss: () -> Void) {
        let representation = item.contentType == .text
            ? (data: Data(item.content.utf8), type: NSPasteboard.PasteboardType.string)
            : item.imageRepresentation()
        guard let representation else {
            logger.error("Cannot replay clipboard history image with invalid or unsupported data")
            showFeedback(copyFailureMessage, kind: .failure)
            return
        }

        guard let ownership = pasteboard.replayData(representation.data, forType: representation.type, source: item.sourceBundleID) else {
            logger.error("Clipboard history replay could not take pasteboard ownership")
            showFeedback(copyFailureMessage, kind: .failure)
            return
        }

        let target = origin
        dismiss()

        // Copy-only requires pasteboard ownership but no permission to send keyboard events.
        guard pasteAutomatically else {
            showFeedback(copiedMessage, kind: .confirmation)
            return
        }

        // Give AppKit time to return focus without activating a possibly stale target.
        let request = DispatchWorkItem { [weak self] in
            self?.requestPaste(to: target, ownership: ownership)
        }
        pendingPaste = request
        DispatchQueue.main.asyncAfter(deadline: .now() + pasteDelay, execute: request)
    }

    private func requestPaste(to target: NSRunningApplication?, ownership: Int) {
        pendingPaste = nil
        let canPost = eventSource.canPostPaste
        guard pasteboard.changeCount == ownership else {
            logger.debug("Clipboard history paste skipped after the clipboard changed")
            showFeedback(changedClipboardMessage, kind: .failure)
            return
        }

        guard canPost else {
            if !requestedPostAccess {
                requestedPostAccess = true
                eventSource.requestPostAccess()
            }
            logger.info("Clipboard history paste unavailable: no permission to post keyboard events")
            showFeedback(permissionPasteMessage, kind: .guidance)
            return
        }

        guard let target,
              !target.isTerminated,
              target.processIdentifier > 0,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              target.isEqual(workspace.frontmostApplication),
              eventSource.postPaste(to: target.processIdentifier)
        else {
            logger.info("Clipboard history paste unavailable: no verified target; the clip is available for manual paste")
            showFeedback(manualPasteMessage, kind: .confirmation)
            return
        }
        logger.debug("Requested paste in the originating app")
    }

    private func showFeedback(_ message: String, kind: PasteToastKind) {
        let feedback = feedback ?? ClipboardPasteFeedback()
        self.feedback = feedback
        feedback.show(message, kind: kind)
    }
}

/// Keep fallback instructions visible without taking focus from the destination.
private final class ClipboardPasteFeedback {
    private let bottomInset: CGFloat = 32
    private let state = PasteToastState()
    private let host: NSHostingView<PasteToastView>
    private let panel = NSPanel(
        contentRect: .zero,
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var dismissal: Task<Void, Never>?

    init() {
        host = NSHostingView(rootView: PasteToastView(state: state))
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        // The glass capsule is not rectangular, so a window shadow or background would show square corners.
        panel.isOpaque = false
        panel.backgroundColor = .clear
        panel.hasShadow = false
        panel.contentView = host
    }

    func show(_ message: String, kind: PasteToastKind) {
        hide()
        guard let frame = NSScreen.main?.visibleFrame else { return }
        state.message = message
        state.kind = kind

        // The panel must fit the wrapped text. The observed message reaches the view only on its next
        // update, so layout is forced first; otherwise the previous message's size would be measured.
        host.layoutSubtreeIfNeeded()
        let size = host.fittingSize
        panel.setContentSize(size)
        panel.setFrameOrigin(NSPoint(x: frame.midX - size.width / 2, y: frame.minY + bottomInset))

        // The launcher hides the application during replay. The notice must not restore focus.
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        panel.orderFrontRegardless()
        state.visible = true
        if kind == .confirmation {
            state.bounces &+= 1
        }

        // VoiceOver users get no focus change from a non-activating panel, so the notice is announced.
        NSAccessibility.post(
            element: NSApp as Any,
            notification: .announcementRequested,
            userInfo: [.announcement: message, .priority: NSAccessibilityPriorityLevel.high.rawValue]
        )

        dismissal = Task { @MainActor [weak self] in
            // Cancellation is the normal way out (a newer notice or `hide()`), so the sleep's error carries
            // nothing to log; the guard below stops the fade.
            try? await Task.sleep(for: kind.lifetime)
            guard !Task.isCancelled else { return }
            await self?.fadeOut()
        }
    }

    /// Fades first so the notice never vanishes abruptly, then removes the panel once the fade is done.
    private func fadeOut() async {
        state.visible = false
        // Cancelled only when a new notice takes over, which the guard below handles.
        try? await Task.sleep(for: .seconds(PasteToastMetrics.fadeOut))
        guard !Task.isCancelled, !state.visible else { return }
        panel.orderOut(nil)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        state.visible = false
        panel.orderOut(nil)
    }
}
