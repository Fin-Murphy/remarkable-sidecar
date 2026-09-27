import AppKit
import CPrivate

let displayWidth = 1404
let displayHeight = 1872

/// A 1404x1872 virtual display (reMarkable 2 panel, 226 dpi). Removed when this object is
/// released or the process exits.
final class VirtualDisplay {
    /// "Looks like" sizes offered in System Settings > Displays, all HiDPI (2 pixels per point).
    /// At 1x a 10" 1404x1872 panel makes text tiny, so the first one (exactly 2x) is selected at
    /// launch; the smaller ones make text even larger (the capture scales their 1200x1600 or
    /// 1080x1440 backing up to the tablet's pixels, slightly softer). Native 1x stays available.
    static let pointSizes = [(702, 936), (600, 800), (540, 720)]

    private let display: CGVirtualDisplay

    var displayID: CGDirectDisplayID { display.displayID }

    init() {
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "reMarkable 2"
        descriptor.maxPixelsWide = UInt32(displayWidth)
        descriptor.maxPixelsHigh = UInt32(displayHeight)
        let mmPerPixel = 25.4 / 226
        descriptor.sizeInMillimeters = CGSize(width: Double(displayWidth) * mmPerPixel,
                                              height: Double(displayHeight) * mmPerPixel)
        descriptor.vendorID = 0x524D  // "RM", arbitrary
        descriptor.productID = 0x0002
        descriptor.serialNum = 0x0001

        display = CGVirtualDisplay(descriptor: descriptor)

        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = Self.pointSizes.map { CGVirtualDisplayMode(width: UInt($0.0), height: UInt($0.1), refreshRate: 60) }
            + [CGVirtualDisplayMode(width: UInt(displayWidth), height: UInt(displayHeight), refreshRate: 60)]
        if !display.apply(settings) {
            log("Virtual display: applySettings failed")
        }
        log("Virtual display created, id \(display.displayID)")
        selectDefaultMode(attempts: 20)
    }

    /// Switches to the first HiDPI size. The modes only become visible shortly after creation,
    /// so this retries for a few seconds.
    private func selectDefaultMode(attempts: Int) {
        let (w, h) = Self.pointSizes[0]
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode] ?? []
        if let mode = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == 2 * w }) {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayWithDisplayMode(config, display.displayID, mode, nil)
            let error = CGCompleteDisplayConfiguration(config, .forSession)
            log("Virtual display mode \(w)x\(h) HiDPI: \(error == .success ? "set" : "failed (\(error.rawValue))")")
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in self?.selectDefaultMode(attempts: attempts - 1) }
        } else {
            log("Virtual display mode \(w)x\(h) HiDPI not available")
        }
    }

    /// Gives only this display a plain white desktop, so a rotating wallpaper doesn't cause
    /// constant e-ink updates. Returns false if the display has no NSScreen yet.
    /// This display's NSScreen, once macOS has set it up.
    var screen: NSScreen? {
        NSScreen.screens.first { $0.deviceDescription[NSDeviceDescriptionKey("NSScreenNumber")] as? CGDirectDisplayID == displayID }
    }

    func setWhiteDesktop() -> Bool {
        guard let screen else { return false }
        do {
            try NSWorkspace.shared.setDesktopImageURL(try whitePNG(), for: screen, options: [
                .imageScaling: NSImageScaling.scaleAxesIndependently.rawValue,
                .allowClipping: true,
                .fillColor: NSColor.white,
            ])
            log("Virtual display desktop set to white")
        } catch {
            log("Could not set virtual display desktop: \(error.localizedDescription)")
        }
        return true
    }

    /// A 1x1 white PNG in Application Support/RM2Sidecar.
    private func whitePNG() throws -> URL {
        let dir = FileManager.default.urls(for: .applicationSupportDirectory, in: .userDomainMask)[0]
            .appendingPathComponent("RM2Sidecar")
        let url = dir.appendingPathComponent("white.png")
        if FileManager.default.fileExists(atPath: url.path) { return url }
        try FileManager.default.createDirectory(at: dir, withIntermediateDirectories: true)
        let rep = NSBitmapImageRep(bitmapDataPlanes: nil, pixelsWide: 1, pixelsHigh: 1, bitsPerSample: 8,
                                   samplesPerPixel: 1, hasAlpha: false, isPlanar: false,
                                   colorSpaceName: .deviceWhite, bytesPerRow: 1, bitsPerPixel: 8)!
        rep.bitmapData![0] = 255
        try rep.representation(using: .png, properties: [:])!.write(to: url)
        return url
    }
}
