import AppKit
import Foundation

struct PendingAction: Identifiable {
    let id = UUID()
    let title: String
    let message: String
    let confirm: String
    let run: @MainActor () async -> Void
}

@MainActor
final class AppModel: ObservableObject {
    @Published var disk = DiskInfo.current()

    @Published var storage: [StorageItem] = StorageCatalog.items
    @Published var storageScanning = false

    @Published var repos: [Repo] = []
    @Published var worktreeScanning = false
    @Published var worktreeProgress = ""
    @Published var worktreesScannedAt: Date?

    @Published var bigFolders: [FolderNode] = []
    @Published var bigScanning = false

    @Published var busy: Set<String> = []
    @Published var pending: PendingAction?
    @Published var errorMessage: String?

    @Published var roots: [String] {
        didSet { UserDefaults.standard.set(roots, forKey: "roots") }
    }
    @Published var fetchBeforeScan: Bool {
        didSet { UserDefaults.standard.set(fetchBeforeScan, forKey: "fetchBeforeScan") }
    }
    @Published var deleteBranchOnRemove: Bool {
        didSet { UserDefaults.standard.set(deleteBranchOnRemove, forKey: "deleteBranchOnRemove") }
    }

    init() {
        let d = UserDefaults.standard
        roots = d.stringArray(forKey: "roots") ?? [home + "/Documents/dev"]
        fetchBeforeScan = d.object(forKey: "fetchBeforeScan") as? Bool ?? true
        deleteBranchOnRemove = d.object(forKey: "deleteBranchOnRemove") as? Bool ?? false

        Task {
            await scanStorage()
            await scanWorktrees()
        }
    }

    // MARK: - Derived

    var allWorktrees: [Worktree] { repos.flatMap(\.worktrees) }
    var mergedWorktrees: [Worktree] { allWorktrees.filter { $0.state.isMerged } }
    var mergedCacheSize: Int64 { mergedWorktrees.reduce(0) { $0 + $1.cacheSize } }
    var removableMerged: [Worktree] { mergedWorktrees.filter { $0.canRemove && !$0.dirty } }

    func refreshDisk() { disk = .current() }

    // MARK: - Storage

    func scanStorage() async {
        storageScanning = true
        refreshDisk()
        let items = storage
        let sizes = await Parallel.map(items, limit: 4) { await DiskUsage.size(of: $0.path) }
        for i in storage.indices { storage[i].size = sizes[i] }
        storageScanning = false
    }

    func refreshStorageSize(_ path: String) async {
        let size = await DiskUsage.size(of: path)
        if let i = storage.firstIndex(where: { $0.path == path }) { storage[i].size = size }
        refreshDisk()
    }

    func askClean(_ item: StorageItem) {
        guard let cleaner = item.cleaner else { return }
        let how: String
        switch cleaner {
        case .deleteContents: how = "Toàn bộ nội dung trong\n\(item.path)\nsẽ bị xóa vĩnh viễn."
        case .command(let args): how = "Sẽ chạy: \(args.joined(separator: " "))"
        }
        pending = PendingAction(
            title: "Dọn \(item.name)?",
            message: "\(how)\n\nDung lượng hiện tại: \((item.size ?? 0).bytes)",
            confirm: "Dọn"
        ) { [weak self] in await self?.clean(item) }
    }

    private func clean(_ item: StorageItem) async {
        guard let cleaner = item.cleaner else { return }
        busy.insert(item.path)
        defer { busy.remove(item.path) }
        switch cleaner {
        case .deleteContents:
            do { try await DiskUsage.removeContents(of: item.path) }
            catch { errorMessage = "Không xóa hết được \(item.name): \(error.localizedDescription)" }
        case .command(let args):
            let r = await Shell.run(args)
            if !r.ok { errorMessage = "Lệnh `\(args.joined(separator: " "))` lỗi:\n\(r.err.isEmpty ? r.out : r.err)" }
        }
        if let i = storage.firstIndex(where: { $0.path == item.path }) {
            storage[i].size = await DiskUsage.size(of: item.path)
        }
        refreshDisk()
    }

    // MARK: - Worktrees

    func scanWorktrees() async {
        guard !worktreeScanning else { return }
        worktreeScanning = true
        repos = await WorktreeScanner.scan(roots: roots, fetch: fetchBeforeScan) { [weak self] msg in
            self?.worktreeProgress = msg
        }
        worktreeScanning = false
        worktreeProgress = ""
        worktreesScannedAt = Date()
        refreshDisk()
    }

    func askCleanCaches(_ wt: Worktree) {
        let list = wt.caches.map { "• \(shortPath($0.path)) — \($0.size.bytes)" }.joined(separator: "\n")
        pending = PendingAction(
            title: "Xóa cache build của \(wt.name)?",
            message: "Sẽ xóa vĩnh viễn \(wt.cacheSize.bytes):\n\(list)",
            confirm: "Xóa cache"
        ) { [weak self] in await self?.cleanCaches(wt) }
    }

    func askCleanAllMergedCaches() {
        let targets = mergedWorktrees.filter { $0.cacheSize > 0 }
        guard !targets.isEmpty else { return }
        pending = PendingAction(
            title: "Xóa cache của \(targets.count) worktree đã merge?",
            message: "Giải phóng khoảng \(mergedCacheSize.bytes). Source code và worktree vẫn giữ nguyên.",
            confirm: "Xóa cache"
        ) { [weak self] in
            for wt in targets { await self?.cleanCaches(wt) }
        }
    }

    private func cleanCaches(_ wt: Worktree) async {
        busy.insert(wt.path)
        defer { busy.remove(wt.path) }
        var failed: [String] = []
        for c in wt.caches {
            do { try await DiskUsage.remove(c.path) } catch { failed.append(shortPath(c.path)) }
        }
        let freedInTree = wt.caches.filter { !$0.isDerivedData }.reduce(0) { $0 + $1.size }
        update(wt) {
            $0.caches.removeAll { c in !failed.contains(self.shortPath(c.path)) }
            $0.totalSize = $0.totalSize.map { max($0 - freedInTree, 0) }
        }
        if !failed.isEmpty { errorMessage = "Không xóa được:\n" + failed.joined(separator: "\n") }
        refreshDisk()
    }

    func askRemove(_ wt: Worktree) {
        var msg = "Thư mục \(wt.path) sẽ bị xóa (git worktree remove) cùng DerivedData của nó."
        if wt.dirty { msg += "\n\n⚠️ Worktree có thay đổi CHƯA COMMIT — sẽ mất hết." }
        if !wt.state.isMerged { msg += "\n\n⚠️ Nhánh này CHƯA được xác nhận là đã merge." }
        if deleteBranchOnRemove, let b = wt.branch, wt.state.isMerged { msg += "\n\nNhánh local \(b) cũng sẽ bị xóa." }
        pending = PendingAction(
            title: "Xóa worktree \(wt.name)?", message: msg,
            confirm: wt.dirty ? "Xóa (bỏ thay đổi)" : "Xóa worktree"
        ) { [weak self] in await self?.remove(wt, force: wt.dirty) }
    }

    func askRemoveAllMerged() {
        let targets = removableMerged
        guard !targets.isEmpty else { return }
        let total = targets.reduce(Int64(0)) { $0 + ($1.totalSize ?? 0) + $1.caches.filter(\.isDerivedData).reduce(0) { $0 + $1.size } }
        let names = targets.map { "• \($0.name)" }.joined(separator: "\n")
        pending = PendingAction(
            title: "Xóa \(targets.count) worktree đã merge?",
            message: "Chỉ gồm các worktree sạch (không có thay đổi chưa commit). Giải phóng khoảng \(total.bytes).\n\n\(names)",
            confirm: "Xóa tất cả"
        ) { [weak self] in
            for wt in targets { await self?.remove(wt, force: false) }
        }
    }

    private func remove(_ wt: Worktree, force: Bool) async {
        busy.insert(wt.path)
        defer { busy.remove(wt.path) }

        if wt.prunable {
            _ = await Shell.run(["git", "-C", wt.repoPath, "worktree", "prune"])
        } else {
            var args = ["git", "-C", wt.repoPath, "worktree", "remove"]
            if force { args.append("--force") }
            args.append(wt.path)
            let r = await Shell.run(args)
            if !r.ok {
                errorMessage = "Không xóa được \(wt.name):\n\(r.err)"
                return
            }
        }
        for dd in wt.caches where dd.isDerivedData {
            try? await DiskUsage.remove(dd.path)
        }
        if deleteBranchOnRemove, wt.state.isMerged, let b = wt.branch {
            _ = await Shell.run(["git", "-C", wt.repoPath, "branch", "-D", b])
        }
        for i in repos.indices { repos[i].worktrees.removeAll { $0.path == wt.path } }
        refreshDisk()
    }

    private func update(_ wt: Worktree, _ change: (inout Worktree) -> Void) {
        for r in repos.indices {
            if let w = repos[r].worktrees.firstIndex(where: { $0.path == wt.path }) {
                change(&repos[r].worktrees[w])
            }
        }
    }

    // MARK: - Big folders

    func scanBigFolders() async {
        bigScanning = true
        defer { bigScanning = false }
        let r = await Shell.run(["du", "-k", "-d", "2", home])
        var sizes: [String: Int64] = [:]
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: "\t", maxSplits: 1)
            guard parts.count == 2, let kb = Int64(parts[0]) else { continue }
            sizes[String(parts[1])] = kb * 1024
        }
        let minSize: Int64 = 50 * 1024 * 1024
        func children(of parent: String) -> [FolderNode] {
            sizes.filter { ($0.key as NSString).deletingLastPathComponent == parent && $0.value >= minSize }
                .map { FolderNode(path: $0.key, size: $0.value) }
                .sorted { $0.size > $1.size }
        }
        bigFolders = children(of: home).map { node in
            var n = node
            let kids = children(of: node.path)
            n.children = kids.isEmpty ? nil : kids
            return n
        }
        refreshDisk()
    }

    // MARK: - Helpers

    func shortPath(_ p: String) -> String {
        p.hasPrefix(home) ? "~" + p.dropFirst(home.count) : p
    }

    func reveal(_ path: String) {
        NSWorkspace.shared.activateFileViewerSelecting([URL(fileURLWithPath: path)])
    }
}
