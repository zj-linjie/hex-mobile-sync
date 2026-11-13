import HexMobileCore
import Observation
import SwiftUI
import UIKit
import UniformTypeIdentifiers

@MainActor
final class ShareViewController: UIViewController {
    private let model = ShareModel()

    override func viewDidLoad() {
        super.viewDidLoad()
        view.tintColor = .systemBlue
        let host = UIHostingController(rootView: ShareView(model: model))
        host.view.tintColor = .systemBlue
        addChild(host)
        host.view.translatesAutoresizingMaskIntoConstraints = false
        view.addSubview(host.view)
        NSLayoutConstraint.activate([
            host.view.leadingAnchor.constraint(equalTo: view.leadingAnchor),
            host.view.trailingAnchor.constraint(equalTo: view.trailingAnchor),
            host.view.topAnchor.constraint(equalTo: view.topAnchor),
            host.view.bottomAnchor.constraint(equalTo: view.bottomAnchor)
        ])
        host.didMove(toParent: self)
        model.finish = { [weak self] in self?.extensionContext?.completeRequest(returningItems: nil) }
        let providers = (extensionContext?.inputItems as? [NSExtensionItem] ?? []).flatMap { $0.attachments ?? [] }
        Task { await model.load(providers) }
    }

    override func viewDidDisappear(_ animated: Bool) {
        super.viewDidDisappear(animated)
        if isBeingDismissed || navigationController?.isBeingDismissed == true { model.cancel() }
    }
}

@MainActor
@Observable
private final class ShareModel {
    var title = ""
    var note = ""
    var errorMessage: String?
    var isBusy = true
    var pickingFolder = false
    var folderName: String?
    var attachmentCount = 0
    var byteCount: Int64 = 0
    var finish: (() -> Void)?
    private var draft: TransferDraft?
    private var folder: URL?
    private var pendingStatus: TransferManifest.Status?
    private var cancelled = false
    private var saving = false
    private let bookmarkKey = "share.syncFolderBookmark"

    init() {
        if let bookmark = UserDefaults.standard.data(forKey: bookmarkKey) {
            var stale = false
            folder = try? URL(resolvingBookmarkData: bookmark, options: [], relativeTo: nil, bookmarkDataIsStale: &stale)
            if stale, let folder { try? remember(folder) }
            folderName = folder?.lastPathComponent
        }
    }

    func load(_ providers: [NSItemProvider]) async {
        do {
            let loaded = try await ShareLoader.load(providers)
            guard !cancelled else { loaded.discard(); return }
            draft = loaded
            title = loaded.suggestedTitle
            attachmentCount = loaded.attachments.count
            byteCount = loaded.attachments.reduce(0) { $0 + $1.bytes }
        } catch { errorMessage = safeMessage(error) }
        isBusy = false
    }

    func submit(_ status: TransferManifest.Status) async {
        guard !isBusy, draft != nil else { return }
        pendingStatus = status
        guard folder != nil else { pickingFolder = true; return }
        await save()
    }

    func picked(_ result: Result<URL, any Error>) async {
        switch result {
        case let .success(url):
            do {
                try remember(url)
                folder = url
                folderName = url.lastPathComponent
                if pendingStatus != nil { await save() }
            }
            catch { errorMessage = String(localized: "The sync folder could not be saved. Choose the folder again.") }
        case .failure:
            // The picker was cancelled. No cloud write has occurred.
            pendingStatus = nil
        }
    }

    private func remember(_ url: URL) throws {
        let access = url.startAccessingSecurityScopedResource()
        defer { if access { url.stopAccessingSecurityScopedResource() } }
        let bookmark = try url.bookmarkData(options: [], includingResourceValuesForKeys: nil, relativeTo: nil)
        UserDefaults.standard.set(bookmark, forKey: bookmarkKey)
    }

    private func save() async {
        guard let draft, let folder, let pendingStatus, !cancelled else { return }
        isBusy = true
        saving = true
        defer { isBusy = false; saving = false }
        do {
            let cleanTitle = title.components(separatedBy: .newlines).joined(separator: " ").trimmingCharacters(in: .whitespacesAndNewlines)
            try await TransferFiles.save(draft, title: cleanTitle, note: String(note.prefix(200)), status: pendingStatus, in: folder)
            draft.discard()
            self.draft = nil
            finish?()
        } catch {
            errorMessage = String(localized: "The transfer could not be saved. Check the sync folder and try again.")
        }
    }

    func cancel() {
        guard !saving else { return }
        cancelled = true
        draft?.discard()
        draft = nil
        finish?()
    }

    private func safeMessage(_ error: any Error) -> String {
        (error as? TransferImportError)?.errorDescription ?? String(localized: "The shared item could not be read. Download it in the source app and try again.")
    }
}

private struct ShareView: View {
    @Bindable var model: ShareModel

    var body: some View {
        NavigationStack {
            Form {
                Section {
                    if model.isBusy { ProgressView() }
                    else if model.attachmentCount > 0 {
                        Label("\(model.attachmentCount) attachments", systemImage: "tray.and.arrow.down")
                        Text(ByteCountFormatter.string(fromByteCount: model.byteCount, countStyle: .file))
                            .foregroundStyle(.secondary)
                    }
                    TextField("Title", text: $model.title, axis: .horizontal).lineLimit(1)
                        .onChange(of: model.title) { _, value in
                            model.title = value.components(separatedBy: .newlines).joined(separator: " ")
                        }
                    TextField("Note (optional, up to 200 characters)", text: $model.note, axis: .vertical)
                        .lineLimit(2...4)
                        .onChange(of: model.note) { _, value in model.note = String(value.prefix(200)) }
                }
                if let message = model.errorMessage {
                    Section { Text(message).foregroundStyle(.red) }
                }
                Section {
                    Button("Sync to Mac") { Task { await model.submit(.queued) } }
                        .buttonStyle(.borderedProminent)
                    Button("Save for later") { Task { await model.submit(.held) } }
                }
                .disabled(model.isBusy || model.attachmentCount == 0 || model.title.trimmingCharacters(in: .whitespacesAndNewlines).isEmpty)
                Section {
                    Button("Choose Sync Folder") { model.pickingFolder = true }
                    if let folderName = model.folderName {
                        Label(folderName, systemImage: "folder").foregroundStyle(.secondary)
                    }
                    Text("Held items are already in your iCloud folder. Your Mac receives them only after you sync.")
                        .font(.footnote).foregroundStyle(.secondary)
                }
                .disabled(model.isBusy)
            }
            .navigationTitle("Transfer")
            .tint(Color(uiColor: .systemBlue))
            .toolbar {
                ToolbarItem(placement: .cancellationAction) { Button("Cancel") { model.cancel() }.disabled(model.isBusy && model.attachmentCount > 0) }
            }
            .fileImporter(isPresented: $model.pickingFolder, allowedContentTypes: [.folder]) { result in
                Task { await model.picked(result) }
            }
        }
    }
}
