import Foundation
import HexMobileCore
import Observation
import UIKit

/// Closures into the input view controller (text proxy, deep link).
struct KeyboardActions {
    var insertText: @MainActor (String) -> Void = { _ in }
    var deleteBackward: @MainActor () -> Void = {}
    /// Moves the cursor `chars` positions, positive to the right: the text
    /// proxy's relative move, the only cursor API a keyboard extension has.
    var moveCursor: @MainActor (Int) -> Void = { _ in }
    var openHostApp: @MainActor (URL) -> Bool = { _ in false }
    var hasFullAccess: @MainActor () -> Bool = { false }
}

/// Keyboard state, driven by Darwin notifications from the app.
@MainActor
@Observable
final class KeyboardModel {
    init() {
        KeyboardDiagnostics.modelCreated()
    }

    nonisolated deinit {
        KeyboardDiagnostics.modelDeallocated()
    }

    /// What the app's flow session is doing, as far as the keyboard knows.
    enum SessionState: Equatable {
        /// Waiting for an answer to `ping`.
        case checking
        /// No flow session answered.
        case unavailable
        case idle
        case recording
        case processing
    }

    enum ReturnTitle {
        case `return`, go, search, send, done, next
    }

    enum Hint: Equatable {
        case startSession
        case needsFullAccess
        case nothingToInsert
        /// A dictation finished that this keyboard did not stop (Live
        /// Activity, Action Button, another keyboard): insert only on tap.
        case resultReady
    }

    private(set) var state: SessionState = .checking {
        didSet {
            guard state != oldValue else { return }
            if state == .recording { startLivePolling() } else { stopLivePolling() }
            // Under an active recording session iOS mutes system sounds; a
            // click here would only sound chopped. Haptic-only until the
            // dictation is over (see KeyFeedback.clicksMuted).
            KeyFeedback.clicksMuted = state == .recording || state == .processing
        }
    }
    /// Why the app could not start or finish a dictation, shown on top of the
    /// keyboard with Close and Retry; `nil` when there is nothing to show.
    private(set) var failure: String?
    @ObservationIgnored private var failureTask: Task<Void, Never>?
    /// What the app is hearing, while recording (from the loopback channel).
    private(set) var liveText = ""
    /// The microphone level 0...1 the app reports while recording (the same
    /// loopback poll as ``liveText``); 0 otherwise. The microphone key draws it.
    private(set) var level: Float = 0
    @ObservationIgnored private var liveTask: Task<Void, Never>?

    private func startLivePolling() {
        liveTask?.cancel()
        liveText = ""
        liveTask = Task { @MainActor [weak self] in
            // Memory while recording, every 10 s (see `KeyboardDiagnostics`).
            let began = Date()
            var nextMemoryLog = 0
            while !Task.isCancelled {
                let live = await LoopbackClient.live()
                // A model that is gone ends the loop: it used to go on asking
                // the app every 150 ms for nobody.
                guard let self else { return }
                if self.state == .recording {
                    if let live {
                        if self.liveText != live.text { self.liveText = live.text }
                        self.level = live.level
                    } else if self.level != 0 {
                        // The app did not answer: the last level must not stay on.
                        self.level = 0
                    }
                }
                let elapsed = Int(Date().timeIntervalSince(began))
                if elapsed >= nextMemoryLog {
                    KeyboardDiagnostics.record("keyboard recording t=\(elapsed)s \(KeyboardDiagnostics.memorySummary)")
                    nextMemoryLog = (elapsed / 10 + 1) * 10
                }
                try? await Task.sleep(for: .milliseconds(150))
            }
        }
    }

    private func stopLivePolling() {
        liveTask?.cancel()
        liveTask = nil
        liveText = ""
        level = 0
    }
    var hint: Hint?
    /// Whether the keyboard draws its own globe key. Starts `false` because
    /// the value is read after the view appeared (see
    /// `KeyboardViewController.viewWillAppear`): iPhones with Face ID get the
    /// system globe and never need ours, so `true` would show a globe that
    /// vanishes a moment later. On a Home-button iPhone the globe appears
    /// right after the keyboard does.
    var needsGlobeKey = false

    // MARK: Typing state

    enum Layer { case letters, numbers, symbols, chinese }
    enum ShiftState { case off, once, locked }
    var layer: Layer = .letters
    var chineseInput = ""
    var chineseCandidates: [String] = []
    var chineseError: String?
    var chineseBusy = false
    /// Zero-based page number, its size, and the derived total page count.
    var chinesePageNo = 0
    var chinesePageCount = 1
    @ObservationIgnored var chinesePageSize = 5
    @ObservationIgnored var chineseIsLastPage = true
    @ObservationIgnored private var chinesePending = 0
    @ObservationIgnored private let chineseEngine = NineKeyEngine.shared
    @ObservationIgnored private let chineseOwner = UUID()
    @ObservationIgnored private var chineseTask: Task<Void, Never>?

    /// Serialized engine work. `postCommit` runs after the snapshot is applied
    /// and the committed text inserted, still inside the same task, so an
    /// insertion ordered after a commit (a punctuation tap) cannot overtake it.
    private func enqueueChinese(_ work: @escaping @Sendable (NineKeyEngine) async -> NineKeyEngine.Snapshot, postCommit: @escaping @MainActor () -> Void = {}) {
        let previous = chineseTask
        chinesePending += 1
        chineseBusy = true
        chineseTask = Task { @MainActor [weak self, chineseEngine] in
            await previous?.value
            guard let self, !self.isShutDown, !Task.isCancelled else { return }
            let result = await work(chineseEngine)
            guard !self.isShutDown, !Task.isCancelled else { return }
            self.chineseInput = result.input
            self.chineseCandidates = result.candidates
            self.chineseError = result.error
            self.chinesePageNo = result.pageNo
            self.chinesePageSize = result.pageSize
            self.chineseIsLastPage = result.isLastPage
            // The total page count is only known at the last page; before
            // that, one more page is always reachable.
            self.chinesePageCount = result.isLastPage ? result.pageNo + 1 : result.pageNo + 2
            if !result.committed.isEmpty { self.actions.insertText(result.committed) }
            postCommit()
            self.chinesePending -= 1
            self.chineseBusy = self.chinesePending > 0
        }
    }

    func chineseKey(_ digit: String) {
        KeyFeedback.tap()
        let owner = chineseOwner
        enqueueChinese { await $0.key(digit, owner: owner) }
    }
    func selectChinese(_ index: Int) {
        guard !chineseBusy else { return }
        let owner = chineseOwner
        enqueueChinese { await $0.select(index, owner: owner) }
    }
    func chineseBackspace() { let owner = chineseOwner; enqueueChinese { await $0.backspace(owner: owner) } }

    /// 重输: clears the composition, keeping the document untouched.
    func retypeTapped() {
        guard !chineseBusy, !chineseInput.isEmpty else { return }
        KeyFeedback.tap()
        let owner = chineseOwner
        enqueueChinese { await $0.retype(owner: owner) }
    }

    /// Candidate paging; only meaningful while a composition is open.
    func pageTapped(backward: Bool) {
        guard !chineseBusy, !chineseInput.isEmpty else { return }
        KeyFeedback.tap()
        let owner = chineseOwner
        enqueueChinese { await $0.page(backward: backward, owner: owner) }
    }

    /// A quick punctuation key (，。？): straight into the text when idle;
    /// while composing, the first candidate commits before it, so the
    /// punctuation lands after the words, as on the system keyboard.
    func punctuationTapped(_ punctuation: String) {
        guard !chineseBusy else { return }
        KeyFeedback.tap()
        guard !chineseInput.isEmpty else { actions.insertText(punctuation); return }
        let owner = chineseOwner
        enqueueChinese({ await $0.select(0, owner: owner) }, postCommit: { [weak self] in
            guard let self, !self.isShutDown else { return }
            self.actions.insertText(punctuation)
        })
    }
    var shift: ShiftState = .once
    /// The space key is held past its hold: the keyboard dims and slides
    /// move the cursor (see `spaceTrackpad…`). Never while a Chinese
    /// composition is open — the space key commits candidates then.
    private(set) var cursorTrackpad = false
    @ObservationIgnored private var lastShiftTap = Date.distantPast
    @ObservationIgnored var documentContextBeforeInput: () -> String? = { nil }
    /// Pasteboard change count when the current recording started: the
    /// plain-text fallback inserts only text written after it.
    @ObservationIgnored private var changeCountAtRecording: Int?
    /// Push-to-talk: the mic key is being held.
    @ObservationIgnored private var isHolding = false
    var returnKeyTitle: ReturnTitle = .return
    /// Whether the pasteboard holds a dictation from the app (checked
    /// without reading the content, so iOS shows no paste prompt).
    private(set) var hasDictationOnPasteboard = false

    @ObservationIgnored var actions = KeyboardActions()
    /// Set by ``shutdown()``: the controller is gone and `actions` are empty
    /// closures that insert nothing. A task that was waiting on the loopback and
    /// wakes up after that must not mark a dictation as inserted.
    @ObservationIgnored private var isShutDown = false
    @ObservationIgnored private var pingTimeout: Task<Void, Never>?
    @ObservationIgnored private var deleteTask: Task<Void, Never>?
    /// Fallback when the app does not answer a toggle with a state signal.
    @ObservationIgnored private var toggleReplyTimeout: Task<Void, Never>?
    /// When this keyboard asked the app to stop a recording; a `done` is
    /// inserted automatically only after such a request.
    @ObservationIgnored private var stopRequestedAt: Date?
    /// This keyboard opened the app on the `dictate` route and has not heard
    /// from it yet: a ping that goes unanswered then means the app did not
    /// come up, and the keyboard says how to start by hand.
    @ObservationIgnored private var awaitingAppStart = false
    /// How long the app has to answer `ping` or `toggle`.
    private static let replyTimeout: Duration = .milliseconds(700)
    @ObservationIgnored private let defaults = UserDefaults.standard
    private static let insertedIDKey = "keyboard.insertedDictationIDs"

    /// Ids already inserted (last 50): a dictation never goes in twice,
    /// whichever route (loopback or pasteboard) delivers it.
    private func wasInserted(_ id: UUID) -> Bool {
        (defaults.stringArray(forKey: Self.insertedIDKey) ?? []).contains(id.uuidString)
    }

    private func markInserted(_ id: UUID) {
        var ids = defaults.stringArray(forKey: Self.insertedIDKey) ?? []
        ids.append(id.uuidString)
        defaults.set(Array(ids.suffix(50)), forKey: Self.insertedIDKey)
    }

    // MARK: - Lifecycle

    func appear() {
        KeyboardDiagnostics.record("appear fullAccess=\(actions.hasFullAccess()) pid=\(getpid()) \(KeyboardDiagnostics.memorySummary)")
        // The signals go to the keyboard that appeared last (`KeyboardSignals`).
        KeyboardSignals.attach(self)
        ping()
        refreshPasteboardFlag()
        // A dictation stopped while this keyboard was hidden (Action Button
        // from another screen): insert it if the app still holds it. Only
        // loopback here, never the pasteboard, which may hold an older copy.
        pullThenInsert(pasteboardFallback: false)
        if !actions.hasFullAccess() { hint = .needsFullAccess }
    }

    // MARK: - Failures

    /// The app said a start or a dictation failed (`startFailed`, also in
    /// answer to `ping` when this keyboard was hidden at the time): reads the
    /// reason over loopback and shows it. Without Full Access, or when the app
    /// cannot be reached, the message says only that the dictation did not
    /// start. A recording or transcription that has begun since wins: the
    /// message is stale.
    private func showFailure() {
        KeyboardDiagnostics.record("keyboard error signal state=\(state)")
        failureTask?.cancel()
        failureTask = Task { @MainActor [weak self] in
            guard let self else { return }
            var reason: String?
            if self.actions.hasFullAccess() {
                // The app opens its loopback listener as it sets the reason, and
                // the signal can arrive before the listener is ready (seen on the
                // simulator, 1 Nov 2026: the first read got no answer).
                for attempt in 0..<4 where reason == nil {
                    if attempt > 0 { try? await Task.sleep(for: .milliseconds(250)) }
                    guard !Task.isCancelled else { return }
                    reason = await LoopbackClient.error()
                }
            }
            guard !Task.isCancelled, self.state != .recording, self.state != .processing else { return }
            let message = (reason?.isEmpty == false ? reason : nil) ?? String(localized: "Dictation could not start.")
            self.failure = message
            KeyboardDiagnostics.record("keyboard error shown chars=\(message.count) fromApp=\(reason?.isEmpty == false) state=\(self.state)")
        }
    }

    private func clearFailure() {
        failureTask?.cancel()
        failureTask = nil
        failure = nil
    }

    /// Close: drops the message here and tells the app it was seen (the app
    /// keeps the reason for a minute for a keyboard that shows late; `cancel`
    /// with nothing to cancel clears it).
    func closeFailureTapped() {
        KeyboardDiagnostics.record("keyboard error closed state=\(state)")
        clearFailure()
        DarwinNotificationCenter.shared.post(.cancel)
    }

    /// Retry: the microphone key's action again, a moment later so that a
    /// dictation that was still stopping has finished (the app answers a start
    /// during that with its own message). With a session it asks the app to
    /// toggle, without one it opens the app on the `dictate` route.
    func retryTapped() {
        KeyboardDiagnostics.record("keyboard error retry state=\(state)")
        clearFailure()
        Task { @MainActor [weak self] in
            try? await Task.sleep(for: .milliseconds(300))
            self?.micTapped()
        }
    }

    func disappear() {
        KeyboardDiagnostics.record("disappear pid=\(getpid()) \(KeyboardDiagnostics.memorySummary)")
        stopWork()
    }

    /// The keyboard's controller is going away (it may never have sent
    /// `disappear`): stops everything this model started and lets go of the
    /// controller's closures. Nothing in the model depends on this call to be
    /// released; it only stops the work sooner.
    func shutdown() {
        isShutDown = true
        chineseTask?.cancel()
        stopWork()
        actions = KeyboardActions()
        documentContextBeforeInput = { nil }
    }

    private func stopWork() {
        KeyboardSignals.detach(self)
        clearFailure()
        stopLivePolling()
        pingTimeout?.cancel()
        toggleReplyTimeout?.cancel()
        stopDeleting()
        cursorTrackpad = false
    }

    func handle(_ signal: HexMobileIPC.Signal) {
        KeyboardDiagnostics.record("signal \(signal)")
        switch signal {
        case .pong:
            pingTimeout?.cancel()
            toggleReplyTimeout?.cancel()
            awaitingAppStart = false
            if state == .checking || state == .unavailable { state = .idle }
            if hint == .startSession { hint = nil }
        case .done:
            clearFailure()
            refreshPasteboardFlag()
            pullThenInsert()
        case .startFailed:
            showFailure()
        case .sessionEnded:
            // The app has no flow session (it ended, or never started).
            pingTimeout?.cancel()
            toggleReplyTimeout?.cancel()
            stopRequestedAt = nil
            state = .unavailable
        default:
            if let flowState = HexMobileIPC.FlowState(signal: signal) {
                pingTimeout?.cancel()
                toggleReplyTimeout?.cancel()
                awaitingAppStart = false
                if hint == .startSession { hint = nil }
                switch flowState {
                case .idle: state = .idle
                case .recording:
                    if state != .recording { changeCountAtRecording = UIPasteboard.general.changeCount }
                    state = .recording
                    clearFailure()
                case .processing:
                    state = .processing
                    clearFailure()
                }
            }
        }
    }

    /// Asks the app whether a flow session is alive. Without an answer the
    /// keyboard falls back to `.unavailable`, also from recording or
    /// processing (the app may have been terminated mid-dictation).
    func ping() {
        if state != .recording && state != .processing { state = .checking }
        DarwinNotificationCenter.shared.post(.ping)
        pingTimeout?.cancel()
        pingTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            // Any answer cancels this task.
            guard !Task.isCancelled, let self else { return }
            self.stopRequestedAt = nil
            self.state = .unavailable
            if self.awaitingAppStart {
                self.awaitingAppStart = false
                KeyboardDiagnostics.record("keyboard app did not answer after dictate route")
                self.hint = .startSession
            }
        }
    }

    /// Sends `toggle` and, when no state signal follows, checks with `ping`
    /// whether the app is still there.
    private func sendToggle() {
        if state == .recording { stopRequestedAt = Date() }
        DarwinNotificationCenter.shared.post(.toggle)
        armReplyTimeout()
    }

    /// When no state signal answers a `toggle` or `cancel` within
    /// ``replyTimeout``, asks with `ping` whether the app is still there.
    private func armReplyTimeout() {
        toggleReplyTimeout?.cancel()
        toggleReplyTimeout = Task { [weak self] in
            try? await Task.sleep(for: Self.replyTimeout)
            guard !Task.isCancelled, let self else { return }
            self.ping()
        }
    }

    // MARK: - Keys

    func micTapped() {
        guard state == .recording || (chineseInput.isEmpty && !chineseBusy) else { return }
        KeyboardDiagnostics.record("keyboard mic tap state=\(state)")
        switch state {
        case .idle, .recording:
            sendToggle()
        case .processing:
            break
        case .checking, .unavailable:
            startThroughApp()
        }
    }

    /// No flow session: opens the app on the `dictate` route, which starts the
    /// session and the dictation in the foreground (the audio can only start
    /// there). The user then comes back through the system's own way back; when
    /// the keyboard shows again, `appear()` pings and finds the recording.
    private func startThroughApp() {
        let url = HexMobileIPC.Route.dictate.url(source: "keyboard")
        let opened = actions.openHostApp(url)
        KeyboardDiagnostics.record("keyboard dictate opened=\(opened) state=\(state)")
        guard opened else {
            // iOS gave no way to open the app: explain how to start by hand.
            hint = .startSession
            return
        }
        hint = nil
        awaitingAppStart = true
        // The keyboard is usually suspended while the app is in front; this
        // runs when it was not (the app did not open, or came up in under 2 s).
        Task { [weak self] in
            try? await Task.sleep(for: .seconds(2))
            self?.ping()
        }
    }

    func insertTapped() {
        KeyFeedback.tap()
        insertLatestDictation(automatic: false)
    }

    /// ✓ while recording: stop, transcribe, insert. The same as a tap on the
    /// microphone key; `stopRequestedAt` makes the `done` that follows insert
    /// the text on its own.
    func finishTapped() {
        guard state == .recording else { return }
        KeyboardDiagnostics.record("keyboard finish state=\(state)")
        sendToggle()
    }

    /// ✕ while recording: drop the dictation. The app answers with the idle
    /// state and posts no `done`, so nothing is inserted; the keyboard forgets
    /// the stop request and the pasteboard mark, so the plain-text fallback of
    /// `insertLatestDictation` cannot pick up anything from this dictation.
    func cancelTapped() {
        guard state == .recording else { return }
        KeyFeedback.tap()
        KeyboardDiagnostics.record("keyboard cancel state=\(state)")
        stopRequestedAt = nil
        changeCountAtRecording = nil
        isHolding = false
        DarwinNotificationCenter.shared.post(.cancel)
        armReplyTimeout()
    }

    func spaceTapped() {
        if layer == .chinese && chineseBusy { return }
        KeyFeedback.tap()
        if layer == .chinese && !chineseInput.isEmpty { selectChinese(0); return }
        // Double space: ". " like the system keyboard.
        if let before = documentContextBeforeInput(), before.hasSuffix(" "),
           let last = before.dropLast().last, last.isLetter || last.isNumber {
            actions.deleteBackward()
            actions.insertText(". ")
            shift = .once
            return
        }
        actions.insertText(" ")
        // The Chinese layer stays put: a space between汉字 must not kick the
        // user back to the letters layer. Numbers and symbols return to
        // letters, like the system keyboard.
        if layer != .letters && layer != .chinese { layer = .letters }
        autoCapitalize()
    }

    // MARK: Space trackpad

    /// The space key's hold elapsed: engage the cursor trackpad (the
    /// keyboard dims) unless a Chinese composition is open, when the space
    /// key keeps its commit job. Returns whether it engaged; a refused
    /// gesture falls back to the space action on release.
    func spaceTrackpadEngaged() -> Bool {
        guard chineseInput.isEmpty, !chineseBusy else { return false }
        KeyFeedback.tap(click: false)
        cursorTrackpad = true
        return true
    }

    /// One slide step of the engaged trackpad: `chars` whole positions,
    /// positive to the right.
    func spaceTrackpadMoved(_ chars: Int) {
        guard cursorTrackpad, chars != 0 else { return }
        actions.moveCursor(chars)
    }

    /// The space key's finger lifted with the trackpad engaged: the cursor
    /// stays where the slide left it.
    func spaceTrackpadEnded() {
        cursorTrackpad = false
    }

    func returnTapped() {
        if layer == .chinese && chineseBusy { return }
        KeyFeedback.tap()
        if layer == .chinese && !chineseInput.isEmpty { selectChinese(0); return }
        actions.insertText("\n")
        shift = .once
    }

    func typed(_ key: String) {
        let text = (layer == .letters && shift != .off) ? key.uppercased() : key
        actions.insertText(text)
        if shift == .once { shift = .off }
        if layer == .symbols || (layer == .numbers && key == "'") { layer = .letters }
    }

    func shiftTapped() {
        let now = Date()
        if now.timeIntervalSince(lastShiftTap) < 0.3 {
            shift = .locked
        } else {
            shift = shift == .off ? .once : .off
        }
        lastShiftTap = now
        KeyFeedback.tap()
    }

    func layerTapped(_ target: Layer) {
        guard chineseInput.isEmpty && !chineseBusy else { return }
        layer = target
        KeyFeedback.tap()
    }

    /// Capitalizes after sentence ends, like the system keyboard.
    func autoCapitalize() {
        guard shift != .locked else { return }
        let before = documentContextBeforeInput() ?? ""
        let trimmed = before.trimmingCharacters(in: .whitespaces)
        if trimmed.isEmpty || [".", "!", "?", "\n"].contains(where: { trimmed.hasSuffix($0) }) && before.hasSuffix(" ") || before.hasSuffix("\n") {
            shift = .once
        } else if shift == .once {
            shift = .off
        }
    }

    // MARK: Push-to-talk and locked dictation

    /// Mic key held: start recording; releasing stops it.
    func micHoldBegan() {
        guard chineseInput.isEmpty && !chineseBusy else { return }
        guard state == .idle else { return }
        isHolding = true
        sendToggle()
    }

    func micHoldEnded() {
        guard isHolding else { return }
        isHolding = false
        if state == .recording || state == .idle { stopRequestedAt = Date(); DarwinNotificationCenter.shared.post(.toggle) }
    }

    func deleteTapped() {
        if layer == .chinese && chineseBusy { return }
        if layer == .chinese && !chineseInput.isEmpty { chineseBackspace() } else { actions.deleteBackward() }
    }

    /// Hold to delete repeatedly, accelerating after a short delay.
    func startDeleting() {
        stopDeleting()
        deleteTapped()
        deleteTask = Task { [weak self] in
            try? await Task.sleep(for: .milliseconds(450))
            var interval = 110
            var count = 0
            while !Task.isCancelled {
                self?.deleteTapped()
                count += 1
                if count == 12 { interval = 50 }
                try? await Task.sleep(for: .milliseconds(interval))
            }
        }
    }

    func stopDeleting() {
        deleteTask?.cancel()
        deleteTask = nil
    }

    // MARK: - Pasteboard

    /// Pulls the result from the app over loopback (works when the app
    /// finished in the background); falls back to the pasteboard.
    func pullThenInsert(pasteboardFallback: Bool = true) {
        guard actions.hasFullAccess() else {
            if pasteboardFallback { insertLatestDictation(automatic: true) }
            return
        }
        Task { @MainActor [weak self] in
            let payload = await LoopbackClient.pull()
            guard let self else { return }
            if let payload {
                KeyboardDiagnostics.record("loopback got payload")
                insert(payload, automatic: true)
            } else {
                KeyboardDiagnostics.record("loopback: nothing")
                if pasteboardFallback { insertLatestDictation(automatic: true) }
            }
        }
    }

    /// Inserts `payload` once per id.
    private func insert(_ payload: DictationPayload, automatic: Bool) {
        // After `shutdown()` the actions insert nothing: marking the id would
        // lose the dictation for the keyboard that is shown next.
        guard !isShutDown else {
            KeyboardDiagnostics.record("insert dropped: keyboard shut down")
            return
        }
        if automatic, !payload.isFresh() { return }
        // A manual insert may repeat; only the automatic paths dedupe.
        if automatic, wasInserted(payload.id) { return }
        let text = payload.insertableText
        guard !text.isEmpty else { return }
        KeyboardDiagnostics.record("inserted \(text.count) chars")
        actions.insertText(text)
        // Marked once the text went in (the call is synchronous on the main
        // actor, so nothing can insert it a second time in between).
        markInserted(payload.id)
        hint = nil
    }

    // MARK: - Recent dictations (long press on the insert key)

    /// The recent-dictation picker is open (it replaces the key area).
    var showRecentPicker = false
    /// The app is being asked for the recent list.
    var recentLoading = false
    /// The payloads the picker offers, newest first.
    var recentPayloads: [DictationPayload] = []

    /// The insert key was held: open the picker and ask the app for the
    /// recent dictations. The keyboard first posts `recent`, so the app
    /// opens its loopback listener for a few seconds; without an answer the
    /// pasteboard payload (if any) is the only row offered.
    func insertLongPressed() {
        KeyboardDiagnostics.record("insert long press")
        showRecentPicker = true
        recentLoading = true
        recentPayloads = []
        DarwinNotificationCenter.shared.post(.recent)
        Task { @MainActor [weak self] in
            // A moment for the app to open its listener before we connect.
            try? await Task.sleep(for: .milliseconds(150))
            guard let self, !self.isShutDown else { return }
            var payloads = await LoopbackClient.recent()
            if payloads.isEmpty, let single = self.pasteboardPayload() { payloads = [single] }
            guard !self.isShutDown else { return }
            self.recentPayloads = payloads
            self.recentLoading = false
        }
    }

    func closeRecentPicker() {
        showRecentPicker = false
        recentLoading = false
        recentPayloads = []
    }

    /// A row of the picker was tapped: insert it. Manual insertions may
    /// repeat — only the automatic paths dedupe by id.
    func recentPicked(_ payload: DictationPayload) {
        closeRecentPicker()
        insertManual(payload)
    }

    /// Inserts `payload` straight in, whatever was inserted before.
    private func insertManual(_ payload: DictationPayload) {
        guard !isShutDown else { return }
        let text = payload.insertableText
        guard !text.isEmpty else {
            hint = .nothingToInsert
            return
        }
        KeyboardDiagnostics.record("inserted recent \(text.count) chars")
        actions.insertText(text)
        // Still marked, so the automatic paths do not insert it again.
        markInserted(payload.id)
        hint = nil
    }

    /// The dictation payload on the pasteboard, if any (without reading the
    /// plain text, so iOS shows no paste prompt for other items).
    private func pasteboardPayload() -> DictationPayload? {
        let pasteboard = UIPasteboard.general
        guard pasteboard.contains(pasteboardTypes: [HexMobileIPC.pasteboardType]),
              let data = pasteboard.data(forPasteboardType: HexMobileIPC.pasteboardType) else {
            return nil
        }
        return try? DictationPayload.decode(from: data)
    }

    private func refreshPasteboardFlag() {
        hasDictationOnPasteboard = UIPasteboard.general.contains(pasteboardTypes: [HexMobileIPC.pasteboardType])
    }

    /// Inserts the dictation on the pasteboard once per id. Automatic
    /// insertion (after `done`) also requires a fresh payload and a stop
    /// requested from this keyboard; otherwise it only offers the result.
    private func insertLatestDictation(automatic: Bool) {
        guard !isShutDown else {
            KeyboardDiagnostics.record("insert dropped: keyboard shut down")
            return
        }
        let requestedHere = stopRequestedAt.map {
            Date().timeIntervalSince($0) < DictationPayload.defaultMaxAge
        } ?? false
        if automatic { stopRequestedAt = nil }
        guard actions.hasFullAccess() else {
            KeyboardDiagnostics.record("insert blocked: no full access")
            hint = .needsFullAccess
            return
        }
        let pasteboard = UIPasteboard.general
        KeyboardDiagnostics.record("insert automatic=\(automatic) hasType=\(pasteboard.contains(pasteboardTypes: [HexMobileIPC.pasteboardType]))")
        guard pasteboard.contains(pasteboardTypes: [HexMobileIPC.pasteboardType]),
              let data = pasteboard.data(forPasteboardType: HexMobileIPC.pasteboardType),
              let payload = try? DictationPayload.decode(from: data)
        else {
            KeyboardDiagnostics.record("insert: no payload; types=\(pasteboard.types.count) change=\(pasteboard.changeCount) since=\(changeCountAtRecording.map(String.init) ?? "-")")
            // Fallback: the custom type did not reach this process, but the
            // app wrote plain text after the recording started.
            if automatic, let start = changeCountAtRecording, pasteboard.changeCount != start,
               pasteboard.hasStrings, let text = pasteboard.string, !text.isEmpty {
                changeCountAtRecording = nil
                KeyboardDiagnostics.record("inserted plain \(text.count) chars")
                actions.insertText(text)
                hint = nil
                return
            }
            if !automatic { hint = .nothingToInsert }
            return
        }
        if automatic, !payload.isFresh(maxAge: 15) { KeyboardDiagnostics.record("insert: payload stale"); return }
        // A manual insert may repeat; only the automatic paths dedupe.
        if automatic, wasInserted(payload.id) { return }
        // A fresh result inserts itself wherever the cursor is, also when the
        // dictation was stopped from the Action Button or the Live Activity:
        // that is the point of the keyboard (like Hex pasting on the Mac).
        _ = requestedHere
        let text = payload.insertableText
        guard !text.isEmpty else {
            if !automatic { hint = .nothingToInsert }
            return
        }
        KeyboardDiagnostics.record("inserted \(text.count) chars")
        actions.insertText(text)
        // Marked once the text went in (the call is synchronous on the main
        // actor, so nothing can insert it a second time in between).
        markInserted(payload.id)
        hint = nil
    }
}
