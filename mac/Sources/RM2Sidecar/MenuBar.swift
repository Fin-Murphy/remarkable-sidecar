import AppKit

final class MenuBar: NSObject, NSMenuDelegate {
    private let sidecar: Sidecar
    private let item = NSStatusBar.system.statusItem(withLength: NSStatusItem.variableLength)
    private let statusLine = NSMenuItem(title: "Starting…", action: nil, keyEquivalent: "")
    private let accessibilityItem = NSMenuItem(title: "Grant Accessibility (pen input)…",
                                               action: #selector(openAccessibility), keyEquivalent: "")
    private let screenRecordingItem = NSMenuItem(title: "Grant Screen Recording…",
                                                 action: #selector(openScreenRecording), keyEquivalent: "")
    private let connectItem = NSMenuItem(title: "Connect", action: #selector(connect), keyEquivalent: "")
    private let disconnectItem = NSMenuItem(title: "Disconnect", action: #selector(disconnect), keyEquivalent: "")

    init(sidecar: Sidecar) {
        self.sidecar = sidecar
        super.init()
        item.button?.title = "rM2 ○"

        let menu = NSMenu()
        menu.delegate = self
        menu.autoenablesItems = false
        statusLine.isEnabled = false
        menu.addItem(statusLine)
        menu.addItem(screenRecordingItem)
        menu.addItem(accessibilityItem)
        menu.addItem(.separator())
        connectItem.target = self
        disconnectItem.target = self
        menu.addItem(connectItem)
        menu.addItem(disconnectItem)
        menu.addItem(.separator())
        menu.addItem(withTitle: "Quit", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")
        accessibilityItem.target = self
        screenRecordingItem.target = self
        item.menu = menu
        setState(.disconnected(nil))
    }

    func setState(_ state: SessionState) {
        let (title, icon): (String, String)
        switch state {
        case .disconnected(let reason): (title, icon) = (reason.map { "Disconnected: \($0)" } ?? "Disconnected", "rM2 ○")
        case .starting(let what): (title, icon) = (what, "rM2 …")
        case .connected(let path): (title, icon) = (path.isEmpty ? "Connected" : "Connected (\(path))", "rM2 ●")
        case .error(let message): (title, icon) = ("Error: \(message)", "rM2 !")
        }
        statusLine.title = title
        item.button?.title = icon
        let busy: Bool
        switch state {
        case .starting, .connected: busy = true
        default: busy = false
        }
        connectItem.isEnabled = !busy
        disconnectItem.isEnabled = busy
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
