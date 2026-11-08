import SwiftUI

/// The Chinese nine-key layer, laid out like the system keyboard: a candidate
/// bar over a narrow punctuation column (，。？), the letter grid with @#,
/// a right column of ⌫, 重输 and 换行, and 符号 · 123 · 空格 · 中英 below.
/// The dictation bar on top stays the keyboard's own; this view fills the rest
/// of the keyboard (see `KeyboardView`).
/// The middle grid: each key shows letters and, when it is a letter key,
/// the digit it feeds Rime. `@#` opens the number layer instead. File scope
/// because the view is generic and Swift forbids static stored properties
/// there.
private let chineseGrid: [[(label: String, digit: String?)]] = [
    [("@#", nil), ("ABC", "2"), ("DEF", "3")],
    [("GHI", "4"), ("JKL", "5"), ("MNO", "6")],
    [("PQRS", "7"), ("TUV", "8"), ("WXYZ", "9")],
]
/// The narrow left column: one quick punctuation per row.
private let chinesePunctuation = ["，", "。", "？"]

struct ChineseNineKeyBody<Globe: View>: View {
    let model: KeyboardModel
    let globeKey: () -> Globe

    var body: some View {
        VStack(spacing: 4) {
            candidateBar
                .frame(height: 38)
            ForEach(0..<3, id: \.self) { row in
                HStack(spacing: 5) {
                    punctuationKey(chinesePunctuation[row])
                        .frame(width: 30)
                    ForEach(0..<3, id: \.self) { col in
                        gridKey(chineseGrid[row][col])
                    }
                    rightKey(row)
                        .frame(width: 46)
                }
                .frame(height: 43)
            }
            bottomRow
                .frame(height: 44)
        }
    }

    // MARK: Candidate bar

    /// Candidates fill the bar; the T9 digit preedit is deliberately not
    /// shown (digits say nothing a person can read). The left slot holds only
    /// the load state or an engine error; page controls sit on the right.
    private var candidateBar: some View {
        HStack(spacing: 10) {
            if model.chineseBusy {
                Text("…")
                    .font(.caption)
                    .foregroundStyle(HexPalette.secondary)
            } else if let error = model.chineseError {
                Text(error)
                    .font(.caption)
                    .foregroundStyle(HexPalette.secondary)
                    .lineLimit(1)
                    .minimumScaleFactor(0.7)
            }
            HStack(spacing: 0) {
                ForEach(Array(model.chineseCandidates.enumerated()), id: \.offset) { index, candidate in
                    Button(candidate) { model.selectChinese(index) }
                        .font(.system(size: 19))
                        .lineLimit(1)
                        .minimumScaleFactor(0.6)
                        .padding(.horizontal, 5)
                        .disabled(model.chineseBusy)
                        .frame(maxWidth: .infinity)
                }
            }
            .frame(maxWidth: .infinity)
            if showsPaging {
                pageControls
            }
        }
        .padding(.horizontal, 6)
        .foregroundStyle(HexPalette.foreground)
    }

    /// The page controls show whenever more than one page is reachable:
    /// before the last page, or once the user has paged away from the first.
    private var showsPaging: Bool {
        !model.chineseIsLastPage || model.chinesePageNo > 0
    }

    private var pageControls: some View {
        HStack(spacing: 8) {
            Button { model.pageTapped(backward: true) } label: {
                Image(systemName: "chevron.left")
                    .opacity(model.chinesePageNo == 0 ? 0.4 : 1)
            }
            .disabled(model.chinesePageNo == 0)
            Text("\(model.chinesePageNo + 1)/\(model.chinesePageCount)")
                .font(.caption2)
                .foregroundStyle(HexPalette.secondary)
            Button { model.pageTapped(backward: false) } label: {
                Image(systemName: "chevron.right")
                    .opacity(model.chineseIsLastPage ? 0.4 : 1)
            }
            .disabled(model.chineseIsLastPage)
        }
        .font(.caption)
        .foregroundStyle(HexPalette.foreground)
        .buttonStyle(PressableStyle())
        .disabled(model.chineseBusy)
    }

    // MARK: Keys

    private func punctuationKey(_ punctuation: String) -> some View {
        Button(punctuation) { model.punctuationTapped(punctuation) }
            .font(.system(size: 20))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyBackground(isAccent: false))
            .buttonStyle(PressableStyle())
            .accessibilityLabel(Text(punctuation))
            .accessibilityAddTraits(.isKeyboardKey)
    }

    private func gridKey(_ key: (label: String, digit: String?)) -> some View {
        Button(key.label) {
            if let digit = key.digit {
                model.chineseKey(digit)
            } else {
                model.layerTapped(.numbers)
            }
        }
        .font(.system(size: 17))
        .frame(maxWidth: .infinity, maxHeight: .infinity)
        .background(KeyBackground(isAccent: false))
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(key.label))
        .accessibilityAddTraits(.isKeyboardKey)
    }

    /// The right column: ⌫ (hold to repeat, through the shared delete loop,
    /// which deletes composition or text as appropriate), 重输, 换行.
    @ViewBuilder private func rightKey(_ row: Int) -> some View {
        switch row {
        case 0: NineKeyDeleteKey(model: model)
        case 1: NineKeyLabelKey(title: "重输") { model.retypeTapped() }
        default: NineKeyLabelKey(title: "换行") { model.returnTapped() }
        }
    }

    private var bottomRow: some View {
        HStack(spacing: 5) {
            NineKeyLabelKey(title: "符号") { model.layerTapped(.symbols) }
                .frame(width: 56)
            NineKeyLabelKey(title: "123") { model.layerTapped(.numbers) }
                .frame(width: 56)
            if model.needsGlobeKey {
                globeKey()
                    .frame(width: 40)
                    .background(KeyBackground(isAccent: false))
            }
            NineKeyLabelKey(title: "空格") { model.spaceTapped() }
            ModeToggleKey(model: model)
                .frame(width: 72)
        }
    }
}

/// A delete key with hold-to-repeat, sharing the model's accelerating delete
/// loop with the letters layer (composition first, then document text).
private struct NineKeyDeleteKey: View {
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
                        model.startDeleting()
                    }
                    .onEnded { _ in
                        isPressed = false
                        model.stopDeleting()
                    }
            )
            .accessibilityElement()
            .accessibilityLabel(Text("删除"))
            .accessibilityAddTraits(.isButton)
            .accessibilityAction { model.deleteTapped() }
    }
}

/// A plain function key of the Chinese layer (重输, 换行, 符号, 123, 空格).
struct NineKeyLabelKey: View {
    let title: String
    let action: () -> Void

    var body: some View {
        Button(action: action) {
            Text(title)
                .font(.callout.weight(.medium))
                .minimumScaleFactor(0.7)
                .lineLimit(1)
                .frame(maxWidth: .infinity, maxHeight: .infinity)
                .background(KeyBackground(isAccent: false))
                .foregroundStyle(HexPalette.foreground)
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text(title))
    }
}

/// The 中/英 mode key both layers share: the active mode reads as foreground,
/// the other as secondary, like the system keyboard's composite key.
struct ModeToggleKey: View {
    let model: KeyboardModel

    var body: some View {
        Button {
            model.layerTapped(model.layer == .chinese ? .letters : .chinese)
        } label: {
            HStack(spacing: 4) {
                Text("中")
                    .foregroundStyle(model.layer == .chinese ? HexPalette.foreground : HexPalette.secondary)
                Text("英")
                    .foregroundStyle(model.layer == .letters ? HexPalette.foreground : HexPalette.secondary)
            }
            .font(.callout.weight(.medium))
            .frame(maxWidth: .infinity, maxHeight: .infinity)
            .background(KeyBackground(isAccent: false))
        }
        .buttonStyle(PressableStyle())
        .accessibilityLabel(Text("切换中文或英文"))
    }
}
