import Foundation
import HexMobileCore
import HexMobileSpeech
import Observation
import UIKit

/// The app's long-lived objects. App Intents can run before any scene is
/// connected, so they reach the controller through this shared instance.
@MainActor
@Observable
final class AppServices {
    static let shared = AppServices()

    let settings: SettingsStore
    let sync: SyncManager
    let transfers: TransfersModel
    let history: HistoryModel
    let dictation: DictationController
    let speechAssets: SpeechAssetsModel

    /// Whether the full-screen "listening" view of the `dictate` route is up
    /// (see ``KeyboardDictationView``).
    var keyboardDictationShown = false

    private init() {
        let settings = SettingsStore()
        let sync = SyncManager()
        let history = HistoryModel(retention: settings.historyRetention)
        self.settings = settings
        self.sync = sync
        self.transfers = TransfersModel(sync: sync)
        self.history = history
        #if DEBUG
        let finalPass: any FinalPassEngine = LaunchOptions.fakeFinalPass.map { FakeFinalPassEngine(mode: $0) } ?? AppleFinalPassEngine()
        let dictation = LaunchOptions.fakeEngine
            ? DictationController(settings: settings, sync: sync, history: history, engine: FakeTranscriptionEngine(), finalPassEngine: finalPass)
            : DictationController(settings: settings, sync: sync, history: history, finalPassEngine: finalPass)
        #else
        let dictation = DictationController(settings: settings, sync: sync, history: history)
        #endif
        let speechAssets = SpeechAssetsModel()
        speechAssets.onInstalled = { locale in dictation.modelInstalled(for: locale) }
        LoopbackHandoff.shared.onSettled = { outcome in
            Task { await dictation.handoffSettled(outcome) }
        }
        self.dictation = dictation
        self.speechAssets = speechAssets
        Diagnostics.observeLifecycle()
        // No dictation is recording at launch: a recording file still there is
        // from a run that was killed.
        let leftovers = AppPaths.purgeTemporaryRecordings()
        if leftovers > 0 { Diagnostics.record("temporary recordings purged count=\(leftovers)") }
        #if DEBUG
        if LaunchOptions.demoContent { DemoContent.load(into: self) }
        #endif
    }

    /// Foreground refresh: history pruning, sync folder and model status.
    func refreshOnForeground() async {
        #if DEBUG
        if LaunchOptions.demoContent { return }
        #endif
        await history.reload()
        await sync.refresh(historyExport: settings.shareHistory ? history.jsonLinesExport() : nil)
        await transfers.refresh()
        await speechAssets.refresh(for: currentLocale)
    }

    /// The locale dictation will use.
    var currentLocale: Locale {
        settings.recognitionLocale(syncedLanguage: sync.bundle?.language)
    }

    #if DEBUG
    /// `-HexMobileAutoStart YES`: dictates once at launch and stops after
    /// `-HexMobileAutoStartSeconds` seconds, so a simulator run exercises the
    /// start and the transcription without a tap. Logs no text.
    func runAutoStart() async {
        let seconds = LaunchOptions.autoStartSeconds
        Diagnostics.record("autostart begin seconds=\(seconds)")
        if let script = LaunchOptions.autoHandoff {
            await runAutoHandoff(script: script)
            return
        }
        if let link = LaunchOptions.autoOpenURL.flatMap(URL.init(string:)) {
            // `-HexMobileAutoOpenURL <url>`: the link as `onOpenURL` delivers it.
            // `xcrun simctl openurl` stops at the system's «open in Hex
            // Mobile?» alert, which only a tap on the screen answers.
            await handle(url: link)
            try? await Task.sleep(for: .seconds(seconds))
            Diagnostics.record("autoopenurl after \(seconds)s phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) error=\(dictation.errorMessage ?? "-")")
            return
        }
        if LaunchOptions.autoOSLog {
            // `-HexMobileAutoOSLog YES`: a flow session so this process logs
            // audio, then the dump that follows an `engine.start` failure,
            // to check on the simulator what `OSLogStore` returns.
            await dictation.startFlowSession()
            AudioFailureLog.capture(path: "debug", attempt: 0)
            try? await Task.sleep(for: .seconds(min(seconds, 3)))
            await dictation.endFlowSession()
            return
        }
        if LaunchOptions.autoFlow {
            // `-HexMobileAutoFlow YES`: a flow session with no dictation, to see
            // the audio liveness fields of the diagnostics log fill in.
            await dictation.startFlowSession()
            Diagnostics.record("autoflow begin active=\(dictation.isFlowSessionActive) error=\(dictation.errorMessage ?? "-")")
            if LaunchOptions.autoDurationChange {
                // `-HexMobileAutoDurationChange YES`: what the picker in Settings
                // does, 3 s apart: Never, then 15 minutes, then 5 minutes.
                for duration in [FlowSessionDuration.never, .minutes15, .minutes5] {
                    try? await Task.sleep(for: .seconds(3))
                    settings.flowSessionDuration = duration
                    await dictation.flowSessionDurationChanged()
                }
            }
            try? await Task.sleep(for: .seconds(seconds))
            Diagnostics.record("autoflow after \(seconds)s \(dictation.audioHealthSummary()) \(Diagnostics.processSummary())")
            await dictation.endFlowSession()
            return
        }
        if LaunchOptions.autoStartViaIntent {
            if LaunchOptions.autoRacePressAfterMilliseconds != nil {
                await runAutoStartRace()
            } else {
                await runAutoStartViaIntent(seconds: seconds)
            }
            return
        }
        await dictation.start()
        Diagnostics.record("autostart started phase=\(dictation.phase) error=\(dictation.errorMessage ?? "-")")
        guard dictation.phase == .recording else {
            // `-HexMobileAutoInstall YES`: what the Download Model button does,
            // then the controller's state, to observe the install card going away.
            if LaunchOptions.autoInstall, let locale = dictation.missingModelLocale {
                Diagnostics.record("autoinstall begin locale=\(locale.identifier(.bcp47))")
                await speechAssets.install(for: locale)
                Diagnostics.record("autoinstall done assets=\(speechAssets.state.map { "\($0)" } ?? "-") assetsError=\(speechAssets.errorMessage ?? "-") missingModel=\(dictation.missingModelLocale?.identifier(.bcp47) ?? "-") banner=\(dictation.errorMessage ?? "-")")
            }
            return
        }
        try? await Task.sleep(for: .seconds(seconds))
        let text = await dictation.stop()
        Diagnostics.record("autostart stopped chars=\(text?.count ?? 0) phase=\(dictation.phase) error=\(dictation.errorMessage ?? "-")")
    }

    /// `-HexMobileAutoHandoff hold|press|adopt`: opens an intent session with a
    /// synthetic payload offered over loopback and waits for the keyboard's
    /// pull (`printf 'HEXMOBILE-PULL 1\n' | nc 127.0.0.1 47391` from the Mac).
    /// `press` first presses the Action Button intent after 3 s (the start
    /// fails on the simulator: it must cancel the wait and, with the payload
    /// still pending, keep the session); `adopt` runs the
    /// `StartFlowSessionIntent` after 3 s (the session must stay).
    private func runAutoHandoff(script: String) async {
        await dictation.debugHoldIntentSessionWithSyntheticPayload()
        Diagnostics.record("autohandoff begin script=\(script) flow=\(dictation.isFlowSessionActive) opener=\(dictation.flowSessionOpener?.rawValue ?? "-") pending=\(LoopbackHandoff.shared.hasPending)")
        try? await Task.sleep(for: .seconds(3))
        switch script {
        case "press":
            do {
                let text = try await IntentBridge.toggleDictation()
                Diagnostics.record("autohandoff press returned chars=\(text.count) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) pending=\(LoopbackHandoff.shared.hasPending)")
            } catch {
                Diagnostics.record("autohandoff press threw message=\(error.localizedDescription.prefix(60)) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) pending=\(LoopbackHandoff.shared.hasPending)")
            }
        case "adopt":
            do {
                try await IntentBridge.startFlowSession()
                Diagnostics.record("autohandoff adopt returned flow=\(dictation.isFlowSessionActive) opener=\(dictation.flowSessionOpener?.rawValue ?? "-")")
            } catch {
                Diagnostics.record("autohandoff adopt threw message=\(error.localizedDescription.prefix(60))")
            }
        default:
            break
        }
    }

    /// `-HexMobileAutoStartIntent YES -HexMobileAutoRaceMs N`: two presses of the
    /// Action Button intent N ms apart, the first still inside its flow session
    /// start (combine with `-HexMobileSlowFlowStart`). The second must cancel the
    /// start; the first must end without a session, a dictation or an error.
    private func runAutoStartRace() async {
        let gap = LaunchOptions.autoRacePressAfterMilliseconds ?? 700
        let first = Task { @MainActor in
            do {
                let text = try await IntentBridge.toggleDictation()
                Diagnostics.record("autorace press1 returned chars=\(text.count) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) starting=\(dictation.isFlowSessionStarting) error=\(dictation.errorMessage ?? "-")")
            } catch {
                Diagnostics.record("autorace press1 threw message=\(error.localizedDescription.prefix(80))")
            }
        }
        try? await Task.sleep(for: .milliseconds(gap))
        do {
            let text = try await IntentBridge.toggleDictation()
            Diagnostics.record("autorace press2 returned chars=\(text.count) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) starting=\(dictation.isFlowSessionStarting)")
        } catch {
            Diagnostics.record("autorace press2 threw message=\(error.localizedDescription.prefix(80))")
        }
        await first.value
        try? await Task.sleep(for: .seconds(1))
        Diagnostics.record("autorace end phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) starting=\(dictation.isFlowSessionStarting) activities=\(LiveActivityManager.activitySummary()) error=\(dictation.errorMessage ?? "-")")
    }

    /// `-HexMobileAutoStartIntent YES`: the same, through
    /// `IntentBridge.toggleDictation`, as two presses of the Action Button.
    private func runAutoStartViaIntent(seconds: Int) async {
        func press(_ label: String) async {
            do {
                let text = try await IntentBridge.toggleDictation()
                Diagnostics.record("autostart intent \(label) returned chars=\(text.count) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive)")
            } catch {
                Diagnostics.record("autostart intent \(label) threw message=\(error.localizedDescription.prefix(80)) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive)")
            }
        }
        await press("press1")
        guard dictation.phase == .recording else { return }
        try? await Task.sleep(for: .seconds(seconds))
        await press("press2")
    }
    #endif

    /// Handles `hexmobile://` links.
    func handle(url: URL) async {
        if url.isFileURL {
            await transfers.openDocument(url)
            return
        }
        guard let route = HexMobileIPC.Route(url: url) else { return }
        switch route {
        case .sessionStart:
            await dictation.startFlowSession()
        case .dictate:
            await dictateFromRoute(source: HexMobileIPC.Route.source(of: url) ?? "-")
        }
    }

    /// `hexmobile://dictate`: the microphone key of the keyboard without a flow
    /// session. The app is in the foreground now, which is when the audio
    /// session may start: it opens the flow session if there is none, starts
    /// dictating (trigger keyboard, so the text goes back to the keyboard when
    /// it stops) and shows ``KeyboardDictationView``. The dictation does not
    /// wait for the user to go back to the previous app; it stops from the
    /// keyboard, the Live Activity or that view.
    func dictateFromRoute(source: String) async {
        let state = UIApplication.shared.applicationState
        Diagnostics.record("route dictate source=\(source) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) starting=\(dictation.isFlowSessionStarting) app=\(state.rawValue)")
        if dictation.phase != .idle {
            // A repeated link, or the keyboard started it meanwhile: just show it.
            Diagnostics.record("route dictate already phase=\(dictation.phase)")
            keyboardDictationShown = dictation.phase != .processing
            return
        }
        keyboardDictationShown = true
        // `onOpenURL` can run before the scene is active; the audio session
        // is started from the foreground (the reason of this route).
        let began = Date()
        while UIApplication.shared.applicationState != .active, Date().timeIntervalSince(began) < 3 {
            try? await Task.sleep(for: .milliseconds(50))
        }
        let waited = String(format: "%.1f", Date().timeIntervalSince(began))
        await dictation.startFlowSession()
        guard dictation.isFlowSessionActive else {
            // The reason is in `dictation.errorMessage`, shown by the view.
            Diagnostics.record("route dictate flow session failed waited=\(waited)s app=\(UIApplication.shared.applicationState.rawValue) error=\(dictation.errorMessage ?? "-")")
            return
        }
        await dictation.start(trigger: .keyboard)
        Diagnostics.record("route dictate started=\(dictation.phase == .recording) phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive) waited=\(waited)s app=\(UIApplication.shared.applicationState.rawValue) error=\(dictation.errorMessage ?? "-")")
    }
}

/// Entry points used by App Intents (app process only).
@MainActor
enum IntentBridge {
    /// Starts dictation, or stops it and returns the final text ("" when starting).
    ///
    /// A start that fails always throws, so Shortcuts shows the reason. It
    /// used to end quietly with `""` for every failure that was not about the
    /// Live Activity or the foreground: the Action Button then did nothing
    /// visible and the flow session this call had opened stayed up, with the
    /// microphone on and the Live Activity showing `ready`, until its
    /// 5-minute timeout (simulator, 1 Nov 2026: `noCompatibleAudioFormat`,
    /// activity never ended). Only a stop that heard nothing ends quietly.
    static func toggleDictation() async throws -> String {
        let dictation = AppServices.shared.dictation
        Diagnostics.record("intent toggle phase=\(dictation.phase) flow=\(dictation.isFlowSessionActive)")
        // A press that cannot start or stop anything is not silent in the log:
        // `toggle` abandons a start still preparing and ignores processing.
        switch dictation.phase {
        case .preparing:
            Diagnostics.record("intent press cancelled phase=preparing flow=\(dictation.isFlowSessionActive)")
        case .processing:
            Diagnostics.record("intent press ignored phase=processing flow=\(dictation.isFlowSessionActive)")
        case .idle, .recording:
            break
        }
        // A second press while the first one is still starting the flow session
        // (the audio attempts last about 3 s when iOS refuses the engine): the
        // session is not active yet, so without this the press would start a
        // second loop on the same audio. It cancels the start, like a second
        // press cancels a dictation still preparing, and does nothing else.
        if dictation.isFlowSessionStarting {
            dictation.cancelFlowSessionStart()
            Diagnostics.record("intent press cancelled flow start")
            return ""
        }
        // Called with the controller idle, this toggle is a start; with a
        // recording in progress it is a stop.
        let wasStart = dictation.phase == .idle
        var openedFlowSession = false
        // Same path as the keyboard, which works: open a flow session first
        // (microphone warm, Live Activity up), then dictate inside it. A cold
        // start from the Action Button lost most of the audio (1 Nov 2026:
        // 5 characters out of 8 seconds, often nothing recognized).
        if dictation.phase == .idle, !dictation.isFlowSessionActive {
            await dictation.startFlowSession(requiresLiveActivity: true, opener: .toggleIntent)
            openedFlowSession = dictation.isFlowSessionActive
            Diagnostics.record("intent flow session started=\(dictation.isFlowSessionActive)")
            if !dictation.isFlowSessionActive, let message = dictation.errorMessage {
                throw IntentFailure(message: message)
            }
            if !dictation.isFlowSessionActive {
                // No error and no session: a second press cancelled this start.
                // Dictating now would start a dictation nobody asked for.
                Diagnostics.record("intent start abandoned during flow session start")
                return ""
            }
        }
        let text = await dictation.toggle(trigger: .intent)
        if let message = dictation.errorMessage, text == nil, dictation.phase == .idle {
            let visibility = dictation.lastLiveActivityFailure?.contains("visibility") ?? false
            let needsForeground = visibility || dictation.lastStartNeedsForeground
            let quietStop = !wasStart && dictation.lastStopFoundNoSpeech
            Diagnostics.record("intent failed start=\(wasStart) openedFlow=\(openedFlowSession) quiet=\(quietStop) visibility=\(visibility) foreground=\(needsForeground) message=\(message.prefix(60))")
            // The session this intent opened has no dictation to serve: end
            // it and its Live Activity instead of leaving the microphone on.
            if openedFlowSession { await dictation.endFlowSession(dismissActivity: true, cause: .intentFailed) }
            // An empty transcript is not an error worth a Shortcuts alert
            // (it looked like a crash): end quietly with no text.
            if quietStop { return "" }
            throw IntentFailure(message: message, needsForeground: needsForeground)
        }
        // A start that ended without recording and without an error was
        // abandoned by a second press (`toggle` cancels a start still
        // preparing). The session this call opened has nothing to serve: close
        // it, as in the failure branch. `phase` can still be `.preparing`
        // here while that press finishes its cancel, which closes the
        // session itself.
        if wasStart, text == nil, dictation.errorMessage == nil, dictation.phase != .recording {
            Diagnostics.record("intent start abandoned phase=\(dictation.phase) openedFlow=\(openedFlowSession) flow=\(dictation.isFlowSessionActive)")
            if openedFlowSession, dictation.phase == .idle { await dictation.endFlowSession(dismissActivity: true, cause: .intentFailed) }
            return ""
        }
        return text ?? ""
    }

    static func stopFromLiveActivity() async {
        await AppServices.shared.dictation.stopFromLiveActivity()
    }

    static func startFlowSession() async throws {
        let dictation = AppServices.shared.dictation
        // Started from an AudioRecordingIntent: without a Live Activity the
        // system stops the background recording.
        await dictation.startFlowSession(requiresLiveActivity: true)
        if !dictation.isFlowSessionActive, let message = dictation.errorMessage {
            throw IntentFailure(message: message)
        }
    }
}

/// An error whose message is shown by Shortcuts.
struct IntentFailure: LocalizedError {
    var message: String
    /// The Live Activity was refused from the background (`.visibility`).
    var needsForeground = false
    var errorDescription: String? { message }
}

/// Launch arguments used for screenshots and debugging.
enum LaunchOptions {
    /// `-HexMobileTab dictate|history|vocabulary|settings`
    static var initialTab: String? { UserDefaults.standard.string(forKey: "HexMobileTab") }
    /// `-HexMobileDemo YES` loads synthetic content (Debug builds only).
    static var demoContent: Bool { UserDefaults.standard.bool(forKey: "HexMobileDemo") }
    #if DEBUG
    /// `-HexMobileAutoStart YES` dictates once when the app becomes active
    /// (Debug builds only, see ``AppServices/runAutoStart()``).
    static var autoStart: Bool { UserDefaults.standard.bool(forKey: "HexMobileAutoStart") }
    /// `-HexMobileAutoStartIntent YES`: with `-HexMobileAutoStart`, runs the
    /// Action Button path (`IntentBridge.toggleDictation`) twice.
    static var autoStartViaIntent: Bool { UserDefaults.standard.bool(forKey: "HexMobileAutoStartIntent") }
    /// `-HexMobileFakeEngine YES`: dictations run on ``FakeTranscriptionEngine``
    /// (Debug builds only), because the simulator has no speech model.
    static var fakeEngine: Bool { UserDefaults.standard.bool(forKey: "HexMobileFakeEngine") }
    /// `-HexMobileFakeClip <absolute path>`: with `-HexMobileFakeEngine`, the
    /// recording is this audio file (16 kHz mono 16-bit, as the analyzer
    /// writes it) instead of a second of silence, so Whisper has speech to read
    /// on a simulator (Debug builds only).
    static var fakeClipPath: String? { UserDefaults.standard.string(forKey: "HexMobileFakeClip") }
    /// `-HexMobileFakeFinalPass ok|messy|slow|fail|short|empty`: the final pass is
    /// ``FakeFinalPassEngine`` (Debug builds only).
    static var fakeFinalPass: String? { UserDefaults.standard.string(forKey: "HexMobileFakeFinalPass") }
    /// `-HexMobileWhisperDeadline N`: Whisper runs with a deadline of N seconds
    /// whatever the budget says (Debug builds only): the simulator runs the
    /// model on the CPU, far slower than the phone.
    static var whisperDeadlineSeconds: Double? {
        let value = UserDefaults.standard.double(forKey: "HexMobileWhisperDeadline")
        return value > 0 ? value : nil
    }
    /// `-HexMobileCleanupTimeoutMs N`: the cleanup gets N ms instead of its
    /// share of the budget, to walk the timeout fallback (Debug builds only).
    static var cleanupTimeoutMilliseconds: Int? {
        let value = UserDefaults.standard.integer(forKey: "HexMobileCleanupTimeoutMs")
        return value > 0 ? value : nil
    }
    /// `-HexMobileAutoOpenURL <url>`: with `-HexMobileAutoStart`, handles `url`
    /// as if the system had opened it (see ``AppServices/runAutoStart()``).
    static var autoOpenURL: String? { UserDefaults.standard.string(forKey: "HexMobileAutoOpenURL") }
    /// `-HexMobileAutoRaceMs N`: with `-HexMobileAutoStartIntent`, presses the
    /// intent twice N ms apart (see ``AppServices/runAutoStartRace()``).
    static var autoRacePressAfterMilliseconds: Int? {
        let value = UserDefaults.standard.integer(forKey: "HexMobileAutoRaceMs")
        return value > 0 ? value : nil
    }
    /// `-HexMobileAutoHandoff hold|press|adopt`: with `-HexMobileAutoStart`, an
    /// intent session holding a synthetic payload (see ``AppServices/runAutoHandoff(script:)``).
    static var autoHandoff: String? { UserDefaults.standard.string(forKey: "HexMobileAutoHandoff") }
    /// `-HexMobileAutoFlow YES`: with `-HexMobileAutoStart`, opens a flow
    /// session for the listening seconds instead of dictating.
    static var autoFlow: Bool { UserDefaults.standard.bool(forKey: "HexMobileAutoFlow") }
    /// `-HexMobileAutoDurationChange YES`: with `-HexMobileAutoFlow`, changes the
    /// idle time of the running flow session like the picker in Settings.
    static var autoDurationChange: Bool { UserDefaults.standard.bool(forKey: "HexMobileAutoDurationChange") }
    /// `-HexMobileAutoOSLog YES`: with `-HexMobileAutoStart`, opens a flow
    /// session and writes the audio OSLog dump (see ``AudioFailureLog``).
    static var autoOSLog: Bool { UserDefaults.standard.bool(forKey: "HexMobileAutoOSLog") }
    /// `-HexMobileSlowFlowStart N`: a flow session start waits N seconds before
    /// its first audio attempt (see ``DictationController/startFlowSession(requiresLiveActivity:opener:)``).
    static var slowFlowStartSeconds: Int? {
        let value = UserDefaults.standard.integer(forKey: "HexMobileSlowFlowStart")
        return value > 0 ? value : nil
    }
    /// `-HexMobileKeyboardProbe YES`: a text field takes focus at launch and asks
    /// for the Hex Mobile keyboard (see ``DebugKeyboardProbe``).
    static var keyboardProbe: Bool { UserDefaults.standard.bool(forKey: "HexMobileKeyboardProbe") }
    /// `-HexMobileSimulateWhat N`: the first N `engine.start` calls fail with
    /// a simulated `'what'` (2003329396), to run the retry ladder of a flow
    /// session start on the simulator, where the real error never happens.
    static var simulateWhatFailures: Int { max(0, UserDefaults.standard.integer(forKey: "HexMobileSimulateWhat")) }
    /// `-HexMobileAutoInstall YES`: with `-HexMobileAutoStart`, installs the
    /// missing speech model right after the start fails for it.
    static var autoInstall: Bool { UserDefaults.standard.bool(forKey: "HexMobileAutoInstall") }
    /// `-HexMobileScroll bottom`: scrolls the Dictate screen to its end.
    static var scrollToBottom: Bool { UserDefaults.standard.string(forKey: "HexMobileScroll") == "bottom" }
    /// `-HexMobileAutoStartSeconds N`: how long the auto-started dictation
    /// listens (default 6).
    static var autoStartSeconds: Int {
        let value = UserDefaults.standard.integer(forKey: "HexMobileAutoStartSeconds")
        return value > 0 ? value : 6
    }
    #endif
}
