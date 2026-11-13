import SwiftUI
import UIKit
import UniformTypeIdentifiers

struct TransfersView: View {
    @Environment(AppServices.self) private var services

    var body: some View {
        @Bindable var model = services.transfers
        NavigationStack {
            List {
                ForEach(model.rows) { row in
                    HStack(alignment: .top, spacing: 12) {
                        Image(systemName: row.count > 1 ? "square.stack" : symbol(row))
                            .accessibilityLabel(kind(row))
                        VStack(alignment: .leading, spacing: 6) {
                            Text(row.title).lineLimit(2)
                            HStack {
                                Text(row.createdAt, format: .dateTime.month().day().hour().minute())
                                Spacer()
                                Text(status(row))
                            }
                            .font(.caption)
                            .foregroundStyle(HexPalette.secondary)
                            if row.count > 1 {
                                Text("\(row.count) attachments").font(.caption).foregroundStyle(HexPalette.secondary)
                            }
                            if row.status == .held {
                                Button("Sync to Mac") { Task { await model.queue(row) } }
                                    .buttonStyle(.borderless)
                            }
                            if row.status != .delivered {
                                Button("Share") { Task { await model.share(row) } }
                                    .buttonStyle(.borderless)
                            }
                        }
                    }
                    .listRowBackground(HexPalette.card)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(row) } }
                    }
                    .contextMenu {
                        if row.status != .delivered {
                            Button("Share", systemImage: "square.and.arrow.up") { Task { await model.share(row) } }
                        }
                        if row.status == .held {
                            Button("Sync to Mac", systemImage: "arrow.up") { Task { await model.queue(row) } }
                        }
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(row) } }
                    }
                    .disabled(model.isBusy)
                }
            }
            .hexListBackground()
            .listStyle(.insetGrouped)
            .overlay {
                if model.rows.isEmpty {
                    ContentUnavailableView("No Transfers", systemImage: "tray.and.arrow.down", description:
                        Text("Share text, images, or files to Hex Mobile. Saved items wait here until you sync them to your Mac."))
                }
            }
            .navigationTitle("Transfers")
            .toolbarTitleDisplayMode(.inlineLarge)
            .background {
                if let item = model.shareItem {
                    TransferSharePresenter(items: item.items) { model.cleanupShare() }
                        .id(item.id)
                }
            }
            .refreshable { await model.refresh() }
            .task { await model.refresh() }
            .fileImporter(isPresented: $model.needsFolder, allowedContentTypes: [.folder]) { result in
                switch result {
                case let .success(url): Task { await model.pickedFolder(url) }
                case .failure: model.cancelIncoming()
                }
            }
            .alert("Transfers", isPresented: Binding(get: { model.errorMessage != nil }, set: { if !$0 { model.errorMessage = nil } })) {
                Button("OK", role: .cancel) { model.errorMessage = nil }
            } message: { Text(model.errorMessage ?? "") }
        }
    }

    private func symbol(_ row: TransfersModel.Row) -> String {
        switch row.kind { case .text: "text.alignleft"; case .image: "photo"; case .file: "doc" }
    }
    private func kind(_ row: TransfersModel.Row) -> String {
        if row.count > 1 { return String(localized: "Multiple attachments") }
        switch row.kind { case .text: return String(localized: "Text"); case .image: return String(localized: "Image"); case .file: return String(localized: "File") }
    }
    /// Presents the system share sheet once this host is in a window. A SwiftUI
    /// sheet would wrap a second sheet around it.
    private struct TransferSharePresenter: UIViewControllerRepresentable {
        let items: [Any]
        let onFinish: () -> Void

        func makeUIViewController(context: Context) -> Host { Host() }

        func updateUIViewController(_ controller: Host, context: Context) {
            controller.items = items
            controller.onFinish = onFinish
            controller.presentIfReady()
        }

        final class Host: UIViewController {
            var items: [Any] = []
            var onFinish: () -> Void = {}
            private var started = false

            override func viewDidAppear(_ animated: Bool) {
                super.viewDidAppear(animated)
                view.backgroundColor = .clear
                presentIfReady()
            }

            func presentIfReady() {
                guard !started, !items.isEmpty, view.window != nil, presentedViewController == nil else { return }
                started = true
                let activity = UIActivityViewController(activityItems: items, applicationActivities: nil)
                activity.completionWithItemsHandler = { _, _, _, _ in
                    Task { @MainActor in self.onFinish() }
                }
                present(activity, animated: true)
            }
        }
    }

    private func status(_ row: TransfersModel.Row) -> String {
        switch row.status {
        case .held: String(localized: "Not yet synced")
        case .queued: String(localized: "Waiting for Mac")
        case .delivered: String(localized: "Delivered to Mac")
        }
    }
}
