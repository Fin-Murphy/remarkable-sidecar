import AppKit
import ApplicationServices

/// Turns tablet INPUT events into CGEvents on the virtual display. Needs Accessibility.
final class InputInjector {
    private let displayID: CGDirectDisplayID
    private(set) var penDown = false
    private var lastDown: (time: Date, point: CGPoint)?
    private var clickCount = 1
    private var warnedNoAccess = false

    init(displayID: CGDirectDisplayID) {
        self.displayID = displayID
    }

    func handle(_ event: InputEvent) {
        guard AXIsProcessTrusted() else {
            if !warnedNoAccess { log("Input ignored: Accessibility permission not granted") }
            warnedNoAccess = true
            return
        }
        warnedNoAccess = false

        // Tablet pixels -> global points. Works for both the 1x and the HiDPI mode.
        let bounds = CGDisplayBounds(displayID)
        let x = Double(min(max(event.x, 0), displayWidth - 1)) + 0.5
        let y = Double(min(max(event.y, 0), displayHeight - 1)) + 0.5
        let point = CGPoint(x: bounds.minX + x * bounds.width / Double(displayWidth),
                            y: bounds.minY + y * bounds.height / Double(displayHeight))

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
