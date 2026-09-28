import Foundation

/// How the tablet is held. The tablet always shows frames, and reports input, in its portrait panel
/// coordinates (displayWidth x displayHeight, the thick edge on the left). In landscape the Mac's
/// virtual display is displayHeight x displayWidth, and frames and input are turned 90° between the two.
enum Orientation: String, CaseIterable {
    case portrait
    case landscapeGripDown  // turned counter-clockwise: the thick edge at the bottom
    case landscapeGripUp    // turned clockwise: the thick edge at the top

    var isLandscape: Bool { self != .portrait }

    /// The virtual display's size in pixels.
    var displaySize: (width: Int, height: Int) {
        isLandscape ? (displayHeight, displayWidth) : (displayWidth, displayHeight)
    }

    /// The display pixel that the panel pixel (x, y) shows. Both frames and input use this, so a pen
    /// tap lands on what is drawn under it.
    @inline(__always)
    func displayPoint(panelX x: Int, panelY y: Int) -> (x: Int, y: Int) {
        switch self {
        case .portrait: return (x, y)
        case .landscapeGripDown: return (y, displayWidth - 1 - x)
        case .landscapeGripUp: return (displayHeight - 1 - y, x)
        }
    }

    /// Turns a display frame (8-bit gray, rows `stride` bytes apart) into a panel frame.
    func panelFrame(from display: UnsafePointer<UInt8>, stride: Int) -> [UInt8] {
        var panel = [UInt8](repeating: 0, count: displayWidth * displayHeight)
        panel.withUnsafeMutableBufferPointer { buffer in
            let out = buffer.baseAddress!
            if self == .portrait {
                for y in 0..<displayHeight { memcpy(out + y * displayWidth, display + y * stride, displayWidth) }
                return
            }
            for y in 0..<displayHeight {
                for x in 0..<displayWidth {
                    let p = displayPoint(panelX: x, panelY: y)
                    out[y * displayWidth + x] = display[p.y * stride + p.x]
                }
            }
        }
        return panel
    }
}
