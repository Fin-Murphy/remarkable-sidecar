import Foundation

/// Starts and stops the tablet side over SSH (key auth, BatchMode), and holds an SSH tunnel from
/// 127.0.0.1:`localPort` on the Mac to the tablet server on the tablet's 127.0.0.1:`remotePort`.
/// The server is never exposed on the tablet's USB or Wi-Fi interfaces.
/// USB is used when the tablet answers there, otherwise Wi-Fi: `remarkable.local` (mDNS), then the
/// Wi-Fi address the tablet last reported (remembered, so a DHCP change or missing mDNS still works),
/// unless a Wi-Fi host is given explicitly.
/// Methods block (they run ssh); call them off the main thread.
final class Tablet {
    struct Path { let name: String; let host: String }

    let usbHost: String
    let wifiOverride: String?
    let remotePort: UInt16
    let localPort: UInt16 = 19876
    private let lock = NSLock()
    private var tunnel: Process?
    private var active: Path?

    private static let lastWifiKey = "lastWifiAddress"

    init(usbHost: String, wifiOverride: String?, remotePort: UInt16) {
        self.usbHost = usbHost
        self.wifiOverride = wifiOverride
        self.remotePort = remotePort
    }

    /// Candidates in order of preference.
    var paths: [Path] {
        var wifi = wifiOverride.map { [$0] } ?? ["remarkable.local"]
        if wifiOverride == nil, let last = UserDefaults.standard.string(forKey: Self.lastWifiKey), !wifi.contains(last) {
            wifi.append(last)
        }
        return [Path(name: "USB", host: usbHost)] + wifi.map { Path(name: "Wi-Fi", host: $0) }
    }

    /// The path the current session uses.
    var path: Path? { lock.withLock { active } }

    /// Runs start.sh on the tablet over the first path that answers. Returns nil once the server
    /// listens, else a reason to show. Only "unreachable" falls through to the next path; a refusal
    /// (start-limit guard, key, host key) is reported as is.
    func startSession() -> String? {
        var unreachable: [String] = []
        for path in paths {
            let (status, output) = ssh(path.host, ["sh /home/root/rm2sidecar/start.sh"], timeout: 90)
            if let match = output.firstMatch(of: try! Regex(#"WIFI (\d+\.\d+\.\d+\.\d+)"#)) {
                UserDefaults.standard.set(String(match.output[1].substring ?? ""), forKey: Self.lastWifiKey)
            }
            if status == 0, output.contains("READY") {
                lock.withLock { active = path }
                log("Tablet session up over \(path.name) (\(path.host))")
                return nil
            }
            if status == 255 || status == nil {
                let reason = Self.explainSSHFailure(output)
                if reason == Self.unreachable || reason == Self.noAnswer {
                    if !unreachable.contains(path.name) { unreachable.append(path.name) }
                    continue
                }
                return "\(path.name): \(reason)"
            }
            return Self.explainStartFailure(output)
        }
        return "Can't reach the tablet by \(unreachable.joined(separator: " or ")). Is it plugged in, or on Wi-Fi and awake?"
    }

    /// Ends the tablet session (run.sh then brings xochitl back).
    func stopSession() {
        guard let path else { return }
        _ = ssh(path.host, ["kill $(pidof rm2sidecar) 2>/dev/null; true"], timeout: 8)
    }

    /// Opens the port forward. Returns nil if it is up, else a reason to show.
    func openTunnel() -> String? {
        guard let host = path?.host else { return "No tablet session" }
        killOrphanedTunnels()
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + ["-N", "-o", "ExitOnForwardFailure=yes",
                                            "-L", "127.0.0.1:\(localPort):127.0.0.1:\(remotePort)", "root@\(host)"]
        let errors = Pipe()
        process.standardError = errors
        process.standardOutput = FileHandle.nullDevice
        // Replace the previous tunnel and register this one as it starts, in one step, so a concurrent
        // closeTunnel() (Disconnect, Quit) or openTunnel() always finds it. Otherwise it could leak and
        // keep holding localPort after the app quits.
        do {
            try lock.withLock {
                tunnel?.terminate()
                try process.run()
                tunnel = process
            }
        } catch { return "Couldn't run ssh: \(error.localizedDescription)" }
        // Wait until ssh listens on localPort (after connecting and logging in, which over Wi-Fi can
        // take a few seconds), or exits because it can't (port busy, host unreachable, key refused).
        let deadline = Date() + 10
        while process.isRunning && !isListening(process.processIdentifier) && Date() < deadline {
            Thread.sleep(forTimeInterval: 0.1)
        }
        guard process.isRunning else {
            let text = String(decoding: errors.fileHandleForReading.readDataToEndOfFile(), as: UTF8.self)
            if text.contains("Address already in use") || text.contains("cannot listen") {
                return "Port \(localPort) on this Mac is in use by another program"
            }
            return Self.explainSSHFailure(text)
        }
        guard isListening(process.processIdentifier) else {
            process.terminate()
            return Self.noAnswer
        }
        return nil
    }

    /// Whether process `pid` listens on localPort (lsof exits with 0 when it finds such a socket).
    private func isListening(_ pid: Int32) -> Bool {
        let lsof = Process()
        lsof.executableURL = URL(fileURLWithPath: "/usr/sbin/lsof")
        lsof.arguments = ["-nP", "-a", "-p", "\(pid)", "-iTCP:\(localPort)", "-sTCP:LISTEN", "-t"]
        lsof.standardOutput = FileHandle.nullDevice
        lsof.standardError = FileHandle.nullDevice
        guard (try? lsof.run()) != nil else { return false }
        lsof.waitUntilExit()
        return lsof.terminationStatus == 0
    }

    /// A tunnel left by an earlier run of the app that ended without cleaning up (force quit, crash)
    /// keeps localPort, so a new one can't forward it. Such an ssh has been reparented to launchd
    /// (parent pid 1); this run's tunnels never are.
    private func killOrphanedTunnels() {
        let pkill = Process()
        pkill.executableURL = URL(fileURLWithPath: "/usr/bin/pkill")
        pkill.arguments = ["-P", "1", "-f", "^/usr/bin/ssh .* -L 127\\.0\\.0\\.1:\(localPort):"]
        guard (try? pkill.run()) != nil else { return }
        pkill.waitUntilExit()
        if pkill.terminationStatus == 0 { log("Ended an SSH tunnel left over from an earlier run") }
    }

    var tunnelIsOpen: Bool { lock.withLock { tunnel?.isRunning ?? false } }

    func closeTunnel() {
        let process = lock.withLock { () -> Process? in
            defer { tunnel = nil }
            return tunnel
        }
        process?.terminate()
    }

    // MARK: - ssh

    /// The tablet's host key is known under its USB address. Checking every address against that
    /// entry keeps host-key verification strict when the tablet is reached another way (Wi-Fi).
    private var options: [String] {
        ["-o", "BatchMode=yes", "-o", "ConnectTimeout=5",
         "-o", "ServerAliveInterval=5", "-o", "ServerAliveCountMax=3",
         "-o", "HostKeyAlias=\(usbHost)"]
    }

    /// Runs a remote command. Returns the exit status (nil on timeout) and stdout+stderr.
    private func ssh(_ host: String, _ command: [String], timeout: TimeInterval) -> (Int32?, String) {
        let process = Process()
        process.executableURL = URL(fileURLWithPath: "/usr/bin/ssh")
        process.arguments = options + ["root@\(host)"] + command
        let pipe = Pipe()
        process.standardOutput = pipe
        process.standardError = pipe
        process.standardInput = FileHandle.nullDevice
        do { try process.run() } catch { return (nil, "Couldn't run ssh: \(error.localizedDescription)") }
        // Read on another thread so a hung ssh can't block us past the timeout.
        var output = Data()
        let readDone = DispatchSemaphore(value: 0)
        DispatchQueue.global().async {
            output = pipe.fileHandleForReading.readDataToEndOfFile()
            readDone.signal()
        }
        let deadline = Date() + timeout
        while process.isRunning && Date() < deadline { Thread.sleep(forTimeInterval: 0.05) }
        if process.isRunning {
            process.terminate()
            log("ssh \(command.joined(separator: " ")) timed out")
            return (nil, "timed out")
        }
        _ = readDone.wait(timeout: .now() + 2)
        let text = String(decoding: output, as: UTF8.self).trimmingCharacters(in: .whitespacesAndNewlines)
        log("ssh \(host) \(command.joined(separator: " ")) -> \(process.terminationStatus): \(text)")
        return (process.terminationStatus, text)
    }

    private static let unreachable = "can't reach the tablet"
    private static let noAnswer = "the tablet didn't answer"

    private static func explainSSHFailure(_ text: String) -> String {
        if text.contains("Permission denied") { return "the tablet refused this Mac's SSH key" }
        if text.contains("Host key verification failed") || text.contains("REMOTE HOST IDENTIFICATION") {
            return "the tablet's SSH host key doesn't match; not connecting"
        }
        if text.contains("timed out") { return noAnswer }
        return unreachable
    }

    /// Turns start.sh's "ERROR: ..." (usually a run.sh guard) into a sentence for the window.
    private static func explainStartFailure(_ text: String) -> String {
        func number(after pattern: String) -> Substring? {
            guard let regex = try? Regex(pattern + #"(\d+)"#), let match = text.firstMatch(of: regex) else { return nil }
            return match.output[1].substring
        }
        if let seconds = number(after: "try again in ") {
            return "Tablet busy (its screen app restarted too often). Try again in \(seconds) s"
        }
        if let percent = number(after: "battery ") {
            return "Tablet battery low (\(percent)%). Charge it first"
        }
        if text.contains("upgrade_available") { return "The tablet has a pending software update; not starting" }
        let reason = text.replacingOccurrences(of: "ERROR:", with: "").trimmingCharacters(in: .whitespaces)
        return reason.isEmpty ? "The tablet side didn't start" : "Tablet: \(reason)"
    }
}
