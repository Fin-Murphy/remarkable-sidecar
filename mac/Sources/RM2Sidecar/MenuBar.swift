import AppKit

final class MenuBar: NSObject, NSMenuDelegate {
    private let sidecar: Sidecar
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility (pen input)…",
                                               action: #selector(openAccessibility), keyEquivalent: "")
    private let screenRecordingItem = NSMenuItem(title: "Grant Screen Recording…",
                                                 action: #selector(openScreenRecording), keyEquivalent: "")

    init(sidecar: Sidecar) {
        self.sidecar = sidecar
        super.init()
        item.button?.title = "rM2 ○"

        let menu = NSMenu()
        menu.delegate = self
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(screenRecordingItem)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Connect", action: #selector(connect), keyEquivalent: "").target = self
        menu.addItem(withTitle: "Disconnect", action: #selector(disconnect), keyEquivalent: "").target = self
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        accessibilityItem.target = self
        screenRecordingItem.target = self
        item.menu = menu
    }

    func setStatus(_ status: String) {
        statusLine.title = status
        item.button?.title = status.hasPrefix("Connected to") ? "rM2 ●" : "rM2 ○"
    }

    func menuNeedsUpdate(_ menu: NSMenu) {
        accessibilityItem.isHidden = AXIsProcessTrusted()
        screenRecordingItem.isHidden = CGPreflightScreenCaptureAccess()
    }

    @objc private func connect() { sidecar.connect() }
    @objc private func disconnect() { sidecar.disconnect() }
    @objc private func openAccessibility() { Permissions.open("Privacy_Accessibility") }
    @objc private func openScreenRecording() { Permissions.open("Privacy_ScreenCapture") }
}

enum Permissions {
    /// Shows the system prompts for whichever permission is missing.
    static func promptIfNeeded() {
        if !CGPreflightScreenCaptureAccess() {
            log("Screen Recording not granted, requesting")
            CGRequestScreenCaptureAccess()
        }
        let options = ["AXTrustedCheckOptionPrompt": true] as CFDictionary
        if !AXIsProcessTrustedWithOptions(options) {
            log("Accessibility not granted, requesting")
        }
    }

    static func open(_ pane: String) {
        NSWorkspace.shared.open(URL(string: "x-apple.systempreferences:com.apple.preference.security?\(pane)")!)
    }
}
