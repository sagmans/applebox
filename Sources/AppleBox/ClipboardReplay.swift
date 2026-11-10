import AppKit
import OSLog

/// Keep ownership of the clipboard and the intended app tied to a single replay.
final class ClipboardReplay {
    private let workspace: WorkspaceProtocol
    private let pasteboard: PasteboardProtocol
    private let eventSource: EventSourceProtocol
    private let pasteDelay = DispatchTimeInterval.milliseconds(100)
    private let manualPasteMessage = "Copied. Press ⌘V to paste."
    private let copiedMessage = "Copied to Clipboard."
    private let changedClipboardMessage = "Clipboard changed before paste."
    private let copyFailureMessage = "Couldn't copy the clip. Try again."
    private let logger = Logger(
        subsystem: Bundle.main.bundleIdentifier ?? "com.assagman.applebox",
        category: "clipboardReplay"
    )

    private var origin: NSRunningApplication?
    private var pendingPaste: DispatchWorkItem?
    private var feedback: ClipboardPasteFeedback?

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
            showFeedback(copyFailureMessage)
            return
        }

        guard let ownership = pasteboard.replayData(representation.data, forType: representation.type) else {
            logger.error("Clipboard history replay could not take pasteboard ownership")
            showFeedback(copyFailureMessage)
            return
        }

        let target = origin
        dismiss()

        // Copy-only requires pasteboard ownership but no permission to send keyboard events.
        guard pasteAutomatically else {
            showFeedback(copiedMessage)
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
            showFeedback(changedClipboardMessage)
            return
        }

        guard canPost,
              let target,
              !target.isTerminated,
              target.processIdentifier > 0,
              target.processIdentifier != ProcessInfo.processInfo.processIdentifier,
              target.isEqual(workspace.frontmostApplication),
              eventSource.postPaste(to: target.processIdentifier)
        else {
            logger.debug("Clipboard history paste unavailable; the clip is available for manual paste")
            showFeedback(manualPasteMessage)
            return
        }
        logger.debug("Requested paste in the originating app")
    }

    private func showFeedback(_ message: String) {
        let feedback = feedback ?? ClipboardPasteFeedback()
        self.feedback = feedback
        feedback.show(message)
    }
}

/// Keep fallback instructions visible without taking focus from the destination.
private final class ClipboardPasteFeedback {
    private static let size = NSSize(width: 300, height: 44)
    private let bottomInset: CGFloat = 32
    private let lifetime = DispatchTimeInterval.seconds(3)
    private let label = NSTextField(labelWithString: "")
    private let panel = NSPanel(
        contentRect: NSRect(origin: .zero, size: size),
        styleMask: [.borderless, .nonactivatingPanel],
        backing: .buffered,
        defer: false
    )
    private var dismissal: DispatchWorkItem?

    init() {
        panel.level = .floating
        panel.ignoresMouseEvents = true
        panel.hidesOnDeactivate = false
        panel.hasShadow = true
        label.alignment = .center
        label.translatesAutoresizingMaskIntoConstraints = false

        if let content = panel.contentView {
            content.addSubview(label)
            NSLayoutConstraint.activate([
                label.centerXAnchor.constraint(equalTo: content.centerXAnchor),
                label.centerYAnchor.constraint(equalTo: content.centerYAnchor),
            ])
        }
    }

    func show(_ message: String) {
        hide()
        guard let frame = NSScreen.main?.visibleFrame else { return }
        label.stringValue = message
        panel.setFrameOrigin(NSPoint(x: frame.midX - Self.size.width / 2, y: frame.minY + bottomInset))

        // The launcher hides the application during replay. The notice must not restore focus.
        if NSApp.isHidden {
            NSApp.unhideWithoutActivation()
        }
        panel.orderFrontRegardless()

        let dismissal = DispatchWorkItem { [weak self] in self?.hide() }
        self.dismissal = dismissal
        DispatchQueue.main.asyncAfter(deadline: .now() + lifetime, execute: dismissal)
    }

    func hide() {
        dismissal?.cancel()
        dismissal = nil
        panel.orderOut(nil)
    }
}
