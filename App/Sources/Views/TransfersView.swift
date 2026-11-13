import SwiftUI
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
                        }
                    }
                    .listRowBackground(HexPalette.card)
                    .swipeActions {
                        Button("Delete", systemImage: "trash", role: .destructive) { Task { await model.delete(row) } }
                    }
                    .contextMenu {
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
    private func status(_ row: TransfersModel.Row) -> String {
        switch row.status {
        case .held: String(localized: "Not yet synced")
        case .queued: String(localized: "Waiting for Mac")
        case .delivered: String(localized: "Delivered to Mac")
        }
    }
}
