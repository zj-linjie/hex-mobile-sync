import SwiftUI

/// The app's tabs.
struct RootView: View {
    enum TabID: String, Hashable {
        case dictate, history, vocabulary, settings, transfers
    }

    @State private var selection: TabID = LaunchOptions.initialTab.flatMap(TabID.init(rawValue:)) ?? .dictate
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var services = services
        return TabView(selection: $selection) {
            Tab("Dictate", image: "hex.mark", value: TabID.dictate) {
                DictateView()
            }
            Tab("History", systemImage: "clock.arrow.circlepath", value: TabID.history) {
                HistoryView()
            }
            Tab("Vocabulary", systemImage: "character.book.closed", value: TabID.vocabulary) {
                VocabularyView()
            }
            Tab("Settings", systemImage: "slider.horizontal.3", value: TabID.settings) {
                SettingsView()
            }
            Tab("Transfers", systemImage: "tray.and.arrow.down", value: TabID.transfers) {
                TransfersView()
            }
        }
        .onChange(of: services.transfers.needsFolder) { _, needed in
            if needed { selection = .transfers }
        }
        .onChange(of: services.transfers.openedDocument) { _, opened in
            if opened { selection = .transfers; services.transfers.openedDocument = false }
        }
        // Outline symbols, as in Hex's sidebar.
        .environment(\.symbolVariants, .none)
        // The `dictate` route (microphone key of the keyboard): listening, go back.
        .fullScreenCover(isPresented: $services.keyboardDictationShown) {
            KeyboardDictationView()
        }
        #if DEBUG
        .overlay(alignment: .top) {
            if LaunchOptions.keyboardProbe {
                DebugKeyboardProbe().frame(height: 36).padding(.horizontal, 40).padding(.top, 60)
            }
        }
        #endif
    }
}
