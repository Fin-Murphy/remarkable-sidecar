import CoreMedia
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and delivers 8-bit grayscale frames in the tablet's
/// panel orientation (displayWidth x displayHeight, row-major, no padding), turned from the display's
/// `orientation`. Uses the luma plane of a full-range 4:2:0 YCbCr buffer, so no color conversion is
/// done here.
///
/// Control Center's menu-bar items (clock, Wi-Fi, battery, sound) are left out of the capture:
/// a clock showing seconds would otherwise redraw the e-ink screen every second and the display
/// would never go idle. Other displays are not affected. The filter is fixed for the stream's life:
/// changing it with updateContentFilter sometimes stopped the stream silently.
///
/// ScreenCaptureKit calls back about 4 times a second even on an idle display, so no callback for
/// `stallAfter` seconds means the stream has died silently; `checkAlive()` then restarts it.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private let onFrame: ([UInt8]) -> Void
    private let onError: (String) -> Void
    private var stream: SCStream?
    private var displayID: CGDirectDisplayID = 0
    private var fps = 4
    private var orientation: Orientation  // on `queue`
    private var lastCallback = Date()  // on `queue`
    private var restarting = false     // on `queue`
    private static let stallAfter: TimeInterval = 3

    init(queue: DispatchQueue, orientation: Orientation,
         onFrame: @escaping ([UInt8]) -> Void, onError: @escaping (String) -> Void) {
        self.queue = queue
        self.orientation = orientation
        self.onFrame = onFrame
        self.onError = onError
    }

    func start(displayID: CGDirectDisplayID, fps: Int) async throws {
        self.displayID = displayID
        self.fps = fps
        // A freshly created virtual display can take a moment to show up.
        var found: (SCShareableContent, SCDisplay)?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            if let display = content.displays.first(where: { $0.displayID == displayID }) {
                found = (content, display)
                break
            }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let (content, display) = found else {
            throw NSError(domain: "Capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "virtual display not found by ScreenCaptureKit"])
        }

        let config = configuration(for: queue.sync { orientation })
        let controlCenter = content.applications.filter { $0.bundleIdentifier == "com.apple.controlcenter" }
        let filter = SCContentFilter(display: display, excludingApplications: controlCenter, exceptingWindows: [])
        let stream = SCStream(filter: filter, configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        queue.sync { lastCallback = Date() }
        self.stream = stream
        log("Capture started at \(fps) fps\(controlCenter.isEmpty ? "" : ", menu-bar clock and status items left out")")

        if ProcessInfo.processInfo.environment["RM2_TEST_STALL"] != nil {  // test hook: die silently
            Task {
                try? await Task.sleep(nanoseconds: 10_000_000_000)
                log("Capture: test hook stopping the stream silently")
                try? await stream.stopCapture()
            }
        }
    }

    private func configuration(for orientation: Orientation) -> SCStreamConfiguration {
        let config = SCStreamConfiguration()
        (config.width, config.height) = orientation.displaySize
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.queueDepth = 3
        config.showsCursor = true
        return config
    }

    /// Call on `queue`, after the display itself has been switched. Frames are skipped until the
    /// display's mode matches, so a half-switched frame never reaches the tablet.
    func setOrientation(_ new: Orientation) {
        let resize = new.isLandscape != orientation.isLandscape
        orientation = new
        guard resize, let stream else { return }  // no stream yet (or restarting): start() uses the new one
        stream.updateConfiguration(configuration(for: new)) { error in
            if let error { log("Capture: resizing for \(new.rawValue) failed: \(error.localizedDescription)") }
        }
    }

    /// Call regularly on `queue`. Restarts the stream if ScreenCaptureKit has gone silent.
    func checkAlive() {
        guard stream != nil, !restarting, Date().timeIntervalSince(lastCallback) > Self.stallAfter else { return }
        restarting = true
        log("Capture stalled (no frames from ScreenCaptureKit for \(Int(Self.stallAfter)) s); restarting it")
        let old = stream
        stream = nil
        Task {
            try? await old?.stopCapture()
            do {
                try await start(displayID: displayID, fps: fps)
            } catch {
                onError("Capture restart failed: \(error.localizedDescription)")
            }
            restartFinished()
        }
    }

    private func restartFinished() {
        queue.async { self.restarting = false; self.lastCallback = Date() }
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int
        else { return }
        lastCallback = Date()
        guard SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        let bounds = CGDisplayBounds(displayID)
        guard (width, height) == orientation.displaySize, (bounds.width > bounds.height) == orientation.isLandscape,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self)
        else { return }

        onFrame(orientation.panelFrame(from: base, stride: stride))
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError("Capture stopped: \(error.localizedDescription)")
    }
}
