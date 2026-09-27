import CoreMedia
import ScreenCaptureKit

/// Captures one display with ScreenCaptureKit and delivers 8-bit grayscale frames
/// (displayWidth x displayHeight, row-major, no padding). Uses the luma plane of a
/// full-range 4:2:0 YCbCr buffer, so no color conversion is done here.
final class Capture: NSObject, SCStreamOutput, SCStreamDelegate {
    private let queue: DispatchQueue
    private let onFrame: ([UInt8]) -> Void
    private let onError: (String) -> Void
    private var stream: SCStream?

    init(queue: DispatchQueue, onFrame: @escaping ([UInt8]) -> Void, onError: @escaping (String) -> Void) {
        self.queue = queue
        self.onFrame = onFrame
        self.onError = onError
    }

    func start(displayID: CGDirectDisplayID, fps: Int) async throws {
        // A freshly created virtual display can take a moment to show up.
        var scDisplay: SCDisplay?
        for _ in 0..<20 {
            let content = try await SCShareableContent.excludingDesktopWindows(false, onScreenWindowsOnly: false)
            scDisplay = content.displays.first { $0.displayID == displayID }
            if scDisplay != nil { break }
            try await Task.sleep(nanoseconds: 250_000_000)
        }
        guard let scDisplay else {
            throw NSError(domain: "Capture", code: 1,
                          userInfo: [NSLocalizedDescriptionKey: "virtual display not found by ScreenCaptureKit"])
        }

        let config = SCStreamConfiguration()
        config.width = displayWidth
        config.height = displayHeight
        config.minimumFrameInterval = CMTime(value: 1, timescale: CMTimeScale(fps))
        config.pixelFormat = kCVPixelFormatType_420YpCbCr8BiPlanarFullRange
        config.queueDepth = 3
        config.showsCursor = true

        let stream = SCStream(filter: SCContentFilter(display: scDisplay, excludingWindows: []),
                              configuration: config, delegate: self)
        try stream.addStreamOutput(self, type: .screen, sampleHandlerQueue: queue)
        try await stream.startCapture()
        self.stream = stream
        log("Capture started at \(fps) fps")
    }

    func stream(_ stream: SCStream, didOutputSampleBuffer sampleBuffer: CMSampleBuffer, of type: SCStreamOutputType) {
        guard type == .screen,
              let attachments = CMSampleBufferGetSampleAttachmentsArray(sampleBuffer, createIfNecessary: false)
                as? [[SCStreamFrameInfo: Any]],
              let rawStatus = attachments.first?[.status] as? Int,
              SCFrameStatus(rawValue: rawStatus) == .complete,
              let pixels = CMSampleBufferGetImageBuffer(sampleBuffer)
        else { return }

        CVPixelBufferLockBaseAddress(pixels, .readOnly)
        defer { CVPixelBufferUnlockBaseAddress(pixels, .readOnly) }

        let width = CVPixelBufferGetWidthOfPlane(pixels, 0)
        let height = CVPixelBufferGetHeightOfPlane(pixels, 0)
        let stride = CVPixelBufferGetBytesPerRowOfPlane(pixels, 0)
        guard width == displayWidth, height == displayHeight,
              let base = CVPixelBufferGetBaseAddressOfPlane(pixels, 0)?.assumingMemoryBound(to: UInt8.self)
        else { return }

        var gray = [UInt8](repeating: 0, count: width * height)
        gray.withUnsafeMutableBufferPointer { dst in
            for y in 0..<height {
                memcpy(dst.baseAddress! + y * width, base + y * stride, width)
            }
        }
        onFrame(gray)
    }

    func stream(_ stream: SCStream, didStopWithError error: Error) {
        onError("Capture stopped: \(error.localizedDescription)")
    }
}
