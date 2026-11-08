import Foundation
import HexMobileCore
import Network

/// Hands the latest dictation to the keyboard over a loopback socket.
///
/// iOS silently drops pasteboard writes made while the app is in the
/// background (measured 1 Nov 2026, iOS 27.2: `changeCount` unchanged), and
/// a free signing team cannot use an App Group. The keyboard has Full Access
/// and may open a connection to 127.0.0.1, so the app listens there only
/// while a result is pending.
///
/// Exposure: any process on the iPhone could connect in that window. The
/// listener binds to loopback only, serves one result once and closes after
/// ``ttl`` seconds, so a result is never served twice or kept around.
@MainActor
final class LoopbackHandoff {
    static let shared = LoopbackHandoff()
    static let ttl: TimeInterval = 60

    /// How a pending payload left: the keyboard took it, or ``ttl`` ran out.
    /// Not reported when a newer payload replaces it.
    enum Settlement: String, Sendable {
        case served
        case expired
    }

    /// Called once per payload that settles. A flow session opened by the
    /// Action Button waits for it before closing: while the audio runs the
    /// app stays alive for the keyboard's pull, and it would not otherwise
    /// (the pull came 4 to 39 s after `done` in the device log of 1 Nov 2026).
    var onSettled: (@MainActor (Settlement) -> Void)?

    /// Whether a payload is waiting for the keyboard.
    var hasPending: Bool { pending != nil }

    /// The text of the pending payload, for the Live Activity that tells the
    /// user to open the keyboard. Follows ``pending``: cleared with it.
    private(set) var pendingText: String?

    /// The most recent dictations, newest first, for the keyboard's
    /// long-press picker (`loopbackRecentRequest`). Memory only, and served
    /// only inside the window ``prepareRecentWindow()`` opens — the listener
    /// must not be reachable at any random time, any local process could
    /// connect to it.
    private(set) var recent: [DictationPayload] = []
    private static let recentLimit = 8
    private var recentWindow: Task<Void, Never>?

    /// Records a finished dictation for the recent list. Newest first; a
    /// payload already in the list moves to the front; the oldest drops out.
    func remember(_ payload: DictationPayload) {
        recent.removeAll { $0.id == payload.id }
        recent.insert(payload, at: 0)
        if recent.count > Self.recentLimit {
            recent.removeLast(recent.count - Self.recentLimit)
        }
    }

    /// Opens the listener for a few seconds so the keyboard can pull the
    /// recent list. The keyboard posts ``HexMobileIPC/Signal/recent`` first:
    /// the window exists only around that explicit user action.
    func prepareRecentWindow() {
        startIfNeeded()
        recentWindow?.cancel()
        recentWindow = Task { [weak self] in
            try? await Task.sleep(for: .seconds(6))
            guard !Task.isCancelled, let self else { return }
            self.stopIfIdle()
        }
    }

    private var listener: NWListener?
    private var pending: Data? {
        didSet { if pending == nil { pendingText = nil } }
    }
    /// Live transcript while recording; `nil` when not recording.
    private var live: String?
    /// Microphone level 0...1 while recording, for the keyboard's level display.
    private var level: Float = 0
    /// Why the last start or dictation failed, for the keyboard (see
    /// ``setError(_:)``); `nil` when nothing failed or the keyboard took over.
    private var error: String?
    private var errorExpiry: Task<Void, Never>?
    private var expiry: Task<Void, Never>?
    private let queue = DispatchQueue(label: "hexmobile.loopback")

    /// Offers `payload` to the next keyboard request within ``ttl`` seconds.
    func offer(_ payload: DictationPayload) {
        guard let data = try? payload.encoded() else { return }
        pending = data
        pendingText = payload.text
        startIfNeeded()
        expiry?.cancel()
        expiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ttl))
            guard !Task.isCancelled, let self else { return }
            let wasPending = self.pending != nil
            self.pending = nil
            self.stopIfIdle()
            if wasPending {
                Diagnostics.record("loopback expired after \(Int(Self.ttl))s, never pulled")
                self.onSettled?(.expired)
            }
        }
    }

    /// Live transcript for the keyboard while recording; `nil` ends it.
    func setLive(_ text: String?) {
        live = text.map { String($0.suffix(400)) }
        if live != nil {
            startIfNeeded()
        } else {
            stopIfIdle()
        }
    }

    /// The level the keyboard's microphone key draws; the app's level meter
    /// calls this every 33 ms. It never opens the listener (``setLive(_:)`` does).
    func setLevel(_ value: Float) {
        level = min(max(value, 0), 1)
    }

    /// Whether a failure reason is waiting for the keyboard.
    var hasError: Bool { error != nil }

    /// The reason a start or dictation failed, for the keyboard to read after
    /// ``HexMobileIPC/Signal/startFailed``. Served any number of times (the
    /// keyboard may ask again after it was hidden) until ``ttl`` runs out, a
    /// new dictation starts (`nil`) or the user closes the message. It is the
    /// system's or the app's error text, never dictated text.
    func setError(_ message: String?) {
        errorExpiry?.cancel()
        errorExpiry = nil
        error = message.map { String($0.prefix(300)) }
        guard error != nil else {
            stopIfIdle()
            return
        }
        startIfNeeded()
        errorExpiry = Task { [weak self] in
            try? await Task.sleep(for: .seconds(Self.ttl))
            guard !Task.isCancelled, let self else { return }
            self.error = nil
            self.stopIfIdle()
        }
    }

    /// Closes the listener when nothing is left to serve.
    private func stopIfIdle() {
        if pending == nil, live == nil, error == nil { stop() }
    }

    private func startIfNeeded() {
        guard listener == nil else { return }
        do {
            let parameters = NWParameters.tcp
            parameters.requiredLocalEndpoint = .hostPort(host: .ipv4(.loopback), port: NWEndpoint.Port(rawValue: HexMobileIPC.loopbackPort)!)
            parameters.allowLocalEndpointReuse = true
            let listener = try NWListener(using: parameters)
            listener.newConnectionHandler = { [weak self] connection in
                Task { @MainActor in self?.serve(connection) }
            }
            listener.stateUpdateHandler = { state in
                if case .failed(let error) = state {
                    Task { @MainActor in Diagnostics.record("loopback failed \(error)") }
                }
            }
            listener.start(queue: queue)
            self.listener = listener
        } catch {
            Diagnostics.record("loopback listen error \(error)")
        }
    }

    private func serve(_ connection: NWConnection) {
        connection.start(queue: queue)
        connection.receive(minimumIncompleteLength: 1, maximumLength: 64) { [weak self] data, _, _, _ in
            Task { @MainActor in
                guard let self else { connection.cancel(); return }
                let request = data.flatMap { String(data: $0, encoding: .utf8) }
                if request == HexMobileIPC.loopbackLiveRequest {
                    let reply = Data((self.live ?? "").utf8)
                    connection.send(content: reply, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                if request == HexMobileIPC.loopbackLiveLevelRequest {
                    let reply = Data((String(format: "%.2f", self.live == nil ? 0 : self.level) + "\n" + (self.live ?? "")).utf8)
                    connection.send(content: reply, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                if request == HexMobileIPC.loopbackErrorRequest {
                    let reply = Data((self.error ?? "").utf8)
                    connection.send(content: reply, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                if request == HexMobileIPC.loopbackRecentRequest {
                    let reply = (try? DictationPayload.encodeArray(self.recent)) ?? Data("[]".utf8)
                    connection.send(content: reply, isComplete: true, completion: .contentProcessed { _ in
                        connection.cancel()
                    })
                    return
                }
                guard request == HexMobileIPC.loopbackRequest, let payload = self.pending else {
                    connection.cancel()
                    return
                }
                self.pending = nil
                Diagnostics.record("loopback served \(payload.count) bytes")
                // The settlement waits for the send: whoever closes the session
                // on it must not cut the reply short.
                connection.send(content: payload, isComplete: true, completion: .contentProcessed { error in
                    connection.cancel()
                    Task { @MainActor in
                        if let error { Diagnostics.record("loopback send error \(error)") }
                        self.onSettled?(.served)
                    }
                })
                self.stopIfIdle()
            }
        }
    }

    private func stop() {
        expiry?.cancel()
        expiry = nil
        errorExpiry?.cancel()
        errorExpiry = nil
        recentWindow?.cancel()
        recentWindow = nil
        pending = nil
        live = nil
        level = 0
        error = nil
        listener?.cancel()
        listener = nil
    }
}
