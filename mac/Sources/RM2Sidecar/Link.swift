import CPrivate
import Foundation
import Network

struct InputEvent {
    enum Kind: UInt8 {
        case hoverMove = 0, penDown, penMove, penUp, touchTap, touchLongPress
    }
    var kind: Kind
    var x: Int
    var y: Int
    var pressure: Int
}

/// TCP client for the tablet. Speaks the protocol in PROTOCOL.md and reconnects every 2 s
/// while `start()`ed. All callbacks run on `queue`.
final class Link {
    var onStatus: (String) -> Void = { _ in }
    var onHello: () -> Void = {}
    var onInput: (InputEvent) -> Void = { _ in }
    var onDrained: () -> Void = {}

    /// HELLO received; frames may be sent.
    private(set) var ready = false
    /// A send is still being handed to the kernel. Callers skip frames rather than queue them.
    private(set) var busy = false

    private let host: String
    private let port: UInt16
    private let queue: DispatchQueue
    private var connection: NWConnection?
    private var wanted = false
    private var rx: [UInt8] = []

    init(host: String, port: UInt16, queue: DispatchQueue) {
        self.host = host
        self.port = port
        self.queue = queue
    }

    func start() {
        wanted = true
        if connection == nil { connect() }
    }

    func stop() {
        wanted = false
        close()
        onStatus("Disconnected")
    }

    func send(_ data: Data) {
        guard let connection else { return }
        busy = true
        connection.send(content: data, completion: .contentProcessed { [weak self] error in
            guard let self, connection === self.connection else { return }
            self.busy = false
            if let error { self.drop("send failed: \(error)") } else { self.onDrained() }
        })
    }

    private func connect() {
        let tcp = NWProtocolTCP.Options()
        tcp.noDelay = true
        tcp.connectionTimeout = 3
        // Notice a pulled USB cable within a few seconds.
        tcp.enableKeepalive = true
        tcp.keepaliveIdle = 2
        tcp.keepaliveInterval = 1
        tcp.keepaliveCount = 3

        let connection = NWConnection(host: NWEndpoint.Host(host), port: NWEndpoint.Port(rawValue: port)!,
                                      using: NWParameters(tls: nil, tcp: tcp))
        self.connection = connection
        onStatus("Connecting to \(host):\(port)…")
        connection.stateUpdateHandler = { [weak self] state in
            guard let self, connection === self.connection else { return }
            switch state {
            case .ready:
                self.onStatus("Connected, waiting for HELLO")
                self.receive(on: connection)
            case .waiting(let error), .failed(let error):
                self.drop("\(error)")
            default:
                break
            }
        }
        connection.start(queue: queue)
    }

    private func close() {
        connection?.cancel()
        connection = nil
        ready = false
        busy = false
        rx.removeAll()
    }

    private func drop(_ reason: String) {
        log("Connection dropped: \(reason)")
        close()
        guard wanted else { return }
        onStatus("Disconnected (\(reason)), retrying")
        queue.asyncAfter(deadline: .now() + 2) { [weak self] in
            guard let self, self.wanted, self.connection == nil else { return }
            self.connect()
        }
    }

    private func receive(on connection: NWConnection) {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65536) { [weak self] data, _, isComplete, error in
            guard let self, connection === self.connection else { return }
            if let data { self.rx += data }
            if let problem = self.parse() { return self.drop(problem) }
            if let error { return self.drop("\(error)") }
            if isComplete { return self.drop("closed by tablet") }
            self.receive(on: connection)
        }
    }

    /// Consumes complete messages from `rx`. Returns an error description on a protocol violation.
    private func parse() -> String? {
        func u16(_ i: Int) -> Int { Int(rx[i]) | Int(rx[i + 1]) << 8 }

        while let type = rx.first {
            switch type {
            case 0x81:  // HELLO
                guard rx.count >= 11 else { return nil }
                guard rx[1...4].elementsEqual("RMSC".utf8) else { return "bad HELLO magic" }
                guard u16(5) == 1 else { return "unsupported protocol version \(u16(5))" }
                guard u16(7) == displayWidth, u16(9) == displayHeight else {
                    return "tablet size \(u16(7))x\(u16(9)) is not \(displayWidth)x\(displayHeight)"
                }
                rx.removeFirst(11)
                ready = true
                onStatus("Connected to \(host)")
                onHello()
            case 0x90:  // INPUT
                guard rx.count >= 8 else { return nil }
                guard let kind = InputEvent.Kind(rawValue: rx[1]) else { return "unknown input kind \(rx[1])" }
                let event = InputEvent(kind: kind, x: u16(2), y: u16(4), pressure: u16(6))
                rx.removeFirst(8)
                if ready { onInput(event) }
            default:
                return String(format: "unknown message type 0x%02x", type)
            }
        }
        return nil
    }
}

// MARK: - Encoding (Mac -> tablet)

enum Message {
    static let fullRefresh = Data([0x02])
    static let frameEnd = Data([0x03])

    /// RECT with the pixels of `rect` taken from `frame` (displayWidth wide), zlib-compressed.
    static func rect(_ rect: DirtyRect, from frame: [UInt8], hint: UInt8) -> Data {
        var pixels = [UInt8]()
        pixels.reserveCapacity(rect.w * rect.h)
        for y in rect.y..<(rect.y + rect.h) {
            let start = y * displayWidth + rect.x
            pixels += frame[start..<(start + rect.w)]
        }
        let payload = zlibCompress(pixels)

        var data = Data([0x01])
        for v in [rect.x, rect.y, rect.w, rect.h] { appendLE(&data, UInt16(v)) }
        data.append(hint)
        appendLE(&data, UInt32(payload.count))
        data += payload
        return data
    }

    private static func appendLE<T: FixedWidthInteger>(_ data: inout Data, _ value: T) {
        withUnsafeBytes(of: value.littleEndian) { data.append(contentsOf: $0) }
    }

    private static func zlibCompress(_ input: [UInt8]) -> [UInt8] {
        var length = compressBound(uLong(input.count))
        var output = [UInt8](repeating: 0, count: Int(length))
        let status = compress2(&output, &length, input, uLong(input.count), 6)
        precondition(status == Z_OK, "zlib compress2 failed: \(status)")
        return Array(output[..<Int(length)])
    }
}
