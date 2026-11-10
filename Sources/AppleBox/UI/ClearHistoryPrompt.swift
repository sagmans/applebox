import AppKit

/// Confirms wiping clipboard history, because the removal cannot be undone.
///
/// A sheet on the launcher panel, not a free-standing alert: a sheet keeps the panel open (the controller
/// ignores resign-key while one is attached) and ties the question to the window the user is looking at.
enum ClearHistoryPrompt {
    /// Presents the sheet over `window`. Does nothing when the launcher is not in clipboard mode or a
    /// sheet is already up, so a double click or repeated menu choice cannot stack prompts.
    static func present(for model: LauncherModel, over window: NSWindow?) {
        guard model.mode == .clipboard, let window, window.attachedSheet == nil else { return }
        let alert = NSAlert()
        alert.messageText = DesignTokens.Copy.clearHistoryTitle
        alert.informativeText = DesignTokens.Copy.clearHistoryExplanation
        // Return chooses Cancel so a repeated keypress cannot erase the archive.
        alert.addButton(withTitle: DesignTokens.Copy.cancel).keyEquivalent = CopyClipShortcut.key
        alert.addButton(withTitle: DesignTokens.Copy.clearHistoryButton).hasDestructiveAction = true
        alert.beginSheetModal(for: window) { [weak model] response in
            guard response == .alertSecondButtonReturn else { return }
            model?.clearHistory()
        }
    }

    /// The launcher panel, found by type because SwiftUI menu actions have no handle to their window.
    @MainActor
    static var launcherWindow: NSWindow? {
        NSApp.windows.first { $0 is LauncherPanel }
    }
}
