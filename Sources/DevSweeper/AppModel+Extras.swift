import Foundation

extension AppModel {
    // MARK: - Simulator runtimes

    func loadRuntimes() async {
        runtimesLoading = true
        runtimes = await RuntimeManager.load()
        runtimesLoading = false
    }

    func askDeleteRuntime(_ rt: SimRuntime) {
        var msg = "Giải phóng \(rt.size.bytes). Cần tải lại trong Xcode → Settings → Components nếu muốn dùng lại."
        if !rt.devices.isEmpty {
            msg += "\n\n\(rt.devices.count) simulator dùng runtime này sẽ bị xóa theo:\n"
                + rt.devices.prefix(10).map { "• \($0)" }.joined(separator: "\n")
        }
        if !rt.bootedDevices.isEmpty {
            msg += "\n\n⚠️ Đang chạy: \(rt.bootedDevices.joined(separator: ", ")) — có thể có phiên khác đang test trên đó."
        }
        pending = PendingAction(title: "Gỡ runtime \(rt.name)?", message: msg, confirm: "Gỡ runtime") { [weak self] in
            guard let self else { return }
            busy.insert(rt.id)
            if let err = await RuntimeManager.delete(rt) { errorMessage = "Không gỡ được \(rt.name):\n\(err)" }
            busy.remove(rt.id)
            await loadRuntimes()
            refreshDisk()
        }
    }

    // MARK: - Git repos

    func loadGitRepos() async {
        gitLoading = true
        gitRepos = await GitRepoScanner.scan(roots: roots)
        gitLoading = false
    }

    func askGC(_ repo: GitRepoInfo) {
        pending = PendingAction(
            title: "Chạy git gc cho \(repo.name)?",
            message: "Gộp \(repo.looseCount) object rời (\(repo.looseSize.bytes)) và \(repo.packs) pack, dọn rác \(repo.garbageSize.bytes). Chỉ prune object cũ hơn 2 tuần nên an toàn với worktree đang làm. Repo lớn có thể mất vài phút.",
            confirm: "Chạy git gc"
        ) { [weak self] in
            guard let self else { return }
            busy.insert(repo.path)
            if let err = await GitRepoScanner.gc(repo.path) { errorMessage = "git gc lỗi:\n\(err)" }
            let updated = await GitRepoScanner.inspect(repo.path)
            if let i = gitRepos.firstIndex(where: { $0.path == repo.path }) { gitRepos[i] = updated }
            busy.remove(repo.path)
            refreshDisk()
        }
    }

    // MARK: - Large files

    func loadLargeFiles(minMB: Int) async {
        largeLoading = true
        largeFiles = await LargeFileScanner.scan(minMB: minMB)
        largeLoading = false
        largeScanned = true
    }

    func askTrashFiles(_ files: [LargeFile]) {
        guard !files.isEmpty else { return }
        let total = files.reduce(Int64(0)) { $0 + $1.size }
        var msg = "Chuyển \(total.bytes) vào Thùng rác — vẫn khôi phục được cho tới khi dọn Thùng rác."
        if files.count <= 12 { msg += "\n\n" + files.map { "• \($0.name)" }.joined(separator: "\n") }
        pending = PendingAction(
            title: files.count == 1 ? "Chuyển \(files[0].name) vào Thùng rác?" : "Chuyển \(files.count) file vào Thùng rác?",
            message: msg, confirm: "Chuyển vào Thùng rác"
        ) { [weak self] in
            guard let self else { return }
            if let err = await AppUninstaller.trash(files.map(\.path)) { errorMessage = err }
            let fm = FileManager.default
            largeFiles.removeAll { !fm.fileExists(atPath: $0.path) }
            refreshDisk()
        }
    }

    // MARK: - Apps

    func loadApps() async {
        appsLoading = true
        apps = await AppUninstaller.listApps()
        appsLoading = false
        // Tính dung lượng dần dần
        let paths = apps.map(\.path)
        let sizes = await Parallel.map(paths, limit: 6) { await DiskUsage.size(of: $0) }
        for (i, p) in paths.enumerated() {
            if let j = apps.firstIndex(where: { $0.path == p }) { apps[j].size = sizes[i] }
        }
    }

    /// Gỡ app: đưa app + các file liên quan đã chọn vào Thùng rác.
    func uninstall(_ app: InstalledApp, related: [RelatedFile]) async -> String? {
        if app.isRunning { return "\(app.name) đang chạy — hãy thoát app trước." }
        busy.insert(app.path)
        defer { busy.remove(app.path) }
        if let err = await AppUninstaller.trash([app.path] + related.map(\.path)) { return err }
        apps.removeAll { $0.path == app.path }
        refreshDisk()
        return nil
    }
}
