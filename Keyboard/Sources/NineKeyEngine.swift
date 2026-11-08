import Foundation
@preconcurrency import LibrimeKit

/// One serialized Rime session in the keyboard process. The bundled schema
/// and dictionary are precompiled so the extension does not run deployment.
actor NineKeyEngine {
    static let shared = NineKeyEngine()
    struct Snapshot: Sendable {
        var input: String = ""
        /// The candidates of the current page.
        var candidates: [String] = []
        var committed: String = ""
        /// Zero-based page number and its size. The menu only knows whether
        /// the current page is the last (`isLastPage`), so the total page
        /// count is derived by the model.
        var pageNo: Int = 0
        var pageSize: Int = 5
        var isLastPage: Bool = true
        var error: String?
    }

    private let rime = Rime.shared
    private var ready = false
    private var failed = false
    private var owner: UUID?

    private func prepare() -> Bool {
        if ready { return true }
        if failed { return false }
        guard let shared = Bundle.main.url(forResource: "RimeData", withExtension: nil) else {
            failed = true
            return false
        }
        do {
            let base = try FileManager.default.url(for: .applicationSupportDirectory, in: .userDomainMask, appropriateFor: nil, create: true).appendingPathComponent("NineKeyRime-v2", isDirectory: true)
            let staging = base.appendingPathComponent("build", isDirectory: true)
            try FileManager.default.createDirectory(at: staging, withIntermediateDirectories: true)
            let traits = Rime.createTraits(sharedSupportDir: shared.path, userDataDir: base.path)
            traits.prebuiltDataDir = shared.appendingPathComponent("build").path
            traits.stagingDir = staging.path
            traits.minLogLevel = 2
            rime.start(traits, maintenance: false)
            rime.createSession()
            guard rime.setSchema("luna_pinyin_t9") else { failed = true; return false }
            _ = rime.asciiMode(false)
            _ = rime.setSimplifiedChineseMode(key: "zh_hans", value: true)
            ready = true
            return true
        } catch {
            failed = true
            return false
        }
    }

    private func snapshot() -> Snapshot {
        // The menu exists only while a composition is open.
        var pageNo = 0
        var pageSize = 5
        var isLastPage = true
        if let menu = rime.context().menu {
            pageNo = Int(menu.pageNo)
            if menu.pageSize > 0 { pageSize = Int(menu.pageSize) }
            isLastPage = menu.isLastPage
        }
        // `RimeCandidateListFromIndex` iterates the candidates of all pages
        // from a zero-based global index, so the bar shows the current page's
        // slice.
        let candidates = rime.candidateListWithIndex(index: pageNo * pageSize, andCount: pageSize).map(\.text)
        return Snapshot(input: rime.getInputKeys(), candidates: candidates, committed: rime.getCommitText(), pageNo: pageNo, pageSize: pageSize, isLastPage: isLastPage)
    }

    func key(_ value: String, owner: UUID) -> Snapshot {
        guard prepare() else { return Snapshot(error: "中文输入初始化失败，请切回英文") }
        if self.owner != owner { rime.cleanComposition(); self.owner = owner }
        _ = rime.inputKey(value)
        return snapshot()
    }

    func backspace(owner: UUID) -> Snapshot {
        guard ready, self.owner == owner else { return Snapshot() }
        _ = rime.inputKeyCode(0xff08)
        return snapshot()
    }

    func select(_ index: Int, owner: UUID) -> Snapshot {
        guard ready, self.owner == owner else { return Snapshot() }
        _ = rime.selectCandidateOnCurrentPage(index: index)
        return snapshot()
    }

    /// 重输: drops the composition, keeping what is already in the document.
    func retype(owner: UUID) -> Snapshot {
        guard ready, self.owner == owner else { return Snapshot() }
        rime.cleanComposition()
        return snapshot()
    }

    /// Candidate paging; `backward` is the ‹ direction.
    func page(backward: Bool, owner: UUID) -> Snapshot {
        guard ready, self.owner == owner else { return Snapshot() }
        _ = rime.changePage(backward: backward)
        return snapshot()
    }

    func clear() {
        if ready { rime.cleanComposition() }
    }
}
