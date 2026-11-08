import AVFAudio
import Foundation
import UIKit
import HexMobileCore
import HexMobileSpeech
import Observation

/// Drives recording, transcription, text rules, output and the flow session.
///
/// One instance lives for the whole process (see ``AppServices``); the UI,
/// App Intents, the URL handler and the keyboard (through Darwin
/// notifications) all go through it.
///
/// Starting is a multi-step async sequence (permissions, Live Activity,
/// audio, model preparation). Every step can be abandoned: ``cancel()``, a
/// stop request, an interruption, a route change or the preparing watchdog
/// bump `startGeneration`, and `start()` checks it after each `await` before
/// it moves on, releasing whatever it already acquired.
@MainActor
@Observable
final class DictationController {
    enum Phase: Equatable {
        case idle
        case preparing
        case recording
        case processing
    }

    /// Who opened the flow session. A session the Action Button intent opened
    /// lasts one dictation, plus the time the keyboard needs to take its text
    /// (see ``awaitingHandoff``); every other one lasts until its idle timeout
    /// or until the user ends it.
    enum FlowSessionOpener: String, Sendable {
        /// `ToggleDictationIntent` (Action Button, Control Center, Shortcuts).
        case toggleIntent = "intent"
        /// The app, the keyboard, `StartFlowSessionIntent` or the URL.
        case other
    }

    /// Why a flow session ended, for the diagnostics log.
    enum FlowSessionEnd: String, Sendable {
        case user
        case idleTimeout = "idle-timeout"
        case liveActivity = "live-activity"
        case interruption
        case audioConfig = "audio-config"
        /// The dictation of an intent-opened session ended with nothing for
        /// the keyboard to take (empty transcript, failure, cancel, or text
        /// finished inside the app).
        case dictationEnded = "dictation-ended"
        /// An intent-opened session waited for the keyboard, which took the text.
        case handoffServed = "handoff-served"
        /// The same wait ended because the text was not pulled within
        /// ``LoopbackHandoff/ttl``.
        case handoffExpired = "handoff-expired"
        /// The intent that opened the session had nothing to dictate.
        case intentFailed = "intent-failed"
    }

    /// Who asked for the dictation; decides where the result goes.
    enum Trigger: Equatable {
        case app
        case intent
        case keyboard
    }

    private(set) var phase: Phase = .idle
    /// Finalized part of the live transcript.
    private(set) var liveFinalized = ""
    /// Volatile tail of the live transcript (may still change).
    private(set) var liveVolatile = ""
    /// Smoothed microphone level in 0...1 while recording.
    private(set) var level: Float = 0
    /// Start of the current recording.
    private(set) var recordingStartedAt: Date?
    /// The audio input port when the recording started, for a kept clip.
    private var recordingRoute: String?
    /// The last finished dictation of this session.
    private(set) var lastRecord: DictationRecord?
    /// A user-facing error, cleared on the next start.
    var errorMessage: String?
    /// Set when the speech model must be installed before dictating.
    private(set) var missingModelLocale: Locale?
    /// The error text shown with ``missingModelLocale``, kept to clear exactly
    /// that message once the model is installed and no other one.
    @ObservationIgnored private var missingModelMessage: String?
    /// Transformations of the active mode that cannot run on iPhone.
    private(set) var skippedTransformations: [String] = []

    /// Whether a flow session keeps the microphone ready in the background.
    /// It must: a keyboard dictation runs while this app is in the
    /// background, and iOS refuses to activate (or reconfigure) an audio
    /// session there — the session is activated once, at flow session start,
    /// and stays active until the session ends. The price is system-level:
    /// a live recording session mutes system sounds (key clicks) and is
    /// known to swallow haptics, so the keyboard's tap feedback is dead for
    /// the whole session. Tried releasing the audio between dictations
    /// (2026-11-08): the next dictation could not bring it back from the
    /// background and dictation broke; reverted.
    private(set) var isFlowSessionActive = false
    /// Whether ``startFlowSession(requiresLiveActivity:opener:)`` is running:
    /// permissions, Live Activity and the audio attempts (about 3 s when iOS
    /// refuses the engine). `isFlowSessionActive` only turns on after the
    /// audio started, so a second press of the Action Button inside this window
    /// used to see no session and started a second loop on the same `audio`.
    /// A second press cancels the start instead (``cancelFlowSessionStart()``).
    private(set) var isFlowSessionStarting = false
    /// Who asked for the flow session that is starting (`isFlowSessionStarting`),
    /// so its first Live Activity already knows whether Never applies.
    @ObservationIgnored private var startingOpener: FlowSessionOpener?
    /// Incremented by every cancelled flow session start; the running start
    /// compares it with the value it began with.
    @ObservationIgnored private var flowStartGeneration = 0
    /// Who opened the current flow session; `nil` without one. Reset whenever
    /// the session ends, whatever the reason (``endFlowSession(dismissActivity:cause:)``).
    private(set) var flowSessionOpener: FlowSessionOpener?
    /// When the flow session ends if nothing happens.
    private(set) var flowSessionEndsAt: Date?
    /// An intent-opened session whose dictation left a text for the keyboard
    /// stays up, microphone on, until the keyboard has pulled it or
    /// ``LoopbackHandoff/ttl`` ran out. Only a running audio session keeps the
    /// app alive in the background, and the keyboard's pull (loopback, served
    /// by this process) needs the app alive; the pulls came 4 to 39 s after
    /// `done` in the device log of 1 Nov 2026. Closing the session at the end
    /// of the dictation would suspend the app first and lose the text
    /// (ipotesi: not measured). A new dictation or an explicit start of a flow
    /// session cancels the wait.
    @ObservationIgnored private var awaitingHandoff = false

    /// How long `start()` may stay in `.preparing` before it gives up.
    static let preparingTimeout: Duration = .seconds(30)

    /// How much of a text waiting for the keyboard the Live Activity carries.
    static let handoffPreviewLength = 120

    /// Pauses between the attempts to start the audio of a flow session: six
    /// attempts over about 3 s (see ``startFlowSession(requiresLiveActivity:opener:)``).
    static let flowAudioRetryDelays: [Duration] = [
        .milliseconds(200), .milliseconds(300), .milliseconds(500), .milliseconds(800), .milliseconds(1200),
    ]

    @ObservationIgnored private let settings: SettingsStore
    @ObservationIgnored private let sync: SyncManager
    @ObservationIgnored private let history: HistoryModel
    @ObservationIgnored private let liveActivity = LiveActivityManager()
    @ObservationIgnored private let audio = AudioCapture()
    @ObservationIgnored private let engine: any TranscriptionEngine
    /// Reads the recording after the stop (Apple's pass; Whisper follows it, see ``whisperPass``).
    @ObservationIgnored private let finalPassEngine: any FinalPassEngine
    /// The Whisper model: where it is, whether it is loaded, load and release.
    @ObservationIgnored let whisper = WhisperModel()
    /// Cleans the text of the dictation in progress; made when recording
    /// starts (so the model is warm at the stop) and used once.
    @ObservationIgnored private var textCleaner: TextCleaner?
    /// The `cleanup availability=` line is logged at the first use only.
    @ObservationIgnored private var loggedCleanupAvailability = false

    @ObservationIgnored private var currentTrigger: Trigger = .app
    @ObservationIgnored private var currentLocale: Locale?
    /// Incremented by every start and every abandoned start.
    @ObservationIgnored private var startGeneration = 0
    /// Calls to `start()` that have not returned yet, abandoned ones included.
    /// The engine keeps one run, so a new start waits until an abandoned one
    /// has released it.
    @ObservationIgnored private var startsInFlight = 0
    @ObservationIgnored private var updatesTask: Task<Void, Never>?
    @ObservationIgnored private var levelTask: Task<Void, Never>?
    @ObservationIgnored private var flowTimeoutTask: Task<Void, Never>?
    @ObservationIgnored private var preparingWatchdog: Task<Void, Never>?
    @ObservationIgnored private var signalTask: Task<Void, Never>?
    @ObservationIgnored private var stopSignalTask: Task<Void, Never>?
    @ObservationIgnored private var interruptionTask: Task<Void, Never>?
    @ObservationIgnored private var configurationTask: Task<Void, Never>?
    @ObservationIgnored private var mediaResetTask: Task<Void, Never>?

    init(
        settings: SettingsStore,
        sync: SyncManager,
        history: HistoryModel,
        engine: any TranscriptionEngine = OnDeviceSpeechEngine(),
        finalPassEngine: any FinalPassEngine = AppleFinalPassEngine()
    ) {
        self.settings = settings
        self.sync = sync
        self.history = history
        self.engine = engine
        self.finalPassEngine = finalPassEngine
        liveActivity.sessionNeverEnds = { [weak self] in self?.flowSessionNeverEnds ?? false }
        startListening()
    }

    /// The audio category the app wants in the foreground (see
    /// ``AudioCapture/configureCategoryForForeground()``).
    func configureAudioCategoryForForeground() {
        audio.configureCategoryForForeground()
    }

    func markNeedsForeground() {
        lastStartNeedsForeground = UIApplication.shared.applicationState != .active
    }

    /// Why the last Live Activity request failed, if it did.
    var lastLiveActivityFailure: String? { liveActivity.lastFailure }

    /// Whether the microphone is in use (recording or flow session).
    var isBusy: Bool { phase != .idle }

    /// The live transcript for display.
    var liveText: String { liveFinalized.appendingSegment(liveVolatile) }

    // MARK: - Dictation

    /// Starts when idle, stops when recording, abandons a start that is
    /// still preparing. Returns the final text when it stops.
    @discardableResult
    func toggle(trigger: Trigger = .app) async -> String? {
        switch phase {
        case .idle:
            await start(trigger: trigger)
            return nil
        case .recording:
            return await stop()
        case .preparing:
            await cancel()
            return nil
        case .processing:
            return nil
        }
    }

    /// The speech model for `locale` is installed now (an install finished, or
    /// a refresh found it): the install card and its message are obsolete.
    /// Before, they stayed until the next `start()` cleared them.
    func modelInstalled(for locale: Locale) {
        guard let missing = missingModelLocale,
              missing.identifier(.bcp47) == locale.identifier(.bcp47) else { return }
        missingModelLocale = nil
        if errorMessage == missingModelMessage { errorMessage = nil }
        missingModelMessage = nil
    }

    /// Starts recording and transcribing.
    func start(trigger: Trigger = .app) async {
        guard phase == .idle else { return }
        guard startsInFlight == 0 else {
            let message = String(localized: "The previous dictation is still stopping. Try again in a moment.")
            errorMessage = message
            publishFailure(message)
            return
        }
        startsInFlight += 1
        defer { startsInFlight -= 1 }
        if awaitingHandoff {
            // A new press inside the wait: the session stays and serves it,
            // and this dictation's end applies the closing rule again.
            awaitingHandoff = false
            Diagnostics.record("handoff wait cancelled by a new dictation trigger=\(trigger)")
        }
        errorMessage = nil
        LoopbackHandoff.shared.setError(nil)
        missingModelLocale = nil
        missingModelMessage = nil
        lastStartNeedsForeground = false
        lastStopFoundNoSpeech = false
        phase = .preparing
        currentTrigger = trigger
        startGeneration += 1
        let generation = startGeneration
        startPreparingWatchdog(for: generation)

        guard await Permissions.requestMicrophone() else {
            if isCurrentStart(generation) {
                await fail(String(localized: "Microphone access is off. Turn it on in Settings > Privacy & Security > Microphone."))
            }
            return
        }
        guard isCurrentStart(generation) else { return }
        guard await Permissions.requestSpeech() else {
            if isCurrentStart(generation) {
                await fail(String(localized: "Speech recognition access is off. Turn it on in Settings > Privacy & Security > Speech Recognition."))
            }
            return
        }
        guard isCurrentStart(generation) else { return }

        let locale = settings.recognitionLocale(syncedLanguage: sync.bundle?.language)
        // The Live Activity comes before the audio: iOS stops a recording
        // started from an AudioRecordingIntent that has no Live Activity.
        let startedAt = Date()
        let hasActivity = await liveActivity.show(
            phase: .recording,
            recordingStartedAt: startedAt,
            isFlowSession: isFlowSessionActive
        )
        guard isCurrentStart(generation) else {
            await settleLiveActivityAfterAbandonedStart()
            return
        }
        // Without a Live Activity iOS may stop a background recording, but
        // the request can fail for reasons other than the user setting (for
        // example while the app is still launching). Try to record anyway and
        // explain the cause only if the audio cannot start.
        Diagnostics.record("start trigger=\(trigger) activity=\(hasActivity) failure=\(liveActivity.lastFailure ?? "-")")
        if trigger == .intent, !hasActivity {
            // An AudioRecordingIntent that records without a Live Activity is
            // terminated by AppIntents (crash of 1 Nov 2026), so stop here.
            await fail(String(localized: "The Live Activity could not start (\(liveActivity.lastFailure ?? "unknown reason")), so iOS does not allow recording in the background. Open Hex Mobile and dictate from there."))
            return
        }
        let activityFailure: String? = nil

        do {
            try await startAudioWithRetry(generation: generation)
            let session = try await engine.start(
                locale: locale,
                context: TranscriptionContext(contextualStrings: recognitionContextualStrings),
                audio: audio
            )
            guard isCurrentStart(generation) else {
                // Abandoned while the model was being prepared.
                await engine.cancel()
                return
            }
            currentLocale = session.locale
            liveFinalized = ""
            liveVolatile = ""
            recordingStartedAt = startedAt
            recordingRoute = AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue
            phase = .recording
            // A dictation outside a flow session has no session to load in:
            // the model loads alongside the recording. Inside one it is
            // already loading or loaded (this is a no-op then), or it was
            // given back after a memory warning and comes back here.
            beginWhisperLoadIfChosen(reason: isFlowSessionActive ? "dictation-in-session" : "dictation")
            cancelPreparingWatchdog()
            observe(session.updates)
            prepareTextCleaner(locale: session.locale)
            LoopbackHandoff.shared.setLive("")
            startLevelMeter()
            postFlowState(.recording)
            pauseFlowTimeout()
        } catch let error as TranscriptionError {
            guard isCurrentStart(generation) else { return }
            let message = Self.describe(error, activityFailure: activityFailure)
            if case .assetsNotInstalled = error {
                missingModelLocale = locale
                missingModelMessage = message
            }
            await fail(message)
        } catch {
            guard isCurrentStart(generation) else { return }
            if case AudioCapture.CaptureError.sessionConfiguration = error { markNeedsForeground() }
            await fail(Self.describe(error, activityFailure: activityFailure))
        }
    }

    /// Right after the Live Activity appears, iOS can still refuse to
    /// activate the audio session of a background app for a moment: retry a
    /// few times before giving up (Action Button, 1 Nov 2026).
    private func startAudioWithRetry(generation: Int) async throws {
        let began = Date()
        var attempt = 0
        var dumpedOSLog = false
        while true {
            do {
                try audio.start()
                if attempt > 0 { Diagnostics.record("audio started after \(attempt) retries") }
                return
            } catch let error as AudioCapture.CaptureError {
                recordAudioFailure(error, path: "start", attempt: attempt, since: began)
                if error.failure.stage == .engineStart, !dumpedOSLog {
                    dumpedOSLog = true
                    AudioFailureLog.capture(path: "start", attempt: attempt)
                }
                guard case .sessionConfiguration(let failure) = error, attempt < 6, isCurrentStart(generation) else { throw error }
                attempt += 1
                Diagnostics.record("audio retry \(attempt): \(failure.message)")
                try await Task.sleep(for: .milliseconds(250))
            }
        }
    }

    /// The identity of an audio failure for the log: where it happened and
    /// the system error, with its four-character code when printable.
    private static func audioFailureFields(_ error: (any Error)?) -> String {
        guard let error else { return "stage=- domain=- code=- fourcc=-" }
        let stage: String
        let domain: String?
        let code: Int?
        let fourCC: String?
        if let failure = (error as? AudioCapture.CaptureError)?.failure {
            (stage, domain, code, fourCC) = (failure.stage.rawValue, failure.domain, failure.code, failure.fourCC)
        } else {
            let nsError = error as NSError
            (stage, domain, code, fourCC) = ("unknown", nsError.domain, nsError.code, FourCC.string(for: nsError.code))
        }
        return "stage=\(stage) domain=\(domain ?? "-") code=\(code.map(String.init) ?? "-") fourcc=\(fourCC ?? "-")"
    }

    /// One log line per failed audio attempt, enough to tell the possible
    /// causes apart on the next device run (1 Nov 2026: `engine.start` failed
    /// 8 times in a row with 'what' after a cold Action Button press, and the
    /// press one second later worked). `path` is `flow` for
    /// ``startFlowSession(requiresLiveActivity:opener:)`` and `start` for
    /// ``startAudioWithRetry(generation:)``; `elapsed` counts from the first
    /// attempt of that start. Never logs dictated text.
    private func recordAudioFailure(_ error: any Error, path: String, attempt: Int, since began: Date) {
        let failure = (error as? AudioCapture.CaptureError)?.failure
        let session = AVAudioSession.sharedInstance()
        let input = failure?.inputSampleRate.map { rate in
            "\(Int(rate))Hz/\(failure?.inputChannelCount ?? 0)ch"
        } ?? "-"
        Diagnostics.record(
            "audio attempt failed path=\(path) attempt=\(attempt) elapsed=\(Self.seconds(since: began))s "
            + "\(Self.audioFailureFields(error)) input=\(input) session=\(Int(session.sampleRate))Hz/\(session.inputNumberOfChannels)ch "
            + "route=\(session.currentRoute.inputs.first?.portType.rawValue ?? "-") otherAudio=\(session.isOtherAudioPlaying) "
            + "t=\(Diagnostics.secondsSinceLaunch)s activities=\(liveActivity.diagnosticsSummary()) \(AudioCapture.routeSummary())"
        )
    }

    /// Seconds since `date`, with one decimal, for the diagnostics log.
    private static func seconds(since date: Date) -> String {
        String(format: "%.1f", Date().timeIntervalSince(date))
    }

    /// Whether the last start failed because the audio session could not be
    /// activated from the background (the intent then retries in foreground).
    private(set) var lastStartNeedsForeground = false

    /// Whether the last stop ended with an empty transcript. The Action
    /// Button intent ends quietly in that case and only in that case.
    private(set) var lastStopFoundNoSpeech = false

    private static func describe(_ error: Error, activityFailure: String?) -> String {
        Diagnostics.record("start failed: \(String(reflecting: error))")

        guard let activityFailure else { return error.localizedDescription }
        return String(localized: "\(error.localizedDescription) The Live Activity could not start (\(activityFailure)).")
    }

    /// Stops recording, transcribes, applies text rules and delivers the
    /// result. A stop that arrives while the start is still preparing (for
    /// example push-to-talk released early) abandons the start: no audio has
    /// reached the recognizer yet.
    @discardableResult
    func stop() async -> String? {
        if phase == .preparing {
            await cancel()
            return nil
        }
        guard phase == .recording else { return nil }
        let stopAt = Date()
        lastStopFoundNoSpeech = false
        phase = .processing
        stopLevelMeter()
        postFlowState(.processing)
        // Time for what follows the stop when the app is in the background.
        let background = BackgroundTaskScope(name: "finish-dictation")
        defer { background.end() }
        await liveActivity.show(phase: .processing, recordingStartedAt: recordingStartedAt, isFlowSession: isFlowSessionActive)

        let raw: String
        do {
            raw = try await engine.finish()
        } catch {
            await fail(error.localizedDescription)
            return nil
        }
        let recording = await engine.takeRecording()
        defer { recording?.discard() }
        let cleaner = textCleaner
        textCleaner = nil
        updatesTask?.cancel()
        let duration = recordingStartedAt.map { Date().timeIntervalSince($0) }
        let live = raw.trimmingCharacters(in: .whitespacesAndNewlines)
        // The accurate second pass over the recording; the live text stays
        // whenever it cannot improve on it.
        let finalPass = await accurateText(live: live, recording: recording, stopAt: stopAt, cleanupExpected: cleaner?.availability == .available)
        let trimmed = finalPass.text
        // Then the cleanup; the text as recognized stays whenever the model
        // cannot be used or does not return a cleanup of it.
        let cleanup = await cleanedText(of: trimmed, with: cleaner, stopAt: stopAt, alreadyRefining: recording != nil)
        let cleaned = cleanup.text
        Diagnostics.record("stop to text dt=\(String(format: "%.2f", Date().timeIntervalSince(stopAt))) chars=\((cleaned ?? trimmed).count) cleaned=\(cleaned != nil) trigger=\(currentTrigger)")
        guard !trimmed.isEmpty else {
            keepClip(recording, live: live, finalPass: finalPass, cleanup: cleanup, inserted: "", record: nil, stopAt: stopAt)
            Diagnostics.record("empty transcript after \(String(format: "%.1f", duration ?? 0))s trigger=\(currentTrigger)")
            await finishCycle()
            lastStopFoundNoSpeech = true
            errorMessage = String(localized: "No speech was recognized.")
            return nil
        }

        // The user's own terms get their exact spelling (case only), whether
        // the text was cleaned or not; then the Hex rules, as on the Mac.
        let respelled = PersonalVocabulary.respell(cleaned ?? trimmed, terms: recognitionContextualStrings)
        if respelled.changes > 0 {
            Diagnostics.record("vocabulary respell n=\(respelled.changes)")
        }
        let processor = sync.textProcessor(modeOverride: settings.modeOverride)
        let result = processor.process(respelled.text)
        skippedTransformations = result.skippedTransformations
        let record = DictationRecord(
            createdAt: Date(),
            text: result.text,
            rawText: result.text == trimmed ? nil : trimmed,
            cleanedText: cleaned == trimmed ? nil : cleaned,
            duration: duration,
            locale: currentLocale?.identifier(.bcp47),
            modeName: processor.mode.name,
            engine: engine.identifier
        )
        lastRecord = record
        // The keyboard's recent-dictation picker (long press on its insert
        // key) serves from this list, whatever route produced the text.
        LoopbackHandoff.shared.remember(DictationPayload(record: record))
        keepClip(recording, live: live, finalPass: finalPass, cleanup: cleanup, inserted: result.text, record: record, stopAt: stopAt)
        if settings.copyToClipboard {
            DictationPasteboard.write(record, localOnly: !settings.allowUniversalClipboard)
        } else {
            // The keyboard receives results through the pasteboard; with
            // copying off, that copy stays local and expires quickly.
            DictationPasteboard.handOffToKeyboard(record)
        }
        // The pasteboard write is dropped while the app is in the
        // background; the keyboard also pulls the result over loopback.
        // Only when finished in the background: a dictation done inside the
        // app is already on the pasteboard and must not pop up later in
        // whatever field the keyboard opens next.
        // A dictation the keyboard asked for is offered in any case: it
        // may end while the app is open on its "listening" view (the `dictate`
        // route), and the keyboard takes the text when the user goes back.
        if UIApplication.shared.applicationState != .active || currentTrigger == .keyboard {
            LoopbackHandoff.shared.offer(DictationPayload(record: record))
        }
        await history.append(record)
        DarwinNotificationCenter.shared.post(.done)
        Diagnostics.record("done trigger=\(currentTrigger) chars=\(record.text.count) copied=\(settings.copyToClipboard) pbChange=\(UIPasteboard.general.changeCount) pbTypes=\(UIPasteboard.general.types.count)")
        await finishCycle()
        if settings.shareHistory, let data = history.jsonLinesExport() {
            await sync.exportHistory(data)
        }
        return record.text
    }

    /// Settings > Prepare Whisper: loads the model once (the first load makes
    /// Core ML compile it) and gives it back, unless a dictation session is
    /// using it.
    func prepareWhisper() async {
        await whisper.prepare(keepLoaded: isFlowSessionActive || isFlowSessionStarting || phase != .idle)
    }

    /// The engine picker changed: inside a session, load or release the model
    /// accordingly, so the next dictation does not wait for it.
    func finalTextEngineChanged() async {
        guard isFlowSessionActive || isFlowSessionStarting || phase != .idle else { return }
        if settings.finalTextEngine == .whisper {
            whisper.beginLoading(reason: "setting-changed")
        } else {
            await whisper.release(reason: "setting-changed")
        }
    }

    /// The terms that bias recognition: live and final pass use the same list.
    private var recognitionContextualStrings: [String] { sync.contextualStrings }

    /// The recording is shorter than this: the live transcript stands, a second
    /// pass is not worth the model load.
    private static let finalPassMinimumSeconds = 0.5

    /// Runs the accurate final pass over `recording` and returns the text to
    /// go on with: the final pass text, or `live` when the pass cannot
    /// improve on it (no file, too short, timeout, error, empty or shorter
    /// than half of the live words). Logs `final pass ...`. With Whisper
    /// chosen in Settings, a second pass follows (``whisperPass``).
    private func accurateText(live: String, recording: RecordedClip?, stopAt: Date, cleanupExpected: Bool) async -> StepResult {
        guard let recording else {
            Diagnostics.record("final pass skipped reason=no-audio live=\(live.count)")
            return StepResult(text: live, outcome: "skipped:no-audio", engine: "live")
        }
        guard recording.seconds >= Self.finalPassMinimumSeconds else {
            Diagnostics.record("final pass skipped reason=too-short rec=\(String(format: "%.1f", recording.seconds))s live=\(live.count)")
            return StepResult(text: live, outcome: "skipped:too-short", engine: "live")
        }
        await liveActivity.show(phase: .processing, recordingStartedAt: recordingStartedAt, isFlowSession: isFlowSessionActive, refining: true)
        let timeout = FinalPassPolicy.finalPassTimeout(forRecordingSeconds: recording.seconds)
        Diagnostics.record("final pass start engine=\(finalPassEngine.name) rec=\(String(format: "%.1f", recording.seconds))s timeout=\(String(format: "%.1f", timeout))s \(Diagnostics.processSummary())")
        let locale = currentLocale ?? settings.recognitionLocale(syncedLanguage: sync.bundle?.language)
        let report = await FinalPass.run(
            engine: finalPassEngine,
            fileURL: recording.url,
            locale: locale,
            contextualStrings: recognitionContextualStrings,
            live: live,
            recordingSeconds: recording.seconds
        )
        Diagnostics.record(report.logLine)
        let apple = StepResult(
            text: report.text,
            outcome: report.outcome == .ok ? "ok" : "fallback:\(report.reason)",
            seconds: report.seconds,
            produced: report.rawFinal.flatMap { $0.isEmpty ? nil : $0 },
            engine: report.outcome == .ok ? finalPassEngine.name : "live"
        )
        guard settings.finalTextEngine == .whisper else { return apple }
        return await whisperPass(after: apple, recording: recording, locale: locale, stopAt: stopAt, cleanupExpected: cleanupExpected)
    }

    /// The prompt tokens the plan counts on: none without terms; the real count
    /// (the run's own builder and tokenizer) once the model is ready, so a piece of
    /// 98 tokens' prompt is planned as 15.0 s and not as 14.75; the cap (an upper
    /// bound, never an underestimate) when the model is not ready, has no tokenizer
    /// or does not answer in 0.3 s (the holder may be busy with a late run of the
    /// previous dictation: the budget is not spent waiting for it).
    private func whisperPromptTokens() async -> (tokens: Int, isCap: Bool) {
        let terms = recognitionContextualStrings
        guard !terms.isEmpty else { return (0, false) }
        let cap = WhisperPromptBuilder.tokenCap
        guard whisper.isReady else { return (cap, true) }
        let holder = whisper.holder
        let counted = try? await withDeadline(.milliseconds(300)) { await holder.promptTokenCount(terms: terms) }
        if let count = counted ?? nil { return (min(count, cap), false) }
        return (cap, true)
    }

    /// The second opinion: Whisper reads the recording after the Apple pass,
    /// when its estimated time and the cleanup's both fit in what is left of the
    /// 8 s budget (``FinalPassPolicy/whisperPlan``: on a long dictation Apple's
    /// text goes to the cleanup instead). Its text replaces `apple`'s when it
    /// finishes in time, keeps at least
    /// half of its words and lacks no run of five of them
    /// (``TranscriptGapGuard``: a lost sentence, `reason=gap`, logged as
    /// `guard gap=N at=i`); otherwise `apple`'s text stands.
    /// Never throws. Whisper's deadline is an absolute time after the stop,
    /// worked out again after the Live Activity update (an `await` that takes its
    /// own time, which used to come out of the cleanup's reserve), and the reserve
    /// has a margin for the model that goes on running after a deadline, so the
    /// cleanup keeps at least `minimumCleanupTime` plus that margin.
    /// Logs `final pass ... engine=whisper ... apple=N ...`.
    private func whisperPass(after apple: StepResult, recording: RecordedClip, locale: Locale, stopAt: Date, cleanupExpected: Bool) async -> StepResult {
        let engine = WhisperFinalPassEngine(holder: whisper.holder)
        // What Whisper's text is compared with, and called in the log: Apple's
        // text, or the live transcript when the Apple pass fell back (then
        // `apple.text` is the live text, and so is the guard's reference).
        let baseline = apple.engine == "live" ? "live" : "apple"
        let (promptTokens, promptIsCap) = await whisperPromptTokens()
        let cleanupCharacters = cleanupExpected ? apple.text.count : nil
        func plan() -> FinalPassPolicy.WhisperPlan {
            FinalPassPolicy.whisperPlan(
                recordingSeconds: recording.seconds,
                elapsedSinceStop: Date().timeIntervalSince(stopAt),
                promptTokens: promptTokens,
                cleanupCharacters: cleanupCharacters
            )
        }
        let shape = "rec=\(String(format: "%.1f", recording.seconds))s prompt=\(promptTokens)\(promptIsCap ? "(cap)" : "") cleanup=\(cleanupCharacters.map(String.init) ?? "-")"
        let report: FinalPassReport
        if !whisper.isReady {
            Diagnostics.record("whisper plan not ready state=\(whisper.holder.state) installed=\(whisper.isInstalled) rec=\(String(format: "%.1f", recording.seconds))s")
            report = FinalPass.skipped(engine: engine.name, reason: .notReady, text: apple.text, recordingSeconds: recording.seconds, baseline: baseline)
        } else {
            var start = false
            switch plan() {
            case .run:
                start = true
            case let .skip(estimate, available):
                Diagnostics.record("whisper plan skip estimate=\(String(format: "%.1f", estimate))s available=\(String(format: "%.1f", available))s \(shape)")
            }
            #if DEBUG
            // A simulator runs the model on the CPU, far slower than the budget
            // allows: the deadline can be forced to see a whole run.
            let forcedDeadline = LaunchOptions.whisperDeadlineSeconds
            if forcedDeadline != nil { start = true }
            #endif
            var deadline: TimeInterval?
            var waited: TimeInterval = 0
            if start {
                await liveActivity.show(phase: .processing, recordingStartedAt: recordingStartedAt, isFlowSession: isFlowSessionActive, refining: true)
                // The update above took time of its own, and the cleanup's reserve is
                // counted from the stop: decide again with the clock as it is now, and
                // give Whisper what is left until the same absolute time.
                waited = Date().timeIntervalSince(stopAt)
                switch plan() {
                case let .run(endBy):
                    deadline = FinalPassPolicy.whisperDeadline(endBy: endBy, elapsedSinceStop: waited)
                case let .skip(estimate, available):
                    Diagnostics.record("whisper plan skip estimate=\(String(format: "%.1f", estimate))s available=\(String(format: "%.1f", available))s after-wait \(shape)")
                }
                #if DEBUG
                if let forcedDeadline { deadline = forcedDeadline }
                #endif
            }
            if let deadline {
                let estimate = FinalPassPolicy.whisperEstimate(forRecordingSeconds: recording.seconds, promptTokens: promptTokens)
                Diagnostics.record("whisper plan run estimate=\(String(format: "%.1f", estimate))s deadline=\(String(format: "%.1f", deadline))s at=\(String(format: "%.2f", waited))s \(shape) \(Diagnostics.processSummary())")
                report = await FinalPass.run(
                    engine: engine,
                    fileURL: recording.url,
                    locale: locale,
                    contextualStrings: recognitionContextualStrings,
                    live: apple.text,
                    recordingSeconds: recording.seconds,
                    timeout: deadline,
                    baseline: baseline,
                    gapGuard: FinalPassPolicy.whisperGapRun
                )
            } else {
                report = FinalPass.skipped(engine: engine.name, reason: .budget, text: apple.text, recordingSeconds: recording.seconds, baseline: baseline)
            }
        }
        Diagnostics.record(report.logLine)
        if let guardLine = report.guardLogLine { Diagnostics.record(guardLine) }

        var result = apple
        result.whisper = WhisperAttempt(
            outcome: report.outcome == .ok ? "ok" : "fallback:\(report.reason)",
            seconds: report.seconds,
            produced: report.rawFinal.flatMap { $0.isEmpty ? nil : $0 }
        )
        if report.outcome == .ok {
            result.text = report.text
            result.engine = engine.name
        }
        return result
    }

    /// What a step after the stop did: the text to go on with, how it ended
    /// (`ok`, `fallback:<reason>`, `skipped:<reason>`), how long it took, and
    /// the text the step itself produced, for the kept clip's metadata.
    private struct StepResult {
        var text: String
        var outcome: String
        var seconds: Double?
        var produced: String?
        /// Whose text is `text`: the final pass engine's name, or `live`.
        var engine: String?
        /// The Whisper pass, when it was asked for (the fields above stay Apple's).
        var whisper: WhisperAttempt?

        init(text: String, outcome: String, seconds: Double? = nil, produced: String? = nil, engine: String? = nil) {
            self.text = text
            self.outcome = outcome
            self.seconds = seconds
            self.produced = produced
            self.engine = engine
        }
    }

    /// How the Whisper pass went, for the kept clip's metadata.
    private struct WhisperAttempt {
        var outcome: String
        var seconds: Double?
        var produced: String?
    }

    /// Makes the cleanup session for the dictation that just started (and
    /// warms the model) when the setting is on. The first use logs whether the
    /// model can be used at all.
    private func prepareTextCleaner(locale: Locale) {
        textCleaner = nil
        guard settings.cleanupEnabled else { return }
        let cleaner = TextCleaner(locale: locale)
        if !loggedCleanupAvailability {
            loggedCleanupAvailability = true
            Diagnostics.record("cleanup availability=\(cleaner.availability.logValue) locale=\(locale.identifier(.bcp47))")
        }
        textCleaner = cleaner
    }

    /// The cleaned text, or `nil` when the raw text stands (setting off,
    /// model unavailable, no time left, error, or an answer that is not a
    /// cleanup). It starts only if its estimate fits what is left until
    /// ``FinalPassPolicy/cleanupDeadline`` (`reason=budget` otherwise, and the
    /// raw text arrives at once), and then runs to that absolute deadline:
    /// ``FinalPassPolicy/cleanupPlan(elapsedSinceStop:characters:)``, asked again
    /// after the Live Activity update, which takes its own time.
    private func cleanedText(of text: String, with cleaner: TextCleaner?, stopAt: Date, alreadyRefining: Bool) async -> CleanupResult {
        guard let cleaner, !text.isEmpty else { return CleanupResult(text: nil, outcome: "skipped:off") }
        let characters = text.count
        #if DEBUG
        let forcedTimeout: Double? = LaunchOptions.cleanupTimeoutMilliseconds.map { Double($0) / 1000 }
        #else
        let forcedTimeout: Double? = nil
        #endif
        func plan() -> FinalPassPolicy.CleanupPlan {
            FinalPassPolicy.cleanupPlan(elapsedSinceStop: Date().timeIntervalSince(stopAt), characters: characters)
        }
        /// Logged and answered when the cleanup does not start.
        func skipped(_ estimate: Double, _ available: Double) -> CleanupResult {
            Diagnostics.record(
                "cleanup dt=0.00 outcome=fallback reason=budget in=\(characters) out=0 "
                    + "estimate=\(String(format: "%.2f", estimate)) available=\(String(format: "%.2f", available))"
            )
            return CleanupResult(text: nil, outcome: "skipped:budget")
        }
        // A model that is not available is not a budget matter: the cleaner logs why.
        let isAvailable = cleaner.availability == .available
        if forcedTimeout == nil, isAvailable, case let .skip(estimate, available) = plan() {
            return skipped(estimate, available)
        }
        if !alreadyRefining {
            await liveActivity.show(phase: .processing, recordingStartedAt: recordingStartedAt, isFlowSession: isFlowSessionActive, refining: true)
        }
        // The deadline is absolute: whatever the update took is out of the cleanup's time.
        var seconds = forcedTimeout ?? FinalPassPolicy.minimumCleanupTime
        if forcedTimeout == nil, isAvailable {
            switch plan() {
            case let .run(timeout): seconds = timeout
            case let .skip(estimate, available): return skipped(estimate, available)
            }
        }
        let report = await cleaner.clean(text, timeout: .milliseconds(Int(max(seconds, 0.05) * 1000)))
        Diagnostics.record(report.logLine)
        return CleanupResult(
            text: report.cleaned,
            outcome: report.outcome == .ok ? "ok" : "fallback:\(report.reason)",
            seconds: report.seconds
        )
    }

    /// The cleanup step: the cleaned text (`nil` when the recognizer's text
    /// stands), how it ended and how long it took.
    private struct CleanupResult {
        var text: String?
        var outcome: String
        var seconds: Double?
    }

    /// Keeps the recording of this dictation with its texts, when the user
    /// chose to (Settings, off by default). The file is moved, not copied: it
    /// is the one the final pass read. Whatever the outcome, the recording is
    /// left either kept or for the caller's `discard()`.
    private func keepClip(
        _ recording: RecordedClip?,
        live: String,
        finalPass: StepResult,
        cleanup: CleanupResult,
        inserted: String,
        record: DictationRecord?,
        stopAt: Date
    ) {
        guard settings.keepAudioClips, let recording else { return }
        let library = AppPaths.clipLibrary
        let metadata = ClipMetadata(
            id: ClipMetadata.makeID(),
            createdAt: record?.createdAt ?? Date(),
            seconds: recording.seconds,
            locale: currentLocale?.identifier(.bcp47),
            route: recordingRoute,
            liveText: live,
            finalPassText: finalPass.produced,
            finalPassOutcome: finalPass.outcome,
            finalPassSeconds: finalPass.seconds,
            finalEngine: finalPass.engine,
            whisperText: finalPass.whisper?.produced,
            whisperOutcome: finalPass.whisper?.outcome,
            whisperSeconds: finalPass.whisper?.seconds,
            cleanedText: cleanup.text,
            cleanupOutcome: cleanup.outcome,
            cleanupSeconds: cleanup.seconds,
            insertedText: inserted,
            stopToTextSeconds: Date().timeIntervalSince(stopAt),
            recordID: record?.id
        )
        do {
            try library.store(audio: recording.url, metadata: metadata)
            Diagnostics.record("clip kept id=\(metadata.id) seconds=\(String(format: "%.1f", recording.seconds)) kept=\(library.count)")
        } catch {
            Diagnostics.record("clip not kept: \(error.localizedDescription)")
        }
    }

    /// Stops recording, or abandons a start that is still preparing, and
    /// discards the audio. `message` is shown to the user, if given.
    func cancel(message: String? = nil) async {
        switch phase {
        case .preparing:
            // Invalidate the start in flight; it releases what it acquired
            // when it resumes.
            startGeneration += 1
            await engine.cancel()
        case .recording:
            await engine.cancel()
        case .idle, .processing:
            return
        }
        await finishCycle()
        if let message {
            errorMessage = message
            publishFailure(message)
        }
    }

    /// Returns to idle; keeps the microphone open only during a flow session.
    private func finishCycle() async {
        textCleaner = nil
        LoopbackHandoff.shared.setLive(nil)
        cancelPreparingWatchdog()
        stopLevelMeter()
        updatesTask?.cancel()
        updatesTask = nil
        recordingStartedAt = nil
        liveVolatile = ""
        phase = .idle
        if isFlowSessionActive, flowSessionOpener == .toggleIntent {
            // A session the Action Button opened lasts one dictation (decision
            // of 1 Nov 2026). With nothing for the keyboard to take, close it
            // and its Live Activity now, however the dictation ended. With a
            // text offered over loopback, keep it, ready as before, until the
            // keyboard pulls the text or it expires (`handoffSettled`). The
            // Live Activity shows the start of that text and asks to open the
            // keyboard: in the background iOS drops the pasteboard copy, and
            // the keyboard was not open in two of the four Action Button
            // dictations of the device log of 1 Nov 2026 evening.
            if LoopbackHandoff.shared.hasPending {
                awaitingHandoff = true
                Diagnostics.record("flow session kept for handoff ttl=\(Int(LoopbackHandoff.ttl))s")
                postFlowState(.idle)
                let preview = Self.handoffPreview(of: LoopbackHandoff.shared.pendingText)
                let shown = await liveActivity.show(phase: .handoff, recordingStartedAt: nil, isFlowSession: true, liveText: preview)
                Diagnostics.record("handoff activity phase=handoff preview=\(preview?.count ?? 0) chars shown=\(shown) activities=\(liveActivity.diagnosticsSummary())")
                // The handoff settles within `ttl`; this timer, a little
                // longer, catches a settlement that never comes and gives the
                // Dictate card the real end time (`flowSessionEndsAt`).
                scheduleFlowTimeout(after: LoopbackHandoff.ttl + 2)
            } else {
                await endFlowSession(dismissActivity: true, cause: .dictationEnded)
            }
        } else if isFlowSessionActive {
            postFlowState(.idle)
            await liveActivity.show(phase: .ready, recordingStartedAt: nil, isFlowSession: true)
            scheduleFlowTimeout()
        } else {
            DarwinNotificationCenter.shared.post(.sessionEnded)
            audio.stop()
            await liveActivity.show(phase: .standby, recordingStartedAt: nil, isFlowSession: true)
            if !isFlowSessionStarting { await whisper.release(reason: "dictation-ended") }
        }
    }

    /// Starts loading the Whisper model when Whisper is the chosen engine and
    /// the model is installed. Returns at once: a dictation that stops before
    /// it is ready keeps Apple's text.
    private func beginWhisperLoadIfChosen(reason: String) {
        guard settings.finalTextEngine == .whisper else { return }
        whisper.beginLoading(reason: reason)
    }

    /// The start of a text waiting for the keyboard, for the Live Activity:
    /// one line, at most ``handoffPreviewLength`` characters and an ellipsis
    /// when the text goes on (the activity cuts it to its lines).
    private static func handoffPreview(of text: String?) -> String? {
        guard let text else { return nil }
        let line = text.split(whereSeparator: \.isNewline).joined(separator: " ")
            .trimmingCharacters(in: .whitespaces)
        guard !line.isEmpty else { return nil }
        return line.count > handoffPreviewLength ? String(line.prefix(handoffPreviewLength)) + "…" : line
    }

    /// The text offered to the keyboard was pulled or expired. Closes an
    /// intent-opened session that waited for it; ignores any other settlement
    /// (a session adopted meanwhile, a newer dictation, a payload of an
    /// earlier dictation). A pull that lands before `finishCycle` ran finds
    /// nothing pending there and closes with `dictation-ended`.
    func handoffSettled(_ outcome: LoopbackHandoff.Settlement) async {
        let waiting = awaitingHandoff
        Diagnostics.record("handoff settled outcome=\(outcome.rawValue) waiting=\(waiting) phase=\(phase) flow=\(isFlowSessionActive) opener=\(flowSessionOpener?.rawValue ?? "-")")
        guard waiting, phase == .idle, isFlowSessionActive, flowSessionOpener == .toggleIntent else { return }
        awaitingHandoff = false
        await endFlowSession(dismissActivity: true, cause: outcome == .served ? .handoffServed : .handoffExpired)
    }

    private func fail(_ message: String) async {
        errorMessage = message
        await finishCycle()
        publishFailure(message)
    }

    /// Tells the keyboard that a start or a dictation failed, and why: the
    /// reason goes on loopback and the signal tells the keyboard to read it.
    /// Posted after the state signal of the cycle that ended, so the keyboard
    /// shows the message on top of the state it has just learned. The keyboard
    /// shows it with Close and Retry (see `KeyboardModel`); nobody is listening
    /// when it is hidden, and it asks again with `ping` when it shows.
    private func publishFailure(_ message: String) {
        LoopbackHandoff.shared.setError(message)
        DarwinNotificationCenter.shared.post(.startFailed)
        Diagnostics.record("keyboard failure published chars=\(message.count)")
    }

    /// The app closed its own error screen (or retried): the keyboard has
    /// nothing left to show either.
    func clearKeyboardFailure() {
        LoopbackHandoff.shared.setError(nil)
    }

    private func isCurrentStart(_ generation: Int) -> Bool {
        generation == startGeneration && phase == .preparing
    }

    /// A start abandoned while its Live Activity request was in flight may
    /// have created an activity after the cancel path ended it.
    private func settleLiveActivityAfterAbandonedStart() async {
        guard phase == .idle else { return }
        if isFlowSessionActive {
            await liveActivity.show(phase: .ready, recordingStartedAt: nil, isFlowSession: true)
        } else {
            await liveActivity.end()
        }
    }

    private func startPreparingWatchdog(for generation: Int) {
        preparingWatchdog?.cancel()
        preparingWatchdog = Task { [weak self] in
            try? await Task.sleep(for: Self.preparingTimeout)
            guard !Task.isCancelled, let self, self.isCurrentStart(generation) else { return }
            await self.cancel(message: String(localized: "Dictation did not start in time. Try again."))
        }
    }

    private func cancelPreparingWatchdog() {
        preparingWatchdog?.cancel()
        preparingWatchdog = nil
    }

    private func observe(_ updates: AsyncStream<TranscriptUpdate>) {
        updatesTask?.cancel()
        updatesTask = Task { [weak self] in
            var count = 0
            for await update in updates {
                guard let self else { return }
                count += 1
                if count == 1 || count % 20 == 0 { Diagnostics.record("transcript update #\(count) after=\(String(format: "%.1f", Date().timeIntervalSince(self.recordingStartedAt ?? Date())))s final=\(update.finalized.count) volatile=\(update.volatile.count)") }
                self.liveFinalized = update.finalized
                self.liveVolatile = update.volatile
                LoopbackHandoff.shared.setLive(self.liveText)
                self.pushLiveTextIfDue()
            }
        }
    }

    @ObservationIgnored private var lastLiveTextPush = Date.distantPast
    @ObservationIgnored private var liveTextTask: Task<Void, Never>?

    @ObservationIgnored private var liveActivityPushes = 0

    /// Shows the live transcript and the voice level in the Live Activity
    /// (lock screen, Dynamic Island) about twice a second: ActivityKit
    /// throttles faster updates.
    private func pushLiveTextIfDue() {
        guard phase == .recording, liveTextTask == nil else { return }
        let wait = max(0, 0.45 - Date().timeIntervalSince(lastLiveTextPush))
        liveTextTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(wait))
            guard let self, self.phase == .recording else { self?.liveTextTask = nil; return }
            self.lastLiveTextPush = Date()
            self.liveActivityPushes += 1
            if self.liveActivityPushes % 20 == 1 {
                // The audio and process fields tell a muted microphone (buffers
                // arrive, level 0) from no audio (no buffers) and from a
                // process short of memory, when a dictation dies silently
                // (device log of 1 Nov 2026: chars=0, then nothing).
                Diagnostics.record("live activity push #\(self.liveActivityPushes) chars=\(self.liveText.count) \(self.audioHealthSummary()) \(Diagnostics.processSummary())")
            }
            await self.liveActivity.show(phase: .recording, recordingStartedAt: self.recordingStartedAt,
                                         isFlowSession: self.isFlowSessionActive,
                                         liveText: String(self.liveText.suffix(160)),
                                         level: Double(min(max(self.level, 0), 1)))
            self.liveTextTask = nil
        }
    }

    /// `buffers=212 lastBuffer=0.1s level=0.35`: the input tap's liveness.
    func audioHealthSummary() -> String {
        let stats = audio.bufferStats
        let age = stats.secondsSinceLast.map { String(format: "%.1fs", $0) } ?? "-"
        return "buffers=\(stats.count) lastBuffer=\(age) level=\(String(format: "%.2f", audio.level))"
    }

    private func startLevelMeter() {
        levelTask?.cancel()
        levelTask = Task { [weak self, audio] in
            #if DEBUG
            let fakeLevelStart = Date()
            #endif
            while !Task.isCancelled {
                var level = audio.level
                #if DEBUG
                // `-HexMobileFakeEngine`: the simulator hears no voice, so the
                // level is a slow wave 0...1 (a period of 4 s), enough to see
                // the keyboard's microphone key follow it.
                if LaunchOptions.fakeEngine {
                    level = Float(0.5 - 0.5 * cos(Date().timeIntervalSince(fakeLevelStart) * .pi / 2))
                }
                #endif
                self?.level = level
                LoopbackHandoff.shared.setLevel(level)
                // Keeps the Dynamic Island wave moving with the voice.
                self?.pushLiveTextIfDue()
                try? await Task.sleep(for: .milliseconds(33))
            }
        }
    }

    private func stopLevelMeter() {
        levelTask?.cancel()
        levelTask = nil
        level = 0
        LoopbackHandoff.shared.setLevel(0)
    }

    // MARK: - Flow session

    /// Keeps the microphone ready in the background so the keyboard can
    /// start dictation without opening the app.
    /// - Parameter requiresLiveActivity: the start comes from an
    ///   `AudioRecordingIntent` (Action Button, Shortcuts). It fails when no
    ///   Live Activity can be shown (the intent stops without one), and it
    ///   always requests a new activity before starting audio, so a standby
    ///   activity left by the previous session is not silently reused. That
    ///   is no known cure for the refusal of the audio engine: the evening
    ///   device log of 1 Nov 2026 refuted it (see the retry loop below).
    /// - Parameter opener: who asked for it. A session opened here is
    ///   recorded with it. A call with `.other` that finds an intent-opened
    ///   session live takes it over: it is an explicit request (the
    ///   `StartFlowSessionIntent` or the `hexmobile://session/start` link the
    ///   keyboard opens on a mic tap; the Start buttons are not shown while a
    ///   session is live), so the session becomes `.other` and keeps its idle
    ///   timeout. An automatic caller must never call this with a session
    ///   live, or it would keep every Action Button session for the full idle
    ///   time; the keyboard's automatic traffic (`ping`, the loopback pull)
    ///   does not come here.
    func startFlowSession(requiresLiveActivity: Bool = false, opener: FlowSessionOpener = .other) async {
        guard !isFlowSessionActive else {
            if opener == .other, flowSessionOpener == .toggleIntent {
                Diagnostics.record("flow session adopted opener=intent->other waiting=\(awaitingHandoff) phase=\(phase)")
                flowSessionOpener = .other
                awaitingHandoff = false
            }
            scheduleFlowTimeout()
            return
        }
        guard !isFlowSessionStarting else {
            // Another start is running (permissions, activity, audio attempts).
            // Only a second Action Button press cancels it, through
            // `IntentBridge`; any other request just waits for the first one.
            Diagnostics.record("flow start already in progress opener=\(opener.rawValue) request ignored")
            return
        }
        isFlowSessionStarting = true
        startingOpener = opener
        defer {
            isFlowSessionStarting = false
            startingOpener = nil
        }
        let startGeneration = flowStartGeneration
        errorMessage = nil
        LoopbackHandoff.shared.setError(nil)
        guard await Permissions.requestMicrophone(), await Permissions.requestSpeech() else {
            if flowStartGeneration != startGeneration {
                Diagnostics.record("flow start cancelled by a second press stage=permissions")
                return
            }
            let message = String(localized: "Microphone and speech recognition access are needed for a flow session.")
            errorMessage = message
            publishFailure(message)
            return
        }
        var activityShown = false
        if phase == .idle {
            let shown = await liveActivity.show(phase: .ready, recordingStartedAt: nil, isFlowSession: true, fresh: requiresLiveActivity)
            if flowStartGeneration != startGeneration {
                Diagnostics.record("flow start cancelled by a second press stage=activity shown=\(shown)")
                if phase == .idle { await liveActivity.end() }
                return
            }
            if requiresLiveActivity, !shown {
                let message = String(localized: "A flow session started from Shortcuts needs a Live Activity, and it could not start (\(liveActivity.lastFailure ?? "unknown reason")). Open Hex Mobile and start the session from the app.")
                errorMessage = message
                publishFailure(message)
                return
            }
            activityShown = shown
        }
        // Right after a cold launch from the Action Button iOS can refuse the
        // audio engine ('what' on `engine.start`, 1 Nov 2026). The first
        // reading of the afternoon log was that a second press worked because
        // it requested a new Live Activity, so this loop used to end the
        // activity and request another one between rounds of attempts. The
        // evening log (iPhone 16 Pro, build 2785a68) disproved it: the first
        // press, 4 s after the app went to the background, had its activity
        // (`requestedNew=true age=0.1s`) and still failed 4 times; the loop
        // then ended that activity, the new request from the background
        // failed (`shown=false`), and rounds 1 and 2 ran with no activity and
        // failed the same way. The press 17 s later, a new `perform()` in the
        // same process and with the same `AVAudioEngine` that had failed 12
        // times, started on its first attempt, and so did a cold launch.
        // The cause of 'what' is not known. So the activity is kept: attempts
        // go on for about 3 s with growing pauses, the engine is replaced
        // after each `engine.start` failure, and from the first failure on
        // the audio session itself is reset before the next attempt (the
        // ladder below; from the background a reactivation can be refused,
        // which is why this happens only after an attempt has failed). A new
        // activity is requested only if the current one has ended.
        let began = Date()
        var attempt = 0
        var attemptsMade = 0
        var lastError: (any Error)?
        var started = false
        var cancelled = false
        var dumpedOSLog = false
        // Fallback ladder (1 Nov 2026, Action Button): every retry used to
        // change only the engine, so six attempts ran on the same audio
        // session and the same route (`output client: 2 ch, 0 Hz`). From the
        // first `engine.start` failure the session itself is reset before the
        // next attempt, and from the second one it goes to `.record`. A start
        // that works the first time never gets here.
        var engineStartFailures = 0
        var retryVariant: AudioCapture.RetryVariant?
        #if DEBUG
        // `-HexMobileSlowFlowStart N`: the start takes N seconds before the
        // first attempt, to press the Action Button intent twice on the simulator.
        if let slow = LaunchOptions.slowFlowStartSeconds {
            Diagnostics.record("flow start slowed by \(slow)s (debug)")
            if await !pauseUnlessCancelled(.seconds(slow), generation: startGeneration) { cancelled = true }
        }
        #endif
        while !cancelled {
            if flowStartGeneration != startGeneration { cancelled = true; break }
            attemptsMade += 1
            do {
                try audio.start()
                started = true
                Diagnostics.record("flow audio started attempt=\(attempt) elapsed=\(Self.seconds(since: began))s t=\(Diagnostics.secondsSinceLaunch)s activities=\(liveActivity.diagnosticsSummary()) variant=\(retryVariant?.rawValue ?? "none") \(AudioCapture.routeSummary())")
                if let retryVariant {
                    // The attempt worked after this variant was applied (the
                    // order, not a proof that it was the variant that did it).
                    Diagnostics.record("flow audio unblocked by variant=\(retryVariant.rawValue) after \(engineStartFailures) engine.start failures attempt=\(attempt) elapsed=\(Self.seconds(since: began))s")
                }
                break
            } catch {
                lastError = error
                recordAudioFailure(error, path: "flow", attempt: attempt, since: began)
                if (error as? AudioCapture.CaptureError)?.failure.stage == .engineStart {
                    engineStartFailures += 1
                    if !dumpedOSLog {
                        // The audio frameworks' own log of the last seconds,
                        // once per start; read in the background.
                        dumpedOSLog = true
                        AudioFailureLog.capture(path: "flow", attempt: attempt)
                    }
                    audio.replaceEngineAfterFailedStart()
                    Diagnostics.record("flow audio engine replaced after attempt \(attempt)")
                }
            }
            guard attempt < Self.flowAudioRetryDelays.count, phase == .idle else { break }
            guard await pauseUnlessCancelled(Self.flowAudioRetryDelays[attempt], generation: startGeneration) else {
                cancelled = true
                break
            }
            guard phase == .idle else { break }
            attempt += 1
            if activityShown, !liveActivity.hasActiveActivity {
                activityShown = await liveActivity.show(phase: .ready, recordingStartedAt: nil, isFlowSession: true, fresh: true)
                Diagnostics.record("flow live activity re-requested because the current one ended shown=\(activityShown) activities=\(liveActivity.diagnosticsSummary())")
                // An intent that records without a Live Activity is terminated
                // by AppIntents (see `start()`): stop instead of going on.
                if !activityShown, requiresLiveActivity { break }
            }
            // No suspension point from here to `audio.start()` at the top of
            // the loop: the session is never inactive across an `await`.
            if engineStartFailures > 0 {
                let variant: AudioCapture.RetryVariant = engineStartFailures == 1 ? .sessionReset : .recordOnly
                retryVariant = variant
                let steps = audio.prepareRetry(variant)
                Diagnostics.record("flow audio retry variant=\(variant.rawValue) next attempt=\(attempt) engineStartFailures=\(engineStartFailures) \(steps)")
            }
        }
        if cancelled || flowStartGeneration != startGeneration {
            // A second press: nothing was started, so nothing stays open. The
            // press that cancelled returns without dictating (`IntentBridge`).
            Diagnostics.record("flow start cancelled by a second press attempts=\(attemptsMade) elapsed=\(Self.seconds(since: began))s started=\(started)")
            if started { audio.stop() } else { audio.restoreNormalCategoryIfIdle(cause: "start-cancelled") }
            if phase == .idle { await liveActivity.end() }
            return
        }
        guard started else {
            Diagnostics.record("flow audio failed attempts=\(attemptsMade) elapsed=\(Self.seconds(since: began))s variant=\(retryVariant?.rawValue ?? "none") last: \(Self.audioFailureFields(lastError))")
            audio.restoreNormalCategoryIfIdle(cause: "start-failed")
            // Nothing is left open: the activity ends here and no session
            // exists. A second press has always worked (device log of 1 Nov
            // 2026), so an Action Button start says so; the system error is
            // in the diagnostics log. Other starts keep the system's text.
            errorMessage = opener == .toggleIntent
                ? String(localized: "Dictation could not start. Press the Action Button again.")
                : lastError?.localizedDescription
            if phase == .idle { await liveActivity.end() }
            if let message = errorMessage { publishFailure(message) }
            return
        }
        isFlowSessionActive = true
        flowSessionOpener = opener
        // Whisper loads while the session is ready, alongside whatever
        // the user does next; it stays until the session ends.
        beginWhisperLoadIfChosen(reason: "flow-session")
        if phase == .idle { scheduleFlowTimeout() }
        DarwinNotificationCenter.shared.post(.pong)
        postFlowState(phase == .recording ? .recording : .idle)
    }

    /// Abandons the flow session start that is running, if any: a second press
    /// of the Action Button inside the window of the audio attempts. The start
    /// notices within 50 ms, releases the Live Activity it requested and
    /// returns without an error message.
    func cancelFlowSessionStart() {
        guard isFlowSessionStarting else { return }
        flowStartGeneration += 1
        Diagnostics.record("flow start cancel requested")
    }

    /// Sleeps for `duration` in short steps; `false` when the start identified
    /// by `generation` was cancelled meanwhile.
    private func pauseUnlessCancelled(_ duration: Duration, generation: Int) async -> Bool {
        let step = Duration.milliseconds(50)
        var left = duration
        while left > .zero {
            if flowStartGeneration != generation { return false }
            let slice = min(step, left)
            try? await Task.sleep(for: slice)
            left -= slice
        }
        return flowStartGeneration == generation
    }

    /// Ends the flow session and releases the microphone (unless recording).
    /// - Parameter dismissActivity: also end the Live Activity instead of
    ///   leaving it in standby. For a session nobody asked for, such as the
    ///   one an Action Button start opened before its dictation failed.
    /// - Parameter cause: for the diagnostics log.
    func endFlowSession(dismissActivity: Bool = false, cause: FlowSessionEnd = .user) async {
        guard isFlowSessionActive else { return }
        Diagnostics.record("flow session ended cause=\(cause.rawValue) opener=\(flowSessionOpener?.rawValue ?? "-") dismissActivity=\(dismissActivity) phase=\(phase)")
        isFlowSessionActive = false
        flowSessionOpener = nil
        awaitingHandoff = false
        flowTimeoutTask?.cancel()
        flowTimeoutTask = nil
        flowSessionEndsAt = nil
        if phase == .idle {
            audio.stop()
            if dismissActivity {
                await liveActivity.end()
            } else {
                // Microphone off, island kept (standby); its stop button ends it.
                await liveActivity.show(phase: .standby, recordingStartedAt: nil, isFlowSession: true)
            }
            DarwinNotificationCenter.shared.post(.sessionEnded)
            await whisper.release(reason: "flow-session-ended")
        }
        // With a dictation still running, `finishCycle` gives the model back.
    }

    /// The idle time of the current flow session in seconds; `nil` when it
    /// never ends by itself (Settings > End After Idle > Never). A session the
    /// Action Button opened is the exception: it lasts one dictation, so
    /// Never does not apply and it keeps the default idle time.
    private var flowIdleInterval: TimeInterval? {
        if let interval = settings.flowSessionDuration.interval { return interval }
        return (flowSessionOpener ?? startingOpener) == .toggleIntent ? FlowSessionDuration.default.interval : nil
    }

    /// Whether the current (or starting) flow session has no idle timeout
    /// (Never), which the Live Activity shows next to the session.
    var flowSessionNeverEnds: Bool {
        (isFlowSessionActive || isFlowSessionStarting) && flowIdleInterval == nil
    }

    /// The idle time was changed in Settings: a session that is waiting takes
    /// the new one at once (a timer for 5, 15 or 60 minutes; none for Never)
    /// and the Live Activity updates. One that is recording, starting or
    /// handing a text to the keyboard keeps its own timing: the next idle
    /// period uses the new value.
    func flowSessionDurationChanged() async {
        guard isFlowSessionActive else { return }
        Diagnostics.record("flow session duration changed to \(settings.flowSessionDuration) phase=\(phase) starting=\(isFlowSessionStarting) handoff=\(awaitingHandoff)")
        guard phase == .idle, !isFlowSessionStarting, !awaitingHandoff else { return }
        scheduleFlowTimeout()
        await liveActivity.show(phase: .ready, recordingStartedAt: nil, isFlowSession: true)
    }

    /// - Parameter interval: seconds until the session ends if nothing happens;
    ///   the idle time from Settings when `nil` (and no timer at all for Never).
    private func scheduleFlowTimeout(after interval: TimeInterval? = nil) {
        flowTimeoutTask?.cancel()
        flowTimeoutTask = nil
        guard isFlowSessionActive else { return }
        guard let interval = interval ?? flowIdleInterval else {
            flowSessionEndsAt = nil
            Diagnostics.record("flow timeout none (never) opener=\(flowSessionOpener?.rawValue ?? "-")")
            return
        }
        flowSessionEndsAt = Date().addingTimeInterval(interval)
        Diagnostics.record("flow timeout in \(Int(interval))s opener=\(flowSessionOpener?.rawValue ?? "-")")
        flowTimeoutTask = Task { [weak self] in
            try? await Task.sleep(for: .seconds(interval))
            guard !Task.isCancelled, let self, self.phase == .idle else { return }
            // An intent-opened session never leaves its Live Activity in standby.
            await self.endFlowSession(dismissActivity: self.flowSessionOpener == .toggleIntent, cause: .idleTimeout)
        }
    }

    private func pauseFlowTimeout() {
        flowTimeoutTask?.cancel()
        flowTimeoutTask = nil
        flowSessionEndsAt = nil
    }

    // MARK: - Keyboard and widget signals

    /// Whether the keyboard may control dictation right now.
    private var acceptsKeyboard: Bool { isFlowSessionActive || phase != .idle }

    private func postFlowState(_ state: HexMobileIPC.FlowState) {
        DarwinNotificationCenter.shared.post(state.signal)
    }

    private func startListening() {
        signalTask = Task { [weak self] in
            for await signal in DarwinNotificationCenter.shared.signals([.ping, .toggle, .cancel, .recent]) {
                guard let self else { return }
                await self.handle(signal)
            }
        }
        stopSignalTask = Task { [weak self] in
            for await _ in DarwinNotificationCenter.shared.notifications(named: [SharedSignal.stop]) {
                guard let self else { return }
                await self.stopFromLiveActivity()
            }
        }
        interruptionTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: AVAudioSession.interruptionNotification) {
                guard let self else { return }
                let rawType = notification.userInfo?[AVAudioSessionInterruptionTypeKey] as? UInt
                if rawType == AVAudioSession.InterruptionType.began.rawValue {
                    await self.handleInterruption()
                }
            }
        }
        configurationTask = Task { [weak self] in
            for await notification in NotificationCenter.default.notifications(named: .AVAudioEngineConfigurationChange) {
                guard let self else { return }
                guard self.audio.isConfigurationChange(notification) else { continue }
                await self.handleAudioConfigurationChange(mediaServicesReset: false)
            }
        }
        mediaResetTask = Task { [weak self] in
            for await _ in NotificationCenter.default.notifications(named: AVAudioSession.mediaServicesWereResetNotification) {
                guard let self else { return }
                await self.handleAudioConfigurationChange(mediaServicesReset: true)
            }
        }
    }

    private func handle(_ signal: HexMobileIPC.Signal) async {
        switch signal {
        case .ping:
            // A keyboard that shows after a failure (it was hidden when the
            // signal went out) learns of it from the answer.
            defer { if LoopbackHandoff.shared.hasError { DarwinNotificationCenter.shared.post(.startFailed) } }
            guard acceptsKeyboard else {
                DarwinNotificationCenter.shared.post(.sessionEnded)
                return
            }
            DarwinNotificationCenter.shared.post(.pong)
            postCurrentFlowState()
        case .toggle:
            guard acceptsKeyboard else {
                // Tell the keyboard instead of ignoring it silently.
                DarwinNotificationCenter.shared.post(.sessionEnded)
                return
            }
            Diagnostics.record("keyboard toggle phase=\(phase)")
            await toggle(trigger: .keyboard)
        case .cancel:
            // The ✕ key: drop the dictation, with no text for anyone. `cancel()`
            // never writes the pasteboard, offers nothing over loopback and adds
            // nothing to the history, so nothing is left pending by this
            // dictation.
            // The Close key of the keyboard's error message sends this too: the
            // failure it showed is done with.
            LoopbackHandoff.shared.setError(nil)
            guard acceptsKeyboard else {
                DarwinNotificationCenter.shared.post(.sessionEnded)
                return
            }
            let before = phase
            Diagnostics.record("keyboard cancel phase=\(before) pending=\(LoopbackHandoff.shared.hasPending)")
            await cancel()
            // Nothing to cancel (idle, or already transcribing): tell the
            // keyboard where things stand, as `finishCycle` does otherwise.
            if before == .idle || before == .processing { postCurrentFlowState() }
            Diagnostics.record("keyboard cancel done phase=\(phase) flow=\(isFlowSessionActive) pending=\(LoopbackHandoff.shared.hasPending) changeCount=\(UIPasteboard.general.changeCount)")
        case .recent:
            // The keyboard's insert key was held: its picker is about to pull
            // the recent dictations. Open the listener for a few seconds —
            // the only moment recent text is reachable on the port.
            LoopbackHandoff.shared.prepareRecentWindow()
        default:
            break
        }
    }

    /// Tells the keyboard what the controller is doing.
    private func postCurrentFlowState() {
        switch phase {
        case .idle: postFlowState(.idle)
        case .preparing, .recording: postFlowState(.recording)
        case .processing: postFlowState(.processing)
        }
    }

    /// Live Activity stop button: stop recording, abandon a start that is
    /// still preparing, or end the flow session.
    func stopFromLiveActivity() async {
        Diagnostics.record("stop cause=live-activity phase=\(phase)")
        switch phase {
        case .recording:
            await stop()
        case .preparing:
            await cancel()
        case .idle, .processing:
            if isFlowSessionActive {
                await endFlowSession(cause: .liveActivity)
            } else if phase == .idle {
                await liveActivity.end()
            }
        }
    }

    private func handleInterruption() async {
        Diagnostics.record("stop cause=interruption phase=\(phase)")
        switch phase {
        case .preparing:
            await cancel(message: String(localized: "Dictation was interrupted. Try again."))
        case .recording:
            await stop()
        case .idle, .processing:
            break
        }
        if isFlowSessionActive { await endFlowSession(cause: .interruption) }
    }

    /// The system stopped the audio engine: the route or hardware format
    /// changed (Bluetooth headphones, CarPlay) or media services were reset.
    /// A recording keeps what was captured so far (its converter was built
    /// for the old format); a flow session restarts capture with the new
    /// format, or ends with a message when that fails.
    private func handleAudioConfigurationChange(mediaServicesReset: Bool) async {
        Diagnostics.record("stop cause=audio-config reset=\(mediaServicesReset) phase=\(phase) route=\(AVAudioSession.sharedInstance().currentRoute.inputs.first?.portType.rawValue ?? "-")")
        if mediaServicesReset {
            audio.rebuildAfterMediaServicesReset()
        }
        switch phase {
        case .preparing:
            await cancel(message: String(localized: "The audio route changed. Try again."))
        case .recording:
            audio.setSink(nil)
            await stop()
        case .idle, .processing:
            break
        }
        guard isFlowSessionActive else { return }
        do {
            try audio.restart()
        } catch {
            await endFlowSession(cause: .audioConfig)
            let message = String(localized: "The flow session ended because the audio route changed: \(error.localizedDescription)")
            errorMessage = message
            publishFailure(message)
        }
    }

    #if DEBUG
    /// `-HexMobileAutoHandoff`: what an Action Button dictation that ended in
    /// the background with a text leaves behind, without a transcription:
    /// an intent-opened session, a synthetic payload offered over loopback,
    /// and the end of the cycle.
    func debugHoldIntentSessionWithSyntheticPayload() async {
        await startFlowSession(requiresLiveActivity: true, opener: .toggleIntent)
        guard isFlowSessionActive else { return }
        let record = DictationRecord(createdAt: Date(), text: "synthetic handoff payload", duration: 1, locale: "it-IT", modeName: "debug", engine: "debug")
        LoopbackHandoff.shared.offer(DictationPayload(record: record))
        await finishCycle()
    }

    /// Synthetic state for screenshots. Never persisted.
    func loadDemoState(lastRecord: DictationRecord) {
        self.lastRecord = lastRecord
    }
    #endif
}
