import AppKit
import ApplicationServices

/// Turns tablet INPUT events into CGEvents on the virtual display. Needs Accessibility.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    var orientation: Orientation
    private(set) var penDown = false
    private var lastDown: (time: Date, point: CGPoint)?
    private var clickCount = 1
    private var warnedNoAccess = false

    init(displayID: CGDirectDisplayID, orientation: Orientation) {
        self.displayID = displayID
        self.orientation = orientation
    }

    func handle(_ event: InputEvent) {
        guard AXIsProcessTrusted() else {
            if !warnedNoAccess { log("Input ignored: Accessibility permission not granted") }
            warnedNoAccess = true
            return
        }
        warnedNoAccess = false

        // Tablet panel pixels -> display pixels -> global points. Works for both the 1x and the HiDPI modes.
        let bounds = CGDisplayBounds(displayID)
        let pixel = orientation.displayPoint(panelX: min(max(event.x, 0), displayWidth - 1),
                                             panelY: min(max(event.y, 0), displayHeight - 1))
        let size = orientation.displaySize
        let point = CGPoint(x: bounds.minX + (Double(pixel.x) + 0.5) * bounds.width / Double(size.width),
                            y: bounds.minY + (Double(pixel.y) + 0.5) * bounds.height / Double(size.height))

        switch event.kind {
        case .hoverMove, .penMove:
            post(penDown ? .leftMouseDragged : .mouseMoved, at: point)
        case .penDown:
            leftDown(at: point)
        case .penUp:
            post(.leftMouseUp, at: point)
            penDown = false
        case .touchTap:
            post(.mouseMoved, at: point)
            leftDown(at: point)
            post(.leftMouseUp, at: point)
            penDown = false
        case .touchLongPress:
            post(.mouseMoved, at: point)
            post(.rightMouseDown, at: point, button: .right)
            post(.rightMouseUp, at: point, button: .right)
        }
    }

    private func leftDown(at point: CGPoint) {
        // Consecutive downs close in time and space form a double click.
        let now = Date()
        if let last = lastDown, now.timeIntervalSince(last.time) < NSEvent.doubleClickInterval,
           hypot(point.x - last.point.x, point.y - last.point.y) < 8 {
            clickCount += 1
        } else {
            clickCount = 1
        }
        lastDown = (now, point)
        penDown = true
        post(.leftMouseDown, at: point)
    }

    private func post(_ type: CGEventType, at point: CGPoint, button: CGMouseButton = .left) {
        guard let event = CGEvent(mouseEventSource: nil, mouseType: type, mouseCursorPosition: point, mouseButton: button)
        else { return }
        if type == .leftMouseDown || type == .leftMouseUp || type == .leftMouseDragged {
            event.setIntegerValueField(.mouseEventClickState, value: Int64(clickCount))
        }
        event.post(tap: .cghidEventTap)
    }
}
