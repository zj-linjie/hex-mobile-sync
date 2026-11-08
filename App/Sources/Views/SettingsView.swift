import HexMobileCore
import HexMobileSpeech
import SwiftUI
import UniformTypeIdentifiers

/// Sync folder, language, speech model, text rules, output, history, flow
/// session and setup guides.
struct SettingsView: View {
    @Environment(AppServices.self) private var services
    @Environment(SettingsStore.self) private var settings
    @Environment(SyncManager.self) private var sync
    @Environment(HistoryModel.self) private var history
    @Environment(SpeechAssetsModel.self) private var assets
    @Environment(DictationController.self) private var dictation

    @State private var isPickingFolder = false
    @State private var confirmForget = false
    @State private var keptClipCount = 0
    @State private var confirmDeleteClips = false

    var body: some View {
        @Bindable var settings = settings
        NavigationStack {
            Form {
                Group {
                    syncSection
                    languageSection
                    finalEngineSection
                    cleanupSection
                    textRulesSection
                    Section {
                        Toggle("Copy to Clipboard", isOn: $settings.copyToClipboard)
                        Toggle("Allow Universal Clipboard", isOn: $settings.allowUniversalClipboard)
                    } header: {
                        HexSectionHeader(title: "Output")
                    } footer: {
                        Text("Copies stay on this iPhone unless you allow Universal Clipboard, which also offers them to your other devices. With Copy to Clipboard off, a dictation started from the Hex Mobile keyboard is still placed on the clipboard so the keyboard can insert it; that copy stays on this iPhone and expires after two minutes.")
                    }
                    historySection
                    measureSection
                    flowSection
                    Section {
                        Toggle("Light Appearance", isOn: $settings.lightAppearance)
                    } header: {
                        HexSectionHeader(title: "Appearance", caption: "Dark by default")
                    }
                    Section {
                        NavigationLink { SetupGuideView(guide: .keyboard) } label: {
                            HexRow(symbol: "keyboard", title: "Keyboard")
                        }
                        NavigationLink { SetupGuideView(guide: .actionButton) } label: {
                            HexRow(symbol: "button.horizontal.top.press", title: "Action Button")
                        }
                        NavigationLink { SetupGuideView(guide: .controlCenter) } label: {
                            HexRow(symbol: "switch.2", title: "Control Center")
                        }
                        NavigationLink { SetupGuideView(guide: .sync) } label: {
                            HexRow(symbol: "arrow.triangle.2.circlepath", title: "Sync with Hex on Mac")
                        }
                    } header: {
                        HexSectionHeader(title: "Setup Guides")
                    }
                    aboutSection
                }
                .listRowBackground(HexPalette.card)
            }
            .hexListBackground()
            .navigationTitle("Settings")
            .toolbarTitleDisplayMode(.inlineLarge)
            .fileImporter(isPresented: $isPickingFolder, allowedContentTypes: [.folder]) { result in
                if case let .success(url) = result {
                    Task { await sync.setFolder(url) }
                }
            }
            .task(id: services.currentLocale) {
                await assets.refresh(for: services.currentLocale)
            }
        }
    }

    // MARK: - Sync

    private var syncSection: some View {
        Section {
            if let name = sync.folderName {
                LabeledContent("Folder", value: name)
                LabeledContent("Status") { syncStatus }
                if let bundle = sync.bundle {
                    LabeledContent("Terms", value: bundle.vocabulary.count, format: .number)
                    if let exportedAt = bundle.exportedAt {
                        LabeledContent("Exported by Mac") {
                            Text(exportedAt, format: .relative(presentation: .named))
                        }
                    }
                }
                if let warning = sync.warning {
                    Text(warning).font(.footnote).foregroundStyle(HexPalette.secondary)
                }
                Button("Sync Now", systemImage: "arrow.triangle.2.circlepath") {
                    Task { await sync.refresh(historyExport: settings.shareHistory ? history.jsonLinesExport() : nil) }
                }
                .disabled(sync.status == .syncing)
                Button("Change Folder…", systemImage: "folder") { isPickingFolder = true }
                Button("Forget Folder", systemImage: "xmark.circle", role: .destructive) { confirmForget = true }
                    .confirmationDialog("Forget the sync folder?", isPresented: $confirmForget, titleVisibility: .visible) {
                        Button("Forget Folder", role: .destructive) {
                            Task { await sync.forgetFolder() }
                        }
                    } message: {
                        Text("The shared history file is removed from the folder. Synced rules stay on this iPhone until you pick a folder again.")
                    }
            } else {
                Button("Choose Sync Folder…", systemImage: "folder.badge.plus") { isPickingFolder = true }
                if sync.bundle != nil {
                    Text("Using the last synced rules stored on this iPhone.")
                        .font(.footnote).foregroundStyle(HexPalette.secondary)
                }
            }
            if let notice = sync.vocabularyNotice {
                Text(VocabularyNoticeLabel.settings(notice))
                    .font(.footnote).foregroundStyle(HexPalette.secondary)
            }
        } header: {
            HexSectionHeader(title: "Sync with Hex", caption: "Through iCloud Drive")
        } footer: {
            Text("Pick the “\(SyncCodec.suggestedFolderName)” folder in iCloud Drive that the Mac script writes. Nothing else on your iPhone is shared.")
        }
    }

    @ViewBuilder private var syncStatus: some View {
        switch sync.status {
        case .notConfigured:
            Text("Not set up").foregroundStyle(HexPalette.secondary)
        case .never:
            Text("Not synced yet").foregroundStyle(HexPalette.secondary)
        case .syncing:
            ProgressView()
        case let .succeeded(date):
            Text(date, format: .relative(presentation: .named)).foregroundStyle(HexPalette.foreground)
        case let .failed(message):
            Text(message).foregroundStyle(.red).multilineTextAlignment(.trailing)
        }
    }

    // MARK: - Language and model

    private var languageSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("Language", selection: $settings.languageIdentifier) {
                Text(automaticLanguageLabel).tag(String?.none)
                ForEach(assets.availableLocales, id: \.identifier) { locale in
                    Text(SpeechModels.displayName(for: locale)).tag(Optional(locale.identifier(.bcp47)))
                }
            }
            .task { await assets.loadAvailableLocales() }

            LabeledContent("Speech Model") { modelStatus }
            if let kind = assets.moduleKind {
                LabeledContent("Recognizer", value: kind == .speechTranscriber
                               ? String(localized: "Speech (on-device)")
                               : String(localized: "Dictation (on-device)"))
            }
            if assets.isInstalling {
                ProgressView(value: assets.progress) {
                    Text("Downloading…")
                }
            } else if assets.state == .notInstalled || assets.state == .downloading {
                Button("Download Model", systemImage: "arrow.down.circle") {
                    Task { await assets.install(for: services.currentLocale) }
                }
            }
            if let error = assets.errorMessage {
                Text(error).font(.footnote).foregroundStyle(.red)
            }
        } header: {
            HexSectionHeader(title: "Recognition", caption: "On this iPhone")
        } footer: {
            Text("Transcription runs entirely on this iPhone. Your Hex vocabulary is used as a hint to the recognizer.")
        }
    }

    // MARK: - Final text engine

    private var finalEngineSection: some View {
        @Bindable var settings = settings
        let whisper = dictation.whisper
        return Section {
            Picker("Final Text Engine", selection: $settings.finalTextEngine) {
                Text("Apple").tag(FinalTextEngine.apple)
                Text("Whisper").tag(FinalTextEngine.whisper).disabled(!whisper.isInstalled)
            }
            if case let .missing(reason) = whisper.availability {
                Text(WhisperLabel.missing(reason))
                    .font(.footnote).foregroundStyle(HexPalette.secondary)
            }
            if let installation = whisper.availability.installation {
                LabeledContent("Whisper Model", value: installation.modelName)
                LabeledContent("Status", value: WhisperLabel.state(whisper.loadState))
                if whisper.loadState == .loading {
                    ProgressView()
                    if !whisper.isPrepared {
                        Text(WhisperLabel.compiling)
                            .font(.footnote).foregroundStyle(HexPalette.secondary)
                    }
                } else {
                    Button("Prepare Whisper", systemImage: "arrow.down.circle") {
                        Task { await dictation.prepareWhisper() }
                    }
                    if !whisper.isPrepared {
                        Text(WhisperLabel.neverPrepared)
                            .font(.footnote).foregroundStyle(HexPalette.secondary)
                    }
                }
            }
        } header: {
            HexSectionHeader(title: "Final Text", caption: "On this iPhone")
        } footer: {
            Text("After you stop, Apple reads the recording again for a more accurate text. With Whisper, the Whisper model then reads it too, in the time that is left, and its text replaces Apple's when it arrives in time and keeps at least half of the words. The app never downloads the model: copy it from your Mac (see the README). It stays in memory while a dictation session is open.")
        }
        .onAppear { whisper.refreshAvailability() }
        .onChange(of: settings.finalTextEngine) { _, _ in
            Task { await dictation.finalTextEngineChanged() }
        }
    }

    // MARK: - Text cleanup

    private var cleanupSection: some View {
        @Bindable var settings = settings
        let availability = TextCleaner.availability(for: services.currentLocale)
        return Section {
            Toggle("Fix the Text", isOn: $settings.cleanupEnabled)
            if settings.cleanupEnabled, case let .unavailable(reason) = availability {
                Text(CleanupLabel.unavailable(reason))
                    .font(.footnote).foregroundStyle(HexPalette.secondary)
            }
        } header: {
            HexSectionHeader(title: "Text Cleanup", caption: "On this iPhone")
        } footer: {
            Text("Adds punctuation and capitals, removes hesitations and applies spoken corrections (“no, anzi…”) with the language model on this iPhone. The text never leaves the device. If the model is not available or takes too long, you get the text as the recognizer heard it.")
        }
    }

    private var automaticLanguageLabel: String {
        if let synced = sync.bundle?.language, !synced.isEmpty, synced.lowercased() != "auto" {
            return String(localized: "Automatic (Hex: \(SpeechModels.displayName(for: Locale(identifier: synced))))")
        }
        return String(localized: "Automatic (\(SpeechModels.displayName(for: Locale.current)))")
    }

    @ViewBuilder private var modelStatus: some View {
        switch assets.state {
        case .none:
            ProgressView()
        case .installed:
            // Not a `Label`: as the value of a `LabeledContent` it stretched
            // the row to about 250 pt on iOS Simulator 27.2 (1 Nov 2026), with
            // the separator starting under the text instead of the row edge.
            HStack(spacing: 6) {
                Image(systemName: "checkmark.circle.fill").accessibilityHidden(true)
                Text("Installed")
            }
            .foregroundStyle(HexPalette.foreground)
        case .downloading:
            Text("Downloading").foregroundStyle(HexPalette.secondary)
        case .notInstalled:
            Text("Not installed").foregroundStyle(HexPalette.secondary)
        case .unsupportedLocale:
            Text("Not supported").foregroundStyle(.red)
        }
    }

    // MARK: - Text rules

    private var textRulesSection: some View {
        @Bindable var settings = settings
        let processor = sync.textProcessor(modeOverride: settings.modeOverride)
        return Section {
            Picker("Mode", selection: $settings.modeOverride) {
                Text("Default (\(sync.bundle?.defaultMode?.name ?? ProcessingMode.passthrough.name))").tag(String?.none)
                ForEach(sync.modeNames, id: \.self) { name in
                    Text(name).tag(Optional(name))
                }
            }
            .disabled(sync.modeNames.isEmpty)
            if sync.localCorrectionCount > 0 {
                LabeledContent("Personal context corrections", value: "\(sync.localCorrectionCount)")
            }
            if processor.mode.replacements.isEmpty && processor.mode.transformations.isEmpty && sync.localCorrectionCount == 0 {
                Text("No steps yet. Hex pastes your words as it heard them.")
                    .font(.subheadline)
                    .foregroundStyle(HexPalette.secondary)
            } else {
                HexRow(symbol: "list.number", title: "Replacements") {
                    Text(processor.mode.replacements.count, format: .number)
                }
                if !processor.mode.transformations.isEmpty {
                    HexRow(symbol: "sparkles", title: "Transformations",
                           subtitle: processor.mode.transformations.joined(separator: ", "))
                }
            }
            if !processor.unsupportedTransformations.isEmpty {
                Text("Skipped on iPhone: \(processor.unsupportedTransformations.joined(separator: ", ")). Only built-in transformations run here.")
                    .font(.footnote)
                    .foregroundStyle(HexPalette.secondary)
            }
        } header: {
            HexSectionHeader(title: "Every dictation", caption: "Runs top to bottom")
        } footer: {
            Text("Hex applies modes per app on the Mac. On iPhone the default mode is used unless you pick one here.")
        }
    }

    // MARK: - History

    private var historySection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("Keep History", selection: $settings.historyRetention) {
                ForEach(HistoryRetention.allCases, id: \.self) { retention in
                    Text(RetentionLabel.title(for: retention)).tag(retention)
                }
            }
            .onChange(of: settings.historyRetention) { _, retention in
                Task { await history.setRetention(retention) }
            }
            Toggle("Share History with Mac", isOn: $settings.shareHistory)
                .disabled(sync.folderURL == nil)
                .onChange(of: settings.shareHistory) { _, enabled in
                    if enabled {
                        guard let data = history.jsonLinesExport() else { return }
                        Task { await sync.exportHistory(data) }
                    } else {
                        Task { await sync.removeHistoryExport() }
                    }
                }
        } header: {
            HexSectionHeader(title: "History")
        } footer: {
            Text("History stays on this iPhone and is not included in iCloud or computer backups. When sharing is on, the final text of each dictation is also written to \(SyncCodec.historyExportFileName) in the sync folder; turning sharing off removes that file.")
        }
    }

    // MARK: - Measure recognition

    private var measureSection: some View {
        @Bindable var settings = settings
        return Section {
            Toggle("Keep Audio to Improve Recognition", isOn: $settings.keepAudioClips)
            if keptClipCount > 0 {
                LabeledContent("Kept Dictations", value: "\(keptClipCount)")
                Button("Delete Kept Audio", systemImage: "trash", role: .destructive) { confirmDeleteClips = true }
                    .confirmationDialog("Delete the kept audio?", isPresented: $confirmDeleteClips, titleVisibility: .visible) {
                        Button("Delete Kept Audio", role: .destructive) {
                            AppPaths.clipLibrary.deleteAll()
                            keptClipCount = AppPaths.clipLibrary.count
                        }
                    } message: {
                        Text("The audio and the texts of the kept dictations are deleted from this iPhone.")
                    }
            }
        } header: {
            HexSectionHeader(title: "Measure Recognition", caption: "Off by default")
        } footer: {
            Text("When on, the audio and the texts (as heard, fixed and inserted) of the last \(ClipLibrary.defaultLimit) dictations stay in this app so a Mac tool can compare recognizers on them. They are never synced, never part of the history export, and excluded from backups. Turning this off stops keeping new ones; the kept ones stay until you delete them.")
        }
        .task(id: settings.keepAudioClips) { keptClipCount = AppPaths.clipLibrary.count }
    }

    // MARK: - Flow session

    private var flowSection: some View {
        @Bindable var settings = settings
        return Section {
            Picker("End After Idle", selection: $settings.flowSessionDuration) {
                ForEach(FlowSessionDuration.allCases, id: \.self) { duration in
                    Text(FlowSessionLabel.title(for: duration)).tag(duration)
                }
            }
            .onChange(of: settings.flowSessionDuration) { _, _ in
                Task { await dictation.flowSessionDurationChanged() }
            }
            Button(dictation.isFlowSessionActive ? "End Flow Session" : "Start Flow Session",
                   systemImage: dictation.isFlowSessionActive ? "stop.circle" : "play.circle") {
                Task {
                    if dictation.isFlowSessionActive {
                        await dictation.endFlowSession()
                    } else {
                        await dictation.startFlowSession()
                    }
                }
            }
        } header: {
            HexSectionHeader(title: "Flow Session", caption: "For the keyboard")
        } footer: {
            VStack(alignment: .leading, spacing: 8) {
                Text("While a flow session is active the microphone stays ready in the background (iOS shows the microphone indicator) and the Hex Mobile keyboard can start dictation in any app. Audio is discarded until you dictate. With Bluetooth headphones, keeping the microphone open can switch them to the lower-quality headset mode until the session ends.")
                if settings.flowSessionDuration == .never {
                    Text("With Never, a session you start stays on until you end it, and the Dynamic Island says so. A session the Action Button starts still ends after its dictation.")
                }
            }
        }
    }

    // MARK: - About

    private var aboutSection: some View {
        Section {
            LabeledContent("Version", value: Bundle.main.object(forInfoDictionaryKey: "CFBundleShortVersionString") as? String ?? "–")
            Text("Hex Mobile is an unofficial companion for the Hex dictation app on macOS. It is not affiliated with Hex or its author.")
                .font(.footnote)
                .foregroundStyle(HexPalette.secondary)
        } header: {
            HexSectionHeader(title: "About")
        } footer: {
            Text("No network access, no analytics. Audio and text never leave this iPhone except the files you choose to write to the sync folder and copies you allow on Universal Clipboard.")
        }
    }
}

/// The picker's names for ``FlowSessionDuration``.
enum FlowSessionLabel {
    static func title(for duration: FlowSessionDuration) -> String {
        switch duration {
        case .minutes5, .minutes15: String(localized: "\(duration.rawValue) min")
        case .minutes60: String(localized: "1 hour")
        case .never: String(localized: "Never")
        }
    }
}

/// What Settings and the Dictate screen say about an empty vocabulary.
enum VocabularyNoticeLabel {
    /// Under the title of the Dictate screen.
    static func dictate(_ notice: VocabularyNotice) -> String {
        switch notice {
        case .noFolder: String(localized: "No vocabulary yet. Pick the Hex Mobile folder in Settings to give recognition your terms.")
        case .noTerms: String(localized: "No vocabulary terms to give recognition yet.")
        }
    }

    /// In the sync section of Settings.
    static func settings(_ notice: VocabularyNotice) -> String {
        switch notice {
        case .noFolder: String(localized: "No vocabulary yet: Apple's recognizer and Whisper get no hint for your names and terms until you pick the folder.")
        case .noTerms: String(localized: "No vocabulary terms yet: Apple's recognizer and Whisper get no hint for your names and terms. Sync again, or add a term in the Vocabulary tab.")
        }
    }
}

/// What Settings says about the Whisper model.
enum WhisperLabel {
    /// Never loaded on this iPhone (or not since the last iOS update): shown next to Prepare.
    static var neverPrepared: String {
        String(localized: "No record of Whisper loading on this iPhone yet, or iOS was updated since. The first load makes Core ML compile the model for the Neural Engine and took about 12 minutes on an iPhone 16 Pro. Tap Prepare Whisper and keep Hex Mobile open on screen until the status says Ready. Until then Apple's text is used.")
    }

    /// While the first load runs.
    static var compiling: String {
        String(localized: "Compiling the model for the Neural Engine: about 12 minutes the first time. Keep Hex Mobile open on screen until the status says Ready.")
    }

    static func missing(_ reason: WhisperMissing) -> String {
        switch reason {
        case .noFolder, .noModel:
            String(localized: "The Whisper model is not on this iPhone. Copy it from your Mac with make push-whisper-model (see the README).")
        case let .incompleteModel(name, missing):
            String(localized: "The model folder \(name) is incomplete: \(missing.joined(separator: ", ")) is missing.")
        case let .unsupportedModel(name):
            String(localized: "\(name) is not a large-v3 model. Only the large-v3 family is supported.")
        case let .noTokenizer(missing):
            String(localized: "The tokenizer files are missing (\(missing.joined(separator: ", "))). Without them the library would download them, which this app never does.")
        }
    }

    static func state(_ state: WhisperModel.LoadState) -> String {
        switch state {
        case .idle: String(localized: "Not loaded")
        case .loading: String(localized: "Loading…")
        case let .ready(seconds): seconds > 0
            ? String(localized: "Ready (loaded in \(String(format: "%.1f", seconds)) s)")
            : String(localized: "Ready")
        case let .failed(reason): String(localized: "Could not load: \(reason)")
        }
    }
}

/// Why the on-device language model cannot fix the text, for Settings.
enum CleanupLabel {
    static func unavailable(_ reason: String) -> String {
        switch reason {
        case "apple-intelligence-off": String(localized: "Turn on Apple Intelligence in Settings > Apple Intelligence & Siri to use this.")
        case "device-not-eligible": String(localized: "This iPhone does not support Apple Intelligence.")
        case "model-not-ready": String(localized: "The language model is still downloading. Try again later.")
        case "language-unsupported": String(localized: "The language model does not support the recognition language.")
        default: String(localized: "The language model is not available.")
        }
    }
}
