import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    print("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
}

/// Host/port from `--host`/`--port`, else `RM2_HOST`/`RM2_PORT`, else the tablet's USB address.
/// Over Wi-Fi it tries `remarkable.local`, then the tablet's last reported Wi-Fi address, unless
/// `--wifi-host` / `RM2_WIFI_HOST` names a host explicitly.
/// By default Connect starts the tablet side over SSH and tunnels to its server (port = the
/// server's port on the tablet). `--no-launch` connects straight to host:port instead and does so
/// at launch (for the mock: `--host 127.0.0.1 --no-launch`). `--connect` presses Connect at launch.
struct Config {
    var host = ProcessInfo.processInfo.environment["RM2_HOST"] ?? "10.11.99.1"
    var port = UInt16(ProcessInfo.processInfo.environment["RM2_PORT"] ?? "") ?? 9876
    var wifiHost = ProcessInfo.processInfo.environment["RM2_WIFI_HOST"]
    var launch = true
    var connectAtLaunch = false
    var testWindow = false

    static func parse() -> Config {
        var config = Config()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--host": if let v = args.next() { config.host = v }
            case "--port": if let v = args.next(), let p = UInt16(v) { config.port = p }
            case "--wifi-host": if let v = args.next() { config.wifiHost = v }
            case "--no-launch": config.launch = false
            case "--connect": config.connectAtLaunch = true
            case "--test-window": config.testWindow = true
            default: break
            }
        }
        return config
    }
}

final class AppDelegate: NSObject, NSApplicationDelegate {
    let config = Config.parse()
    var display: VirtualDisplay!
    var sidecar: Sidecar!
    var appWindow: AppWindow!
    var screenObserver: NSObjectProtocol?
    var signalSources: [DispatchSourceSignal] = []

    private static let orientationKey = "orientation"

    func applicationDidFinishLaunching(_ notification: Notification) {
        let orientation = Orientation(rawValue: UserDefaults.standard.string(forKey: Self.orientationKey) ?? "") ?? .portrait
        display = VirtualDisplay(orientation: orientation)
        // The display's NSScreen appears asynchronously.
        if !display.setWhiteDesktop() {
            screenObserver = NotificationCenter.default.addObserver(
                forName: NSApplication.didChangeScreenParametersNotification, object: nil, queue: .main
            ) { [weak self] _ in
                guard let self, self.display.setWhiteDesktop(), let observer = self.screenObserver else { return }
                NotificationCenter.default.removeObserver(observer)
                self.screenObserver = nil
            }
        }
        sidecar = Sidecar(displayID: display.displayID, config: config, orientation: orientation)
        appWindow = AppWindow(sidecar: sidecar, orientation: orientation)
        sidecar.onState = { [weak self] state in
            DispatchQueue.main.async { self?.appWindow.setState(state) }
        }
        appWindow.onOrientation = { [weak self] orientation in
            guard let self else { return }
            log("Orientation: \(orientation.rawValue)")
            UserDefaults.standard.set(orientation.rawValue, forKey: Self.orientationKey)
            self.display.setOrientation(orientation)
            self.sidecar.setOrientation(orientation)
        }
        appWindow.show()
        NSApp.activate()
        Permissions.promptIfNeeded()
        sidecar.start()
        if config.connectAtLaunch { sidecar.connect() }
        if config.testWindow { startTestWindow() }

        // Scripting hooks: `kill -USR2 <pid>` = Connect, `kill -USR1 <pid>` = Disconnect.
        for (sig, action) in [(SIGUSR2, sidecar.connect), (SIGUSR1, sidecar.disconnect)] {
            signal(sig, SIG_IGN)
            let source = DispatchSource.makeSignalSource(signal: sig, queue: .main)
            source.setEventHandler(handler: action)
            source.resume()
            signalSources.append(source)
        }
    }

    /// Regression check (`--test-window`): a window on the virtual display whose text changes twice a
    /// second and which moves every second. Both must produce frames for the tablet.
    var testWindow: NSWindow?
    func startTestWindow() {
        var ticks = 0
        Timer.scheduledTimer(withTimeInterval: 0.5, repeats: true) { [weak self] _ in
            guard let self, let screen = self.display.screen else { return }
            if self.testWindow == nil {
                let window = NSWindow(contentRect: NSRect(x: 0, y: 0, width: 320, height: 160),
                                      styleMask: [.titled], backing: .buffered, defer: false)
                window.title = "rM2 Sidecar test window"
                window.contentView = NSTextField(labelWithString: "")
                window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40, y: screen.frame.midY))
                window.orderFrontRegardless()
                self.testWindow = window
                log("Test window opened on the virtual display")
            }
            ticks += 1
            (self.testWindow?.contentView as? NSTextField)?.stringValue = "  tick \(ticks)"
            if ticks % 2 == 0, let window = self.testWindow {
                let step = CGFloat((ticks / 2) % 8) * 40
                window.setFrameOrigin(NSPoint(x: screen.frame.minX + 40 + step, y: screen.frame.midY - step))
            }
        }
    }

    func applicationWillTerminate(_ notification: Notification) {
        sidecar.shutdown()  // ends the tablet session so its screen app comes back right away
    }
}

/// The standard app menu (About, Hide, Quit) and Window menu (Minimize, Close).
func makeMainMenu() -> NSMenu {
    let appMenu = NSMenu()
    appMenu.addItem(withTitle: "About rM2 Sidecar", action: #selector(NSApplication.orderFrontStandardAboutPanel(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Hide rM2 Sidecar", action: #selector(NSApplication.hide(_:)), keyEquivalent: "h")
    appMenu.addItem(withTitle: "Hide Others", action: #selector(NSApplication.hideOtherApplications(_:)), keyEquivalent: "h")
        .keyEquivalentModifierMask = [.command, .option]
    appMenu.addItem(withTitle: "Show All", action: #selector(NSApplication.unhideAllApplications(_:)), keyEquivalent: "")
    appMenu.addItem(.separator())
    appMenu.addItem(withTitle: "Quit rM2 Sidecar", action: #selector(NSApplication.terminate(_:)), keyEquivalent: "q")

    let windowMenu = NSMenu(title: "Window")
    windowMenu.addItem(withTitle: "Minimize", action: #selector(NSWindow.performMiniaturize(_:)), keyEquivalent: "m")
    windowMenu.addItem(withTitle: "Close", action: #selector(NSWindow.performClose(_:)), keyEquivalent: "w")

    let menu = NSMenu()
    for submenu in [appMenu, windowMenu] {
        menu.addItem(withTitle: submenu.title, action: nil, keyEquivalent: "").submenu = submenu
    }
    return menu
}

let app = NSApplication.shared
app.setActivationPolicy(.regular)
app.mainMenu = makeMainMenu()
let delegate = AppDelegate()
app.delegate = delegate
app.run()
