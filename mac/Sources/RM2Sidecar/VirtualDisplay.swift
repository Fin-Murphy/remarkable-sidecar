import AppKit
import CPrivate

let displayWidth = 1404
let displayHeight = 1872

/// A virtual display for the reMarkable 2 panel (1404x1872, 226 dpi), portrait or landscape
/// (1872x1404). Removed when this object is released or the process exits.
final class VirtualDisplay {
    /// "Looks like" sizes offered in System Settings > Displays, all HiDPI (2 pixels per point),
    /// given for portrait; landscape offers the same sizes turned sideways.
    /// At 1x a 10" 1404x1872 panel makes text tiny, so the first one (exactly 2x) is selected at
    /// launch; the smaller ones make text even larger (the capture scales their 1200x1600 or
    /// 1080x1440 backing up to the tablet's pixels, slightly softer). Native 1x stays available.
    static let pointSizes = [(702, 936), (600, 800), (540, 720)]

    private let display: CGVirtualDisplay
    private var orientation: Orientation
    private var selecting = 0  // bumps per mode selection, so an older one's retries stop

    var displayID: CGDirectDisplayID { display.displayID }

    init(orientation: Orientation) {
        self.orientation = orientation
        let descriptor = CGVirtualDisplayDescriptor()
        descriptor.setDispatchQueue(DispatchQueue.main)
        descriptor.name = "reMarkable 2"
        // Room for both orientations.
        descriptor.maxPixelsWide = UInt32(max(displayWidth, displayHeight))
        descriptor.maxPixelsHigh = UInt32(max(displayWidth, displayHeight))
        let mmPerPixel = 25.4 / 226
        descriptor.sizeInMillimeters = CGSize(width: Double(displayWidth) * mmPerPixel,
                                              height: Double(displayHeight) * mmPerPixel)
        descriptor.vendorID = 0x524D  // "RM", arbitrary
        descriptor.productID = 0x0002
        descriptor.serialNum = 0x0001

        display = CGVirtualDisplay(descriptor: descriptor)
        log("Virtual display created, id \(display.displayID)")
        applyModes()
        selectMode(size: 0, attempts: 20)
    }

    /// Switches between portrait and landscape modes, keeping the chosen text size.
    func setOrientation(_ new: Orientation) {
        let wasLandscape = orientation.isLandscape
        orientation = new
        guard new.isLandscape != wasLandscape else { return }  // same modes; only the frames turn the other way
        let size = currentSize()
        applyModes()
        selectMode(size: size, attempts: 20)
    }

    /// Mode sizes in points for the current orientation: pointSizes, then native 1x.
    private var modeSizes: [(width: Int, height: Int)] {
        (Self.pointSizes + [(displayWidth, displayHeight)]).map { orientation.isLandscape ? ($0.1, $0.0) : ($0.0, $0.1) }
    }

    private func applyModes() {
        let settings = CGVirtualDisplaySettings()
        settings.hiDPI = 1
        settings.modes = modeSizes.map { CGVirtualDisplayMode(width: UInt($0.width), height: UInt($0.height), refreshRate: 60) }
        if !display.apply(settings) {
            log("Virtual display: applySettings failed")
        }
    }

    /// The index in modeSizes of the current mode (whichever orientation it has), or 0.
    private func currentSize() -> Int {
        guard let mode = CGDisplayCopyDisplayMode(display.displayID) else { return 0 }
        if mode.pixelWidth == mode.width { return Self.pointSizes.count }  // native 1x
        let portrait = (min(mode.width, mode.height), max(mode.width, mode.height))
        return Self.pointSizes.firstIndex { $0 == portrait } ?? 0
    }

    /// Switches to modeSizes[size] (HiDPI, except native). New modes only become visible shortly
    /// after they are applied, so this retries for a few seconds.
    private func selectMode(size: Int, attempts: Int) {
        selecting += 1
        selectMode(size: size, attempts: attempts, selection: selecting)
    }

    private func selectMode(size: Int, attempts: Int, selection: Int) {
        guard selection == selecting else { return }
        let (w, h) = modeSizes[size]
        let scale = size == Self.pointSizes.count ? 1 : 2
        let name = "\(w)x\(h)\(scale == 2 ? " HiDPI" : "")"
        let options = [kCGDisplayShowDuplicateLowResolutionModes: true] as CFDictionary
        let modes = CGDisplayCopyAllDisplayModes(display.displayID, options) as? [CGDisplayMode] ?? []
        if let mode = modes.first(where: { $0.width == w && $0.height == h && $0.pixelWidth == scale * w }) {
            var config: CGDisplayConfigRef?
            CGBeginDisplayConfiguration(&config)
            CGConfigureDisplayWithDisplayMode(config, display.displayID, mode, nil)
            let error = CGCompleteDisplayConfiguration(config, .forSession)
            log("Virtual display mode \(name): \(error == .success ? "set" : "failed (\(error.rawValue))")")
        } else if attempts > 0 {
            DispatchQueue.main.asyncAfter(deadline: .now() + 0.25) { [weak self] in
                self?.selectMode(size: size, attempts: attempts - 1, selection: selection)
            }
        } else {
            log("Virtual display mode \(name) not available")
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
