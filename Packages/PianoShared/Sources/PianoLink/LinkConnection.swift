import Foundation
import Network

/// All framing state is confined to its private serial queue.
final class LinkConnection: @unchecked Sendable {
    let id = UUID()
    let connection: NWConnection
    private let queue = DispatchQueue(label: "com.pianovision.link.connection")
    private var buffer = Data()
    private var closed = false
    private let onPacket: @Sendable (UUID, LinkPacket) -> Void
    private let onState: @Sendable (UUID, String, Bool) -> Void

    init(connection: NWConnection,
         onPacket: @escaping @Sendable (UUID, LinkPacket) -> Void,
         onState: @escaping @Sendable (UUID, String, Bool) -> Void) {
        self.connection = connection
        self.onPacket = onPacket
        self.onState = onState
    }

    func start() {
        connection.stateUpdateHandler = { [weak self] state in
            guard let self else { return }
            switch state {
            case .ready:
                self.onState(self.id, "ready", true)
            case .failed(let error), .waiting(let error):
                self.onState(self.id, error.localizedDescription, false)
                self.cancel()
            case .cancelled:
                self.onState(self.id, "disconnected", false)
            default: break
            }
        }
        connection.start(queue: queue)
        receive()
    }

    func send(_ packet: LinkPacket) {
        queue.async { [weak self] in
            guard let self, !self.closed, let encoded = try? JSONEncoder().encode(packet),
                  encoded.count <= 65_536 else { return }
            let count = UInt32(encoded.count)
            var data = Data([UInt8((count >> 24) & 255), UInt8((count >> 16) & 255),
                             UInt8((count >> 8) & 255), UInt8(count & 255)])
            data.append(encoded)
            self.connection.send(content: data, completion: .contentProcessed { [weak self] error in
                if let error, let self { self.onState(self.id, error.localizedDescription, false); self.cancel() }
            })
        }
    }

    func cancel() {
        // Retain through the queued cancellation: owners intentionally drop their
        // last reference immediately when disconnecting.
        queue.async { [self] in
            guard !self.closed else { return }
            self.closed = true
            self.buffer.removeAll()
            self.connection.cancel()
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_540) { [weak self] data, _, complete, error in
            guard let self, !self.closed else { return }
            if let data {
                self.buffer.append(data)
                while self.buffer.count >= 4 {
                    let prefix = Array(self.buffer.prefix(4))
                    let length = prefix.reduce(0) { ($0 << 8) | Int($1) }
                    guard length > 0, length <= 65_536 else {
                        self.onState(self.id, "Invalid bridge packet length", false)
                        self.cancel()
                        return
                    }
                    guard self.buffer.count >= length + 4 else { break }
                    let payload = Data(self.buffer.dropFirst(4).prefix(length))
                    self.buffer.removeFirst(length + 4)
                    guard let packet = try? JSONDecoder().decode(LinkPacket.self, from: payload) else {
                        self.onState(self.id, "Invalid bridge message", false)
                        self.cancel()
                        return
                    }
                    self.onPacket(self.id, packet)
                }
            }
            if complete || error != nil {
                self.onState(self.id, error?.localizedDescription ?? "Bridge closed the connection", false)
                self.cancel()
            } else { self.receive() }
        }
    }
}
