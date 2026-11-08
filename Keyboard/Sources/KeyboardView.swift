import SwiftUI

/// Full keyboard in Hex style: a dictation bar on top (status, voice blob
/// mic key, insert), then an Italian QWERTY layout with numbers and
/// symbols. Long-press a vowel for the accented letter.
struct KeyboardView<Globe: View>: View {
    static var preferredHeight: CGFloat { 300 }

    let model: KeyboardModel
    let globeKey: () -> Globe

    var body: some View {
        VStack(spacing: 7) {
            Group {
                if let message = model.failure {
                    // The app could not start or finish a dictation: the reason,
                    // Close, and Retry (the microphone key's action again).
                    FailureBar(model: model, message: message)
                } else {
                    HStack(spacing: 8) {
                        if model.state == .recording {
                            CancelKey(model: model)
                                .frame(width: 44, height: 44)
                        } else {
                            InsertKey(model: model)
                                .frame(width: 44, height: 44)
                        }
                        hintBanner
                            .frame(maxWidth: .infinity)
                        MicKey(model: model)
                            .frame(width: 112, height: 50)
                    }
                }
            }
            .frame(height: 52)
            if model.showRecentPicker {
                RecentPickerPanel(model: model)
            } else if model.layer == .chinese {
                ChineseNineKeyBody(model: model, globeKey: globeKey)
            } else {
                ForEach(Array(rows.enumerated()), id: \.offset) { index, row in
                    HStack(spacing: 5) {
                        if index == 2 { leadingThirdRowKey }
                        ForEach(row, id: \.self) { key in
                            LetterKey(key: key, model: model)
                        }
                        if index == 2 {
                            DeleteKey(model: model)
                                .frame(width: 46)
                        }
                    }
                    .padding(.horizontal, index == 1 && model.layer == .letters ? 16 : 0)
                    .frame(height: 46)
                }
                sharedBottomRow
                    .frame(height: 46)
            }
        }
        .padding(.horizontal, 4)
        .padding(.vertical, 6)
        .frame(height: Self.preferredHeight)
        .background(HexPalette.background)
        .sensoryFeedback(.impact(weight: .light), trigger: model.state)
    }

    private var rows: [[String]] {
        switch model.layer {
        case .letters:
            [["q", "w", "e", "r", "t", "y", "u", "i", "o", "p"],
             ["a", "s", "d", "f", "g", "h", "j", "k", "l"],
             ["z", "x", "c", "v", "b", "n", "m"]]
        case .numbers:
            [["1", "2", "3", "4", "5", "6", "7", "8", "9", "0"],
             ["-", "/", ":", ";", "(", ")", "€", "&", "@", "\""],
             [".", ",", "?", "!", "'"]]
        case .symbols:
            [["[", "]", "{", "}", "#", "%", "^", "*", "+", "="],
             ["_", "\\", "|", "~", "<", ">", "$", "£", "•"],
             [".", ",", "?", "!", "'"]]
        case .chinese: []
        }
    }

    /// The letters/numbers/symbols bottom row: layer switch, 中/英, globe,
    /// space, return. The Chinese layer draws its own (ChineseNineKeyBody).
    private var sharedBottomRow: some View {
        HStack(spacing: 5) {
            LayerKey(title: model.layer == .numbers || model.layer == .symbols ? "ABC" : "123") {
                model.layerTapped(model.layer == .numbers || model.layer == .symbols ? .letters : .numbers)
            }
            .frame(width: 50)
            ModeToggleKey(model: model)
                .frame(width: 45)
            if model.needsGlobeKey {
                globeKey()
                    .frame(width: 44)
                    .background(KeyBackground(isAccent: false))
            }
            SpaceKey(model: model)
            ReturnKey(model: model)
                .frame(width: 88)
        }
    }

    @ViewBuilder private var leadingThirdRowKey: some View {
        switch model.layer {
        case .letters:
            ShiftKey(model: model).frame(width: 46)
        case .numbers:
            LayerKey(title: "#+=") { model.layerTapped(.symbols) }.frame(width: 46)
        case .symbols:
            LayerKey(title: "123") { model.layerTapped(.numbers) }.frame(width: 46)
        case .chinese: EmptyView()
        }
    }

    @ViewBuilder private var hintBanner: some View {
        Group {
            if model.state == .recording, !model.liveText.isEmpty {
                // Live words, newest at the end, like Hex's transcript.
                Text(String(model.liveText.suffix(90)))
                    .font(.footnote)
                    .foregroundStyle(HexPalette.foreground)
                    .lineLimit(2)
                    .truncationMode(.head)
                    .frame(maxWidth: .infinity, alignment: .trailing)
                    .animation(.easeOut(duration: 0.2), value: model.liveText)
            } else if let text = hintText {
                Text(text)
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
                    .font(.caption)
                    .foregroundStyle(HexPalette.secondary)
            } else {
                Text(statusText)
                    .hexCaption()
                    .lineLimit(2)
                    .minimumScaleFactor(0.7)
            }
        }
        .multilineTextAlignment(.center)
    }

    private var hintText: LocalizedStringKey? {
        switch model.hint {
        case .startSession: "Open Hex Mobile and start a flow session, then come back."
        case .needsFullAccess: "Turn on Allow Full Access for Hex Mobile in Settings > Keyboards."
        case .nothingToInsert: "No dictation on the clipboard yet."
        case .resultReady: "A dictation is ready. Tap the insert key to add it."
        case nil: nil
        }
    }

    private var statusText: LocalizedStringKey {
        switch model.state {
        case .checking: "Connecting to Hex Mobile…"
        case .unavailable: "Tap the mic to start a flow session"
        case .idle: "Tap to dictate · hold to talk"
        case .recording: "Listening… ✓ to insert, ✕ to cancel"
        case .processing: "Transcribing…"
        }
    }
}

/// A letter, number or symbol key. Long-press a vowel for its accent.
private struct LetterKey: View {
    let key: String
    let model: KeyboardModel
    @State private var isPressed = false
    @State private var showAccent = false

    private static let accents: [String: String] = [
        "a": "à", "e": "è", "i": "ì", "o": "ò", "u": "ù", "E": "É",
    ]

    var body: some View {
        let label = (model.layer == .letters && model.shift != .off) ? key.uppercased() : key
        Text(showAccent ? (Self.accents[key].map { model.shift != .off ? $0.uppercased() : $0 } ?? label) : label)
            .font(.system(size: 22))
            .foregroundStyle(HexPalette.foreground)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyBackground(isAccent: false, isPressed: isPressed))
            .overlay(alignment: .top) {
                if isPressed {
                    Text(showAccent ? (Self.accents[key] ?? label) : label)
                        .font(.system(size: 30, weight: .medium))
                        .foregroundStyle(HexPalette.foreground)
                        .frame(width: 48, height: 50)
                        .background(RoundedRectangle(cornerRadius: 10).fill(HexPalette.surface))
                        .overlay(RoundedRectangle(cornerRadius: 10).strokeBorder(HexPalette.separator))
                        .offset(y: -56)
                        .allowsHitTesting(false)
                }
            }
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        if !isPressed {
                            isPressed = true
                            KeyFeedback.tap()
                            if Self.accents[key] != nil {
                                Task {
                                    try? await Task.sleep(for: .milliseconds(420))
                                    if isPressed { showAccent = true }
                                }
                            }
                        }
                    }
                    .onEnded { _ in
                        if showAccent, let accent = Self.accents[key] {
                            model.typed(accent)
                        } else {
                            model.typed(key)
                        }
                        isPressed = false
                        showAccent = false
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text(label))
            .accessibilityAddTraits(.isKeyboardKey)
            .accessibilityAction { model.typed(key) }
    }
}

private struct ShiftKey: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.shiftTapped) {
            Image(systemName: model.shift == .locked ? "capslock.fill" : (model.shift == .once ? "shift.fill" : "shift"))
                .font(.title3)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeyBackground(isAccent: model.shift != .off))
                .foregroundStyle(model.shift != .off ? HexPalette.onForeground : HexPalette.foreground)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text("Shift"))
    }
}

private struct LayerKey: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeyBackground(isAccent: false))
                .foregroundStyle(HexPalette.foreground)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Shared key background: dark gray key on the black keyboard.
struct KeyBackground: View {
    let isAccent: Bool
    var isPressed = false

    var body: some View {
        RoundedRectangle(cornerRadius: 10, style: .continuous)
            .fill(isAccent ? HexPalette.foreground : (isPressed ? HexPalette.separator : HexPalette.surface))
            .overlay(
                RoundedRectangle(cornerRadius: 10, style: .continuous)
                    .strokeBorder(HexPalette.separator, lineWidth: 1)
            )
    }
}

/// The dictation key: the voice blob in a pill. Tap starts a locked
/// dictation (tap again to stop); hold to talk and release to stop.
private struct MicKey: View {
    let model: KeyboardModel
    @State private var pressStart: Date?
    @State private var holdTask: Task<Void, Never>?
    @State private var holding = false

    var body: some View {
        ZStack {
            Capsule()
                .fill(model.state == .recording ? HexPalette.foreground.opacity(0.12) : HexPalette.surface)
                .overlay(Capsule().strokeBorder(model.state == .recording ? HexPalette.foreground.opacity(0.6) : HexPalette.separator, lineWidth: 1))
            HStack(spacing: 6) {
                ParticleBlob(state: markState, level: model.state == .recording ? model.level : 0, count: 220)
                    .frame(width: 40, height: 40)
                if model.state == .recording { RecordingDot(size: 6) }
                Image(systemName: model.state == .recording ? "checkmark" : "mic.fill")
                    .font(.system(size: 15, weight: .semibold))
                    .foregroundStyle(HexPalette.foreground)
            }
        }
        .opacity(model.state == .processing || model.state == .checking ? 0.6 : 1)
        .contentShape(Capsule())
        .gesture(
            DragGesture(minimumDistance: 0)
                .onChanged { _ in
                    guard pressStart == nil else { return }
                    pressStart = Date()
                    // Haptic only: the click would be cut off by the audio
                    // session this key is about to start.
                    KeyFeedback.tap(click: false)
                    holdTask = Task {
                        try? await Task.sleep(for: .milliseconds(320))
                        guard !Task.isCancelled else { return }
                        if model.state == .idle {
                            holding = true
                            model.micHoldBegan()
                        }
                    }
                }
                .onEnded { _ in
                    holdTask?.cancel()
                    if holding {
                        holding = false
                        model.micHoldEnded()
                    } else {
                        model.micTapped()
                    }
                    pressStart = nil
                }
        )
        .accessibilityElement()
        .accessibilityLabel(Text(model.state == .recording ? "Finish dictation" : "Dictate"))
        .accessibilityAddTraits(.isButton)
        .accessibilityAction { model.state == .recording ? model.finishTapped() : model.micTapped() }
    }

    private var markState: HexMarkState {
        switch model.state {
        case .recording: .recording
        case .processing: .processing
        case .checking, .unavailable, .idle: .idle
        }
    }
}

/// The reason a dictation did not start or failed, with Close and Retry.
private struct FailureBar: View {
    let model: KeyboardModel
    let message: String

    var body: some View {
        HStack(spacing: 8) {
            Button(action: model.closeFailureTapped) {
                Image(systemName: "xmark")
                    .font(.title3.weight(.semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(KeyBackground(isAccent: false))
                    .foregroundStyle(HexPalette.foreground)
            }
            .buttonStyle(PressableStyle())
            .frame(width: 44, height: 44)
            .accessibilityLabel(Text("Close"))
            HStack(spacing: 6) {
                Image(systemName: "exclamationmark.triangle.fill")
                    .foregroundStyle(.orange)
                    .accessibilityHidden(true)
                Text(message)
                    .font(.caption)
                    .foregroundStyle(HexPalette.foreground)
                    .lineLimit(3)
                    .minimumScaleFactor(0.7)
            }
            .frame(maxWidth: .infinity, alignment: .leading)
            .accessibilityElement(children: .combine)
            Button(action: model.retryTapped) {
                Label("Retry", systemImage: "arrow.clockwise")
                    .font(.system(size: 15, weight: .semibold))
                    .frame(maxWidth: .infinity, maxHeight: .infinity)
                    .background(Capsule().fill(HexPalette.surface))
                    .overlay(Capsule().strokeBorder(HexPalette.foreground.opacity(0.6), lineWidth: 1))
                    .foregroundStyle(HexPalette.foreground)
            }
            .buttonStyle(PressableStyle())
            .frame(width: 112, height: 50)
        }
    }
}

/// ✕ while recording: drops the dictation, nothing is inserted.
private struct CancelKey: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.cancelTapped) {
            Image(systemName: "xmark")
                .font(.title3.weight(.semibold))
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeyBackground(isAccent: false))
                .foregroundStyle(HexPalette.foreground)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text("Cancel dictation"))
    }
}

/// The insert key: a tap inserts the latest dictation, a hold (about half a
/// second) opens the recent-dictation picker.
private struct InsertKey: View {
    let model: KeyboardModel
    @State private var isPressed = false
    @State private var longPressFired = false
    @State private var holdTask: Task<Void, Never>?
    private static let holdDuration: Duration = .milliseconds(450)

    var body: some View {
        Image(systemName: "text.insert")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyBackground(isAccent: false, isPressed: isPressed))
            .foregroundStyle(model.hasDictationOnPasteboard ? HexPalette.foreground : HexPalette.secondary)
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        longPressFired = false
                        holdTask = Task {
                            try? await Task.sleep(for: Self.holdDuration)
                            guard !Task.isCancelled else { return }
                            longPressFired = true
                            KeyFeedback.tap()
                            model.insertLongPressed()
                        }
                    }
                    .onEnded { _ in
                        holdTask?.cancel()
                        if !longPressFired {
                            model.insertTapped()
                        }
                        isPressed = false
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Insert last dictation"))
            .accessibilityAddTraits(.isButton)
            .accessibilityHint(Text("Hold for recent dictations"))
            .accessibilityAction { model.insertTapped() }
    }
}

/// The recent-dictation picker the insert key's hold opens: one row per
/// dictation, newest first; tapping a row inserts it (repeats allowed).
/// The rows come from the app over loopback, served only in the window this
/// picker's opening asked for; without Full Access (or an unreachable app)
/// the pasteboard payload is the only row.
private struct RecentPickerPanel: View {
    let model: KeyboardModel

    var body: some View {
        VStack(spacing: 6) {
            HStack(spacing: 8) {
                Text("最近听写")
                    .font(.callout.weight(.medium))
                    .foregroundStyle(HexPalette.foreground)
                Spacer()
                Button {
                    model.closeRecentPicker()
                } label: {
                    Image(systemName: "xmark")
                        .font(.callout.weight(.semibold))
                        .frame(width: 34, height: 30)
                        .background(KeyBackground(isAccent: false))
                        .foregroundStyle(HexPalette.foreground)
                }
                .buttonStyle(PressableStyle())
                .accessibilityLabel(Text("关闭"))
            }
            .frame(height: 32)
            if model.recentLoading {
                Spacer()
                Text("读取中…")
                    .font(.caption)
                    .foregroundStyle(HexPalette.secondary)
                Spacer()
            } else if model.recentPayloads.isEmpty {
                Spacer()
                Text("暂无听写记录")
                    .font(.caption)
                    .foregroundStyle(HexPalette.secondary)
                Spacer()
            } else {
                ScrollView(.vertical, showsIndicators: false) {
                    VStack(spacing: 5) {
                        ForEach(model.recentPayloads) { payload in
                            Button {
                                model.recentPicked(payload)
                            } label: {
                                HStack(spacing: 8) {
                                    Text(payload.text)
                                        .font(.subheadline)
                                        .lineLimit(1)
                                        .truncationMode(.tail)
                                        .foregroundStyle(HexPalette.foreground)
                                    Spacer(minLength: 8)
                                    Text(Self.time(payload.createdAt))
                                        .font(.caption2)
                                        .foregroundStyle(HexPalette.secondary)
                                }
                                .padding(.horizontal, 10)
                                .frame(maxWidth: .infinity, minHeight: 36)
                                .background(KeyBackground(isAccent: false))
                            }
                            .buttonStyle(PressableStyle())
                            .accessibilityLabel(Text("插入：\(payload.text)"))
                        }
                    }
                }
            }
        }
    }

    /// `HH:MM` of when the dictation finished, in the current calendar.
    private static func time(_ date: Date) -> String {
        let formatter = DateFormatter()
        formatter.dateFormat = "HH:mm"
        return formatter.string(from: date)
    }
}

private struct DeleteKey: View {
    let model: KeyboardModel
    @State private var isPressed = false

    var body: some View {
        Image(systemName: isPressed ? "delete.left.fill" : "delete.left")
            .font(.title3)
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyBackground(isAccent: false, isPressed: isPressed))
            .contentShape(.rect)
            .gesture(
                DragGesture(minimumDistance: 0)
                    .onChanged { _ in
                        guard !isPressed else { return }
                        isPressed = true
                        KeyFeedback.tap()
                        model.startDeleting()
                    }
                    .onEnded { _ in
                        isPressed = false
                        model.stopDeleting()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("Delete"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.deleteTapped() }
    }
}

private struct ReturnKey: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.returnTapped) {
            Text(title)
                .font(.callout.weight(.medium))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeyBackground(isAccent: false))
                .foregroundStyle(HexPalette.foreground)
        }
        .buttonStyle(PressableStyle())
    }

    private var title: LocalizedStringKey {
        switch model.returnKeyTitle {
        case .return: "return"
        case .go: "go"
        case .search: "search"
        case .send: "send"
        case .done: "done"
        case .next: "next"
        }
    }
}

private struct SpaceKey: View {
    let model: KeyboardModel

    var body: some View {
        Button(action: model.spaceTapped) {
            Text("space")
                .font(.callout)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeyBackground(isAccent: false))
                .foregroundStyle(HexPalette.foreground)
        }
        .buttonStyle(PressableStyle())
    }
}

/// Pressed keys brighten and shrink. The haptic and click are not here:
/// an observer on the style's pressed state did not prove reliable, so
/// `KeyFeedback.tap()` fires from the key actions instead.
struct PressableStyle: ButtonStyle {
    func makeBody(configuration: Configuration) -> some View {
        configuration.label
            .scaleEffect(configuration.isPressed ? 0.97 : 1)
            .brightness(configuration.isPressed ? 0.12 : 0)
            .animation(.easeOut(duration: 0.08), value: configuration.isPressed)
    }
}
