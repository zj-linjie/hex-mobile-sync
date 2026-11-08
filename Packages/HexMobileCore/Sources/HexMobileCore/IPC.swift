import Foundation

/// Identifiers shared by the app and the keyboard extension.
///
/// The app and its extensions cannot share an App Group under a free
/// Personal Team, so they talk through Darwin notifications (no payload) and
/// the general pasteboard. All identifiers are fixed and neutral; they do not
/// depend on the bundle identifier prefix.
public enum HexMobileIPC {
    /// Prefix of every Darwin notification name.
    public static let notificationPrefix = "io.github.hexmobile"

    /// Pasteboard type carrying a JSON ``DictationPayload`` next to the plain text.
    public static let pasteboardType = "io.github.hexmobile.dictation"
    /// Loopback port (127.0.0.1 only) where the app hands the latest result
    /// to the keyboard. iOS drops pasteboard writes from a background app,
    /// so the pasteboard alone fails for Action Button and keyboard starts.
    public static let loopbackPort: UInt16 = 47391
    /// Request line the keyboard sends; the app answers with the payload JSON.
    public static let loopbackRequest = "HEXMOBILE-PULL 1\n"
    /// Request line for the live transcript while recording (UTF-8 reply,
    /// not consumed).
    public static let loopbackLiveRequest = "HEXMOBILE-LIVE 1\n"
    /// Request line for the microphone level and the live transcript while
    /// recording: the reply is the level as `0.00`...`1.00`, a newline, then the
    /// transcript (UTF-8, not consumed). The keyboard polls it about every
    /// 150 ms to draw the level in its microphone key.
    public static let loopbackLiveLevelRequest = "HEXMOBILE-LIVE 2\n"

    /// Splits a reply to ``loopbackLiveLevelRequest`` into the level (clamped to
    /// 0...1; 0 when the first line is not a number) and the transcript.
    public static func parseLiveLevelReply(_ text: String) -> (level: Float, text: String) {
        let parts = text.split(separator: "\n", maxSplits: 1, omittingEmptySubsequences: false)
        let level = parts.first.flatMap { Float($0) } ?? 0
        let transcript = parts.count > 1 ? String(parts[1]) : ""
        return (min(max(level, 0), 1), transcript)
    }

    /// Request line for the reason of the last failed start or dictation
    /// (UTF-8 reply, empty when none; not consumed). The keyboard sends it
    /// after ``Signal/startFailed``, which carries no text.
    public static let loopbackErrorRequest = "HEXMOBILE-ERROR 1\n"
    /// Request line for the recent dictations: the reply is a JSON array of
    /// ``DictationPayload`` (newest first, not consumed). The listener only
    /// serves it inside the window a ``Signal/recent`` opens, so dictated
    /// text is not reachable on the port at any random time.
    public static let loopbackRecentRequest = "HEXMOBILE-RECENT 1\n"

    /// Uniform type identifier of the plain-text pasteboard representation.
    public static let plainTextPasteboardType = "public.utf8-plain-text"

    /// URL scheme of the app.
    public static let urlScheme = "hexmobile"

    /// Darwin notifications exchanged between the app and the keyboard.
    public enum Signal: String, CaseIterable, Sendable {
        /// Keyboard → app: is a flow session alive?
        case ping = "io.github.hexmobile.ping"
        /// App → keyboard: a flow session is alive (answer to ``ping``).
        case pong = "io.github.hexmobile.pong"
        /// Keyboard → app: start dictation when idle, otherwise stop it.
        case toggle = "io.github.hexmobile.toggle"
        /// App → keyboard: recording.
        case stateRecording = "io.github.hexmobile.state.recording"
        /// App → keyboard: transcribing and processing.
        case stateProcessing = "io.github.hexmobile.state.processing"
        /// App → keyboard: idle, session still alive.
        case stateIdle = "io.github.hexmobile.state.idle"
        /// App → keyboard: a result is on the pasteboard.
        case done = "io.github.hexmobile.done"
        /// App → keyboard: no flow session (it ended, or the app ignored a
        /// ``toggle`` because none was running). The keyboard shows how to start one.
        case sessionEnded = "io.github.hexmobile.session.ended"
        /// Keyboard → app: abandon the dictation in progress without a result
        /// (the ✕ key). Unlike ``toggle``, which stops and transcribes, nothing
        /// is written to the pasteboard, offered over loopback or added to the
        /// history.
        case cancel = "io.github.hexmobile.cancel"
        /// App → keyboard: a dictation could not start or failed. The reason is
        /// on loopback (``HexMobileIPC/loopbackErrorRequest``); the keyboard shows
        /// it with Close and Retry.
        case startFailed = "io.github.hexmobile.start.failed"
        /// Keyboard → app: the user held the insert key and is about to ask
        /// for the recent dictations. The app opens its loopback listener for
        /// a few seconds so the ``loopbackRecentRequest`` can be served; the
        /// listener must not be up at any random time (any local process
        /// could connect to it).
        case recent = "io.github.hexmobile.recent"

        /// The Darwin notification name.
        public var name: String { rawValue }

        /// The signal with Darwin notification `name`, if it is one of ours.
        public init?(name: String) {
            self.init(rawValue: name)
        }
    }

    /// The state of a flow session as announced to the keyboard.
    public enum FlowState: String, CaseIterable, Sendable {
        /// Session alive, not recording.
        case idle
        /// Recording audio.
        case recording
        /// Transcribing and processing.
        case processing

        /// The signal announcing this state.
        public var signal: Signal {
            switch self {
            case .idle: .stateIdle
            case .recording: .stateRecording
            case .processing: .stateProcessing
            }
        }

        /// The state announced by `signal`, if it is a state signal.
        public init?(signal: Signal) {
            switch signal {
            case .stateIdle: self = .idle
            case .stateRecording: self = .recording
            case .stateProcessing: self = .processing
            case .ping, .pong, .toggle, .done, .sessionEnded, .cancel, .startFailed, .recent: return nil
            }
        }
    }

    /// Deep links handled by the app (`hexmobile://…`).
    public enum Route: String, CaseIterable, Sendable {
        /// `hexmobile://session/start`: start a flow session (opened by the keyboard, best effort).
        case sessionStart = "session/start"
        /// `hexmobile://dictate?source=keyboard`: start a flow session if there
        /// is none and start dictating at once, with the app in the foreground
        /// (the microphone key without a session). The app then asks the user to
        /// go back to the previous app; the dictation goes on meanwhile.
        case dictate = "dictate"

        /// The URL that opens this route.
        public var url: URL { url(source: nil) }

        /// The URL that opens this route, with `?source=<source>` when given
        /// (who opened it, for the app's log).
        public func url(source: String?) -> URL {
            var components = URLComponents()
            components.scheme = HexMobileIPC.urlScheme
            let parts = rawValue.split(separator: "/", maxSplits: 1).map(String.init)
            components.host = parts[0]
            components.path = parts.count > 1 ? "/" + parts[1] : ""
            if let source { components.queryItems = [URLQueryItem(name: "source", value: source)] }
            guard let url = components.url else {
                preconditionFailure("Invalid route URL for \(rawValue)")
            }
            return url
        }

        /// The `source` query item of `url`, if any.
        public static func source(of url: URL) -> String? {
            URLComponents(url: url, resolvingAgainstBaseURL: false)?
                .queryItems?.first { $0.name == "source" }?.value
        }

        /// Parses an incoming URL. The scheme and host are compared
        /// case-insensitively; a trailing slash, query and fragment are ignored.
        public init?(url: URL) {
            guard url.scheme?.lowercased() == HexMobileIPC.urlScheme,
                  let host = url.host(percentEncoded: false)?.lowercased(), !host.isEmpty
            else { return nil }
            let path = url.path(percentEncoded: false)
                .split(separator: "/", omittingEmptySubsequences: true)
                .joined(separator: "/")
            let key = path.isEmpty ? host : "\(host)/\(path.lowercased())"
            self.init(rawValue: key)
        }
    }
}
