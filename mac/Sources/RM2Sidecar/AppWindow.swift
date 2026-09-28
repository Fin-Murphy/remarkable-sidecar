import AppKit

/// The app's window: the session state, Connect/Disconnect, the orientation, and a "Grant…" row for
/// each missing permission. Closing it quits the app, which ends the tablet session.
final class AppWindow: NSObject, NSWindowDelegate {
    var onOrientation: (Orientation) -> Void = { _ in }

    private let sidecar: Sidecar
    private let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 360, height: 150),
                                  styleMask: [.titled, .closable, .miniaturizable], backing: .buffered, defer: false)
    private let dot = NSTextField(labelWithString: "●")
    private let statusLabel = NSTextField(wrappingLabelWithString: "")
    private let button = NSButton(title: "Connect", target: nil, action: nil)
    private let orientationControl = NSSegmentedControl(labels: ["Portrait", "Landscape ↓", "Landscape ↑"],
                                                        trackingMode: .selectOne, target: nil, action: nil)
    private let screenRecordingRow = NSStackView()
    private let accessibilityRow = NSStackView()
    private var disconnects = false  // what the button does

    init(sidecar: Sidecar, orientation: Orientation) {
        self.sidecar = sidecar
        super.init()

        // Order matches Orientation.allCases. The arrows say where the tablet's thick edge goes.
        orientationControl.target = self
        orientationControl.action = #selector(orientationChosen)
        orientationControl.selectedSegment = Orientation.allCases.firstIndex(of: orientation) ?? 0
        orientationControl.setToolTip("Tablet upright, thick edge on the left", forSegment: 0)
        orientationControl.setToolTip("Tablet on its side, thick edge at the bottom", forSegment: 1)
        orientationControl.setToolTip("Tablet on its side, thick edge at the top", forSegment: 2)

        statusLabel.alignment = .center
        statusLabel.preferredMaxLayoutWidth = 290
        let statusRow = NSStackView(views: [dot, statusLabel])
        statusRow.alignment = .firstBaseline
        statusRow.spacing = 6

        button.target = self
        button.action = #selector(buttonPressed)
        button.bezelStyle = .rounded
        button.controlSize = .large
        button.keyEquivalent = "\r"

        fill(screenRecordingRow, "Screen Recording not granted", #selector(openScreenRecording))
        fill(accessibilityRow, "Accessibility (pen input) not granted", #selector(openAccessibility))

        let stack = NSStackView(views: [statusRow, button, orientationControl, screenRecordingRow, accessibilityRow])
        stack.orientation = .vertical
        stack.alignment = .centerX
        stack.spacing = 16
        stack.edgeInsets = NSEdgeInsets(top: 24, left: 24, bottom: 24, right: 24)
        stack.translatesAutoresizingMaskIntoConstraints = false
        let content = NSView()
        content.addSubview(stack)
        NSLayoutConstraint.activate([
            stack.topAnchor.constraint(equalTo: content.topAnchor),
            stack.bottomAnchor.constraint(equalTo: content.bottomAnchor),
            stack.leadingAnchor.constraint(equalTo: content.leadingAnchor),
            stack.trailingAnchor.constraint(equalTo: content.trailingAnchor),
            stack.widthAnchor.constraint(equalToConstant: 360),
        ])

        window.title = "rM2 Sidecar"
        window.contentView = content
        window.delegate = self
        window.isReleasedWhenClosed = false
        setState(.disconnected(nil))
        refreshPermissions()
        // Back from System Settings: show what was granted meanwhile.
        NotificationCenter.default.addObserver(forName: NSApplication.didBecomeActiveNotification, object: nil,
                                               queue: .main) { [weak self] _ in self?.refreshPermissions() }
    }

    func show() {
        window.center()  // on the main display, not the reMarkable one
        window.makeKeyAndOrderFront(nil)
    }

    func setState(_ state: SessionState) {
        let (text, color): (String, NSColor)
        switch state {
        case .disconnected(let reason): (text, color) = (reason.map { "Disconnected: \($0)" } ?? "Disconnected", .secondaryLabelColor)
        case .starting(let what): (text, color) = (what, .systemOrange)
        case .connected(let path): (text, color) = (path.isEmpty ? "Connected" : "Connected (\(path))", .systemGreen)
        case .error(let message): (text, color) = (message, .systemRed)
        }
        statusLabel.stringValue = text
        dot.textColor = color
        switch state {
        case .starting, .connected: disconnects = true
        default: disconnects = false
        }
        button.title = disconnects ? "Disconnect" : "Connect"
        fitWindow()
    }

    func windowWillClose(_ notification: Notification) {
        NSApp.terminate(nil)
    }

    private func fill(_ row: NSStackView, _ text: String, _ action: Selector) {
        let label = NSTextField(labelWithString: "⚠ " + text)
        label.textColor = .secondaryLabelColor
        let grant = NSButton(title: "Grant…", target: self, action: action)
        grant.bezelStyle = .rounded
        grant.controlSize = .small
        row.setViews([label, grant], in: .leading)
        row.alignment = .firstBaseline
        row.spacing = 8
    }

    private func refreshPermissions() {
        screenRecordingRow.isHidden = CGPreflightScreenCaptureAccess()
        accessibilityRow.isHidden = AXIsProcessTrusted()
        fitWindow()
    }

    /// Resizes the window to its content (the status can wrap, and rows come and go), keeping its top edge.
    private func fitWindow() {
        guard let content = window.contentView else { return }
        content.layoutSubtreeIfNeeded()
        var frame = window.frameRect(forContentRect: NSRect(origin: .zero, size: content.fittingSize))
        frame.origin = NSPoint(x: window.frame.minX, y: window.frame.maxY - frame.height)
        window.setFrame(frame, display: true)
    }

    @objc private func buttonPressed() { disconnects ? sidecar.disconnect() : sidecar.connect() }
    @objc private func orientationChosen() { onOrientation(Orientation.allCases[orientationControl.selectedSegment]) }
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
