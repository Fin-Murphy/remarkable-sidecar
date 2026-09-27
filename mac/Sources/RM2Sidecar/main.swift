import AppKit

setvbuf(stdout, nil, _IOLBF, 0)

func log(_ message: String) {
    print("[\(Date().formatted(date: .omitted, time: .standard))] \(message)")
}

/// Host/port from `--host`/`--port`, else `RM2_HOST`/`RM2_PORT`, else the tablet's USB address.
struct Config {
    var host = ProcessInfo.processInfo.environment["RM2_HOST"] ?? "10.11.99.1"
    var port = UInt16(ProcessInfo.processInfo.environment["RM2_PORT"] ?? "") ?? 9876

    static func parse() -> Config {
        var config = Config()
        var args = CommandLine.arguments.dropFirst().makeIterator()
        while let arg = args.next() {
            switch arg {
            case "--host": if let v = args.next() { config.host = v }
            case "--port": if let v = args.next(), let p = UInt16(v) { config.port = p }
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
    var menuBar: MenuBar!
    var screenObserver: NSObjectProtocol?

    func applicationDidFinishLaunching(_ notification: Notification) {
        display = VirtualDisplay()
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
        sidecar = Sidecar(displayID: display.displayID, host: config.host, port: config.port)
        menuBar = MenuBar(sidecar: sidecar)
        sidecar.onStatus = { [weak self] status in
            DispatchQueue.main.async { self?.menuBar.setStatus(status) }
        }
        Permissions.promptIfNeeded()
        sidecar.start()
    }
}

let app = NSApplication.shared
app.setActivationPolicy(.accessory)
let delegate = AppDelegate()
app.delegate = delegate
app.run()
