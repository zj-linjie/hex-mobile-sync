import Foundation
import HexMobileCore
import Network

/// Pulls the pending dictation from the app over 127.0.0.1 (see the app's
/// `LoopbackHandoff`). Needs Full Access.
enum LoopbackClient {
    static func pull(timeout: TimeInterval = 1.5) async -> DictationPayload? {
        let data = await Puller(request: HexMobileIPC.loopbackRequest, timeout: timeout).run()
        guard let data else { return nil }
        return try? DictationPayload.decode(from: data)
    }

    /// Why the app's last start or dictation failed; `nil` when the app is
    /// unreachable or has nothing to report.
    static func error(timeout: TimeInterval = 0.6) async -> String? {
        guard let data = await Puller(request: HexMobileIPC.loopbackErrorRequest, timeout: timeout).run() else {
            return nil
        }
        return String(data: data, encoding: .utf8)
    }

    /// The microphone level (0...1) and the live transcript while the app
    /// records; `nil` when unreachable.
    static func live(timeout: TimeInterval = 0.4) async -> (level: Float, text: String)? {
        guard let data = await Puller(request: HexMobileIPC.loopbackLiveLevelRequest, timeout: timeout).run(),
              let reply = String(data: data, encoding: .utf8) else {
            return nil
        }
        return HexMobileIPC.parseLiveLevelReply(reply)
    }

    /// The recent dictations, newest first. Only served inside the window
    /// the app opens after this keyboard posts ``HexMobileIPC/Signal/recent``
    /// (see `KeyboardModel.insertLongPressed`); empty when unreachable.
    static func recent(timeout: TimeInterval = 1.5) async -> [DictationPayload] {
        guard let data = await Puller(request: HexMobileIPC.loopbackRecentRequest, timeout: timeout).run() else {
            return []
        }
        return (try? DictationPayload.decodeArray(from: data)) ?? []
    }
}

/// One request: connect, send the request line, read until the app closes.
/// All state is touched only on `queue`.
private final class Puller: @unchecked Sendable {
    private let queue = DispatchQueue(label: "hexmobile.keyboard.loopback")
    private let connection = NWConnection(
        host: .ipv4(.loopback),
        port: NWEndpoint.Port(rawValue: HexMobileIPC.loopbackPort)!,
        using: .tcp
    )
    private let timeout: TimeInterval
    private let request: String
    private var buffer = Data()
    private var continuation: CheckedContinuation<Data?, Never>?

    init(request: String, timeout: TimeInterval) {
        self.request = request
        self.timeout = timeout
    }

    func run() async -> Data? {
        await withCheckedContinuation { continuation in
            queue.async {
                self.continuation = continuation
                self.connection.stateUpdateHandler = { [self] state in
                    switch state {
                    case .ready:
                        connection.send(content: Data(request.utf8), completion: .contentProcessed { _ in })
                        receive()
                    case .failed, .cancelled, .waiting:
                        finish(nil)
                    default:
                        break
                    }
                }
                self.connection.start(queue: self.queue)
                self.queue.asyncAfter(deadline: .now() + self.timeout) { self.finish(nil) }
            }
        }
    }

    private func receive() {
        connection.receive(minimumIncompleteLength: 1, maximumLength: 65_536) { [self] chunk, _, isComplete, error in
            if let chunk { buffer.append(chunk) }
            if isComplete || error != nil || buffer.count > 1_000_000 {
                finish(buffer.isEmpty ? nil : buffer)
            } else {
                receive()
            }
        }
    }

    private func finish(_ value: Data?) {
        guard let continuation else { return }
        self.continuation = nil
        connection.cancel()
        continuation.resume(returning: value)
    }
}
