import CoreGraphics
import Foundation

/// Wires capture -> diff -> link, and link input -> injector. Everything runs on one queue.
final class Sidecar {
    var onStatus: (String) -> Void = { _ in }

    private let queue = DispatchQueue(label: "sidecar")
    private let displayID: CGDirectDisplayID
    private let link: Link
    private let input: InputInjector
    private var capture: Capture?

    private var latest: [UInt8]?  // newest captured frame
    private var sent: [UInt8]?  // what the tablet shows; nil means it needs a full frame
    private var lastChange = Date.distantPast
    private var fastSinceRefresh = false

    private static let fps = 4
    private static let fastWindow: TimeInterval = 1  // changes closer together than this use DU
    private static let refreshAfter: TimeInterval = 2  // idle time before FULL_REFRESH

    init(displayID: CGDirectDisplayID, host: String, port: UInt16) {
        self.displayID = displayID
        link = Link(host: host, port: port, queue: queue)
        input = InputInjector(displayID: displayID)

        link.onStatus = { [weak self] in self?.onStatus($0) }
        link.onHello = { [weak self] in
            self?.sent = nil
            self?.pump()
        }
        link.onDrained = { [weak self] in self?.pump() }
        link.onInput = { [weak self] in self?.input.handle($0) }

        let timer = DispatchSource.makeTimerSource(queue: queue)
        timer.schedule(deadline: .now() + 0.5, repeating: 0.5)
        timer.setEventHandler { [weak self] in self?.maybeFullRefresh() }
        timer.resume()
        refreshTimer = timer
    }

    private var refreshTimer: DispatchSourceTimer?

    func start() {
        queue.async { self.link.start() }
        guard capture == nil else { return }
        let capture = Capture(queue: queue,
                              onFrame: { [weak self] in self?.latest = $0; self?.pump() },
                              onError: { [weak self] in log($0); self?.onStatus($0) })
        self.capture = capture
        Task {
            do {
                try await capture.start(displayID: displayID, fps: Self.fps)
            } catch {
                log("Capture failed: \(error.localizedDescription)")
                onStatus("Capture failed. Grant Screen Recording, then relaunch")
            }
        }
    }

    func connect() { queue.async { self.link.start() } }
    func disconnect() { queue.async { self.link.stop() } }

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
    }

    private func maybeFullRefresh() {
        guard fastSinceRefresh, link.ready, !link.busy,
              Date().timeIntervalSince(lastChange) > Self.refreshAfter else { return }
        fastSinceRefresh = false
        link.send(Message.fullRefresh)
    }
}
