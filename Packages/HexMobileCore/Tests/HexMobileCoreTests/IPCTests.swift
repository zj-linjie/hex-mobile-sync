import Foundation
import Testing
@testable import HexMobileCore

@Suite("IPC constants and routes")
struct IPCTests {
    @Test("Darwin notification names match the PLAN")
    func signalNames() {
        #expect(HexMobileIPC.Signal.allCases.map(\.name) == [
            "io.github.hexmobile.ping",
            "io.github.hexmobile.pong",
            "io.github.hexmobile.toggle",
            "io.github.hexmobile.state.recording",
            "io.github.hexmobile.state.processing",
            "io.github.hexmobile.state.idle",
            "io.github.hexmobile.done",
            "io.github.hexmobile.session.ended",
            "io.github.hexmobile.cancel",
            "io.github.hexmobile.start.failed",
            "io.github.hexmobile.recent",
        ])
        for signal in HexMobileIPC.Signal.allCases {
            #expect(signal.name.hasPrefix(HexMobileIPC.notificationPrefix + "."))
            #expect(HexMobileIPC.Signal(name: signal.name) == signal)
        }
        #expect(HexMobileIPC.Signal(name: "io.github.hexmobile.unknown") == nil)
    }

    @Test("Pasteboard type and URL scheme match the PLAN")
    func constants() {
        #expect(HexMobileIPC.notificationPrefix == "io.github.hexmobile")
        #expect(HexMobileIPC.pasteboardType == "io.github.hexmobile.dictation")
        #expect(HexMobileIPC.plainTextPasteboardType == "public.utf8-plain-text")
        #expect(HexMobileIPC.urlScheme == "hexmobile")
    }

    @Test("The live level reply splits into a level and the transcript")
    func liveLevelReply() {
        let ok = HexMobileIPC.parseLiveLevelReply("0.42\nprova di dettatura\nseconda riga")
        #expect(ok.level == 0.42)
        #expect(ok.text == "prova di dettatura\nseconda riga")
        #expect(HexMobileIPC.parseLiveLevelReply("0.00\n").text == "")
        #expect(HexMobileIPC.parseLiveLevelReply("1.00").text == "")
        #expect(HexMobileIPC.parseLiveLevelReply("7.5\nx").level == 1)
        #expect(HexMobileIPC.parseLiveLevelReply("-3\nx").level == 0)
        // Not a number: the level is 0 and the rest is still the transcript.
        let odd = HexMobileIPC.parseLiveLevelReply("hello\nworld")
        #expect(odd.level == 0)
        #expect(odd.text == "world")
        #expect(HexMobileIPC.parseLiveLevelReply("").level == 0)
    }

    @Test("Loopback request lines end with a newline and differ")
    func loopbackRequests() {
        let lines = [HexMobileIPC.loopbackRequest, HexMobileIPC.loopbackLiveRequest,
                     HexMobileIPC.loopbackLiveLevelRequest, HexMobileIPC.loopbackErrorRequest]
        #expect(Set(lines).count == lines.count)
        for line in lines {
            #expect(line.hasSuffix("\n"))
            #expect(line.utf8.count <= 64) // the app reads at most 64 bytes
        }
    }

    @Test("Flow states map to state signals and back")
    func flowStates() {
        for state in HexMobileIPC.FlowState.allCases {
            #expect(HexMobileIPC.FlowState(signal: state.signal) == state)
        }
        #expect(HexMobileIPC.FlowState.recording.signal == .stateRecording)
        #expect(HexMobileIPC.FlowState(signal: .ping) == nil)
        #expect(HexMobileIPC.FlowState(signal: .done) == nil)
        #expect(HexMobileIPC.FlowState(signal: .sessionEnded) == nil)
        #expect(HexMobileIPC.FlowState(signal: .cancel) == nil)
        #expect(HexMobileIPC.FlowState(signal: .startFailed) == nil)
    }

    @Test("Route URLs")
    func routeURL() {
        #expect(HexMobileIPC.Route.sessionStart.url.absoluteString == "hexmobile://session/start")
        #expect(HexMobileIPC.Route.dictate.url.absoluteString == "hexmobile://dictate")
        #expect(HexMobileIPC.Route.dictate.url(source: "keyboard").absoluteString == "hexmobile://dictate?source=keyboard")
        #expect(HexMobileIPC.Route.sessionStart.url(source: "keyboard").absoluteString == "hexmobile://session/start?source=keyboard")
    }

    @Test("The route URL the keyboard builds parses back, with its source")
    func routeRoundTrip() {
        for route in HexMobileIPC.Route.allCases {
            #expect(HexMobileIPC.Route(url: route.url) == route)
            let url = route.url(source: "keyboard")
            #expect(HexMobileIPC.Route(url: url) == route)
            #expect(HexMobileIPC.Route.source(of: url) == "keyboard")
            #expect(HexMobileIPC.Route.source(of: route.url) == nil)
        }
    }

    @Test("Route parsing", arguments: [
        ("hexmobile://session/start", Optional(HexMobileIPC.Route.sessionStart)),
        ("HEXMOBILE://Session/Start/", Optional(HexMobileIPC.Route.sessionStart)),
        ("hexmobile://session/start?source=keyboard#x", Optional(HexMobileIPC.Route.sessionStart)),
        ("hexmobile://dictate", Optional(HexMobileIPC.Route.dictate)),
        ("hexmobile://dictate?source=keyboard", Optional(HexMobileIPC.Route.dictate)),
        ("HEXMOBILE://Dictate/", Optional(HexMobileIPC.Route.dictate)),
        ("hexmobile://dictate/now", nil),
        ("hexmobile://session", nil),
        ("hexmobile://session/stop", nil),
        ("https://session/start", nil),
        ("hexmobile:session/start", nil),
    ])
    func routeParsing(input: String, expected: HexMobileIPC.Route?) throws {
        let url = try #require(URL(string: input))
        #expect(HexMobileIPC.Route(url: url) == expected)
    }
}

@Suite("Dictation payload")
struct DictationPayloadTests {
    @Test("Insertable text drops control characters except newline and tab")
    func insertableText() {
        let payload = DictationPayload(text: "Perché\u{1B}[2J sì\r\nriga\ttab\u{7}\u{202E}fine 👩‍💻", createdAt: referenceDate)
        #expect(payload.insertableText == "Perché[2J sì\nriga\ttabfine 👩‍💻")
        #expect(payload.containsLineBreak)
        #expect(!DictationPayload(text: "una riga", createdAt: referenceDate).containsLineBreak)
        #expect(DictationPayload.insertable("a\rb") == "a\nb")
    }

    @Test("Round-trips with snake_case keys")
    func roundTrip() throws {
        let payload = DictationPayload(text: "Perché l'API è pronta?", createdAt: referenceDate, locale: "it-IT", engine: "on-device")
        let data = try payload.encoded()
        let object = try #require(try JSONSerialization.jsonObject(with: data) as? [String: Any])
        #expect(Set(object.keys) == ["schema_version", "id", "text", "created_at", "locale", "engine"])
        #expect(try DictationPayload.decode(from: data) == payload)
    }

    @Test("Optional fields may be absent; unknown keys are ignored")
    func minimal() throws {
        let payload = try DictationPayload.decode(from: json(#"""
        {"schema_version":1,"id":"5D4C2B1A-0000-4000-8000-000000000001","text":"ciao","created_at":"2026-11-01T10:00:00Z","extra":1}
        """#))
        #expect(payload.text == "ciao")
        #expect(payload.locale == nil)
        #expect(payload.engine == nil)
        #expect(payload.createdAt == referenceDate)
    }

    @Test("Future schema and missing text are refused")
    func refused() {
        #expect(throws: SyncCodecError.unsupportedSchemaVersion(found: 2, supported: 1)) {
            try DictationPayload.decode(from: json(#"{"schema_version":2,"id":"5D4C2B1A-0000-4000-8000-000000000001","text":"x","created_at":"2026-11-01T10:00:00Z"}"#))
        }
        let error = #expect(throws: SyncCodecError.self) {
            try DictationPayload.decode(from: json(#"{"schema_version":1,"id":"5D4C2B1A-0000-4000-8000-000000000001","created_at":"2026-11-01T10:00:00Z"}"#))
        }
        guard case .invalidJSON = error else {
            Issue.record("Expected invalidJSON, got \(String(describing: error))")
            return
        }
    }

    @Test("Freshness window")
    func freshness() {
        let payload = DictationPayload(text: "x", createdAt: referenceDate)
        #expect(payload.isFresh(at: referenceDate))
        #expect(payload.isFresh(at: referenceDate.addingTimeInterval(120)))
        #expect(!payload.isFresh(at: referenceDate.addingTimeInterval(121)))
        #expect(!payload.isFresh(at: referenceDate.addingTimeInterval(-60)))
        #expect(payload.isFresh(at: referenceDate.addingTimeInterval(600), maxAge: 900))
    }

    @Test("Pasteboard item carries plain text and the JSON payload")
    func pasteboardItem() throws {
        let record = DictationRecord(createdAt: referenceDate, text: "testo finale", locale: "it-IT", engine: "on-device")
        let payload = DictationPayload(record: record)
        #expect(payload.id == record.id)
        let item = try payload.pasteboardItem()
        #expect(Set(item.keys) == [HexMobileIPC.plainTextPasteboardType, HexMobileIPC.pasteboardType])
        #expect(item[HexMobileIPC.plainTextPasteboardType] as? String == "testo finale")
        let data = try #require(item[HexMobileIPC.pasteboardType] as? Data)
        #expect(try DictationPayload.decode(from: data) == payload)
    }
}

@Suite("Darwin notification center", .serialized)
struct DarwinNotificationCenterTests {
    @Test("A posted notification reaches an observer in the same process", .timeLimit(.minutes(1)))
    func roundTrip() async {
        let name = "io.github.hexmobile.test.\(UUID().uuidString)"
        let center = DarwinNotificationCenter.shared
        let stream = center.notifications(named: [name])
        center.post(name)
        let received = await firstElement(of: stream, timeout: .seconds(5))
        #expect(received == name)
    }

    @Test("Signals stream maps names to signals", .timeLimit(.minutes(1)))
    func signalStream() async {
        let center = DarwinNotificationCenter()
        let stream = center.signals([.pong])
        center.post(.pong)
        let received = await firstElement(of: stream, timeout: .seconds(5))
        #expect(received == .pong)
    }

    @Test("Ending an observation unregisters it; later posts are harmless", .timeLimit(.minutes(1)))
    func termination() async {
        let name = "io.github.hexmobile.test.\(UUID().uuidString)"
        let center = DarwinNotificationCenter.shared
        let baseline = DarwinObservationRegistry.activeCount

        let consumer = Task { () -> String? in
            for await received in center.notifications(named: [name, name]) {
                return received
            }
            return nil
        }
        while DarwinObservationRegistry.activeCount == baseline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        #expect(DarwinObservationRegistry.activeCount == baseline + 1)
        center.post(name)
        #expect(await consumer.value == name)
        #expect(DarwinObservationRegistry.activeCount == baseline)

        center.post(name)
        let fresh = center.notifications(named: [name])
        center.post(name)
        #expect(await firstElement(of: fresh, timeout: .seconds(5)) == name)
    }

    @Test("Cancelling the consuming task unregisters the observation", .timeLimit(.minutes(1)))
    func cancellation() async {
        let name = "io.github.hexmobile.test.\(UUID().uuidString)"
        let baseline = DarwinObservationRegistry.activeCount
        let consumer = Task {
            for await _ in DarwinNotificationCenter.shared.notifications(named: [name]) {}
        }
        while DarwinObservationRegistry.activeCount == baseline {
            try? await Task.sleep(for: .milliseconds(10))
        }
        consumer.cancel()
        await consumer.value
        #expect(DarwinObservationRegistry.activeCount == baseline)
    }
}
