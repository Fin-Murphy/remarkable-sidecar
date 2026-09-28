import CoreGraphics
import Foundation

enum SessionState: Equatable {
    case disconnected(String?)  // optional reason, e.g. "Tablet session ended"
    case starting(String)       // "Starting tablet…", "Reconnecting…"
    case connected(String)      // the path: "USB", "Wi-Fi" (or "" without a tablet launcher)
    case error(String)          // human-readable
}

/// Wires capture -> diff -> link, and link input -> injector, and runs the session:
/// Connect starts the tablet side over SSH (if `tablet` is set), opens the tunnel and connects;
/// Disconnect ends it. Everything except the blocking SSH calls runs on one queue.
final class Sidecar {
    var onState: (SessionState) -> Void = { _ in }

    private let queue = DispatchQueue(label: "sidecar")
    private let displayID: CGDirectDisplayID
    private let tablet: Tablet?  // nil: connect straight to host:port (the mock)
    private let link: Link
    private let input: InputInjector
    private var capture: Capture?

    private var state: SessionState = .disconnected(nil) {
        didSet { if state != oldValue { log("State: \(state)"); onState(state) } }
    }
    private var generation = 0          // bumps on every Connect/Disconnect; stale SSH results are dropped
    private var lostSince: Date?        // wanted but not connected since then
    private var reopeningTunnel = false

    private var latest: [UInt8]?  // newest captured frame
    private var sent: [UInt8]?  // what the tablet shows; nil means it needs a full frame
    private var lastChange = Date.distantPast
    private var fastSinceRefresh = false
    private var stats = (frames: 0, rects: 0, bytes: 0, since: Date())

    private static let fps = 4
    private static let fastWindow: TimeInterval = 1  // changes closer together than this use DU
    private static let refreshAfter: TimeInterval = 2  // idle time before FULL_REFRESH
    private static let giveUpAfter: TimeInterval = 40  // longer than the tablet's 30 s grace

    private var orientation: Orientation  // on `queue`

    init(displayID: CGDirectDisplayID, config: Config, orientation: Orientation) {
        self.displayID = displayID
        self.orientation = orientation
        if config.launch {
            let tablet = Tablet(usbHost: config.host, wifiOverride: config.wifiHost, remotePort: config.port)
            self.tablet = tablet
            link = Link(host: "127.0.0.1", port: tablet.localPort, queue: queue)
        } else {
            tablet = nil
            link = Link(host: config.host, port: config.port, queue: queue)
        }
        input = InputInjector(displayID: displayID, orientation: orientation)

        link.onHello = { [weak self] in
            guard let self else { return }
            self.state = .connected(self.tablet?.path?.name ?? "")
            self.lostSince = nil
            self.sent = nil
            self.pump()
        }
        link.onLost = { [weak self] _ in
            guard let self else { return }
            self.state = .starting("Reconnecting…")
            self.lostSince = Date()
        }
        link.onDrained = { [weak self] in self?.pump() }
        link.onInput = { [weak self] in self?.input.handle($0) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.tick() }
        timer.resume()
        tickTimer = timer
    }

    private var tickTimer: DispatchSourceTimer?

    /// Starts capturing. Without a tablet launcher (mock testing) it also connects right away.
    func start() {
        let capture = Capture(queue: queue, orientation: queue.sync { orientation },
                              onFrame: { [weak self] in self?.latest = $0; self?.pump() },
                              onError: { [weak self] message in
                                  log(message)
                                  self?.fail("Screen capture stopped")
                              })
        self.capture = capture
        Task {
            do {
                try await capture.start(displayID: displayID, fps: Self.fps)
            } catch {
                log("Capture failed: \(error.localizedDescription)")
                fail("No Screen Recording permission. Grant it, then relaunch")
            }
        }
        if tablet == nil { connect() }
    }

    /// Call after the virtual display has been switched. The next frame is sent whole.
    func setOrientation(_ new: Orientation) {
        queue.async { [self] in
            if new.isLandscape && orientation.isLandscape {
                // Only the direction changed: the display doesn't, so no new frame comes. The two
                // landscape panel frames are 180° apart, which for a row-major frame is reversing it.
                latest = latest.map { Array($0.reversed()) }
            } else {
                latest = nil  // the display's mode changes; its next frame comes in the new orientation
            }
            orientation = new
            input.orientation = new
            capture?.setOrientation(new)
            sent = nil
            pump()
        }
    }

    private func fail(_ message: String) {
        queue.async { self.state = .error(message) }
    }

    func connect() {
        queue.async { [self] in
            switch state {
            case .starting, .connected: return
            default: break
            }
            generation += 1
            let generation = generation
            guard let tablet else {
                state = .starting("Connecting…")
                link.start()
                return
            }
            state = .starting("Starting tablet…")
            DispatchQueue.global().async { [self] in
                var problem = tablet.startSession()
                // If Disconnect was chosen meanwhile, don't open a tunnel; a newer Connect opens its own.
                if problem == nil, queue.sync(execute: { generation == self.generation }) {
                    problem = tablet.openTunnel()
                }
                queue.async { [self] in
                    guard generation == self.generation else { return }  // Disconnect was chosen meanwhile
                    if let problem {
                        state = .error(problem)
                        return
                    }
                    lostSince = Date()  // counts toward giving up until the first HELLO
                    link.start()
                }
            }
        }
    }

    func disconnect() {
        queue.async { [self] in
            generation += 1
            link.stop()
            lostSince = nil
            state = .disconnected(nil)
            if let tablet {
                DispatchQueue.global().async {
                    tablet.closeTunnel()
                    tablet.stopSession()
                }
            }
        }
    }

    /// For Quit: ends the tablet session before returning (at most a few seconds).
    func shutdown() {
        queue.sync {
            generation += 1
            link.stop()
        }
        tablet?.closeTunnel()
        tablet?.stopSession()
    }

    private func tick() {
        capture?.checkAlive()
        maybeFullRefresh()
        logStats()
        guard let tablet, let since = lostSince, case .starting = state else { return }
        if Date().timeIntervalSince(since) > Self.giveUpAfter {
            // The tablet session has ended (its 30 s grace ran out) or is unreachable. Don't start it
            // again on our own: every start restarts xochitl, which is rate-limited.
            generation += 1
            link.stop()
            lostSince = nil
            state = .disconnected("Tablet session ended")
            DispatchQueue.global().async { tablet.closeTunnel() }
        } else if !tablet.tunnelIsOpen && !reopeningTunnel {
            // Reopening the tunnel is cheap and doesn't touch xochitl.
            reopeningTunnel = true
            let generation = generation
            DispatchQueue.global().async { [self] in
                let problem = tablet.openTunnel()
                queue.async { [self] in
                    reopeningTunnel = false
                    if let problem, generation == self.generation { log("Tunnel: \(problem)") }
                }
            }
        }
    }

    /// Sends whatever changed since the last send, unless the link is still busy.
    private func pump() {
        guard link.ready, !link.busy, let frame = latest else { return }
        let now = Date()
        let rects: [DirtyRect]
        let hint: UInt8
        if let sent {
            rects = dirtyRects(old: sent, new: frame, width: displayWidth, height: displayHeight)
            guard !rects.isEmpty else { return }
            let changingFast = input.penDown || now.timeIntervalSince(lastChange) < Self.fastWindow
            hint = changingFast ? 0 : 1
        } else {
            rects = [DirtyRect(x: 0, y: 0, w: displayWidth, h: displayHeight)]
            hint = 1
        }
        lastChange = now
        if hint == 0 { fastSinceRefresh = true }

        var data = Data()
        for rect in rects { data += Message.rect(rect, from: frame, hint: hint) }
        data += Message.frameEnd
        link.send(data)
        sent = frame  // everything outside the rects was already identical
        stats.frames += 1
        stats.rects += rects.count
        stats.bytes += data.count
    }

    private func maybeFullRefresh() {
        guard fastSinceRefresh, link.ready, !link.busy,
              Date().timeIntervalSince(lastChange) > Self.refreshAfter else { return }
        fastSinceRefresh = false
        link.send(Message.fullRefresh)
        log("Sent FULL_REFRESH")
    }

    /// Every 10 s while connected: what was sent. An idle display should show 0 frames.
    private func logStats() {
        guard Date().timeIntervalSince(stats.since) >= 10 else { return }
        if case .connected = state {
            log("Last 10 s: \(stats.frames) frames, \(stats.rects) rects, \(stats.bytes) bytes")
        }
        stats = (0, 0, 0, Date())
    }
}
