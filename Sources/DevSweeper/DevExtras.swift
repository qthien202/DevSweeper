import Foundation

// MARK: - Simulator runtimes

struct SimRuntime: Identifiable {
    var id: String { identifier }
    let identifier: String
    let runtimeIdentifier: String
    let name: String          // "iOS 26.0.1"
    let build: String
    let size: Int64
    let lastUsed: Date?
    let deletable: Bool
    var devices: [String] = []
    var bootedDevices: [String] = []

    var unusedDays: Int? { lastUsed.map { Int(Date().timeIntervalSince($0) / 86400) } }
    /// Gợi ý gỡ: lâu không dùng (>30 ngày), hoặc không simulator nào dùng và đã >7 ngày.
    /// Runtime vừa dùng gần đây thì không gợi ý — có thể là runtime mặc định của Xcode.
    var suggestRemove: Bool {
        guard deletable, bootedDevices.isEmpty else { return false }
        let days = unusedDays ?? Int.max
        return days > 30 || (devices.isEmpty && days > 7)
    }
}

enum RuntimeManager {
    static func load() async -> [SimRuntime] {
        let iso = ISO8601DateFormatter()
        let rt = await Shell.run(["xcrun", "simctl", "runtime", "list", "-j"])
        guard let runtimes = try? JSONSerialization.jsonObject(with: Data(rt.out.utf8)) as? [String: [String: Any]]
        else { return [] }

        var devicesByRuntime: [String: [(name: String, booted: Bool)]] = [:]
        let dv = await Shell.run(["xcrun", "simctl", "list", "devices", "-j"])
        if let json = try? JSONSerialization.jsonObject(with: Data(dv.out.utf8)) as? [String: Any],
           let devices = json["devices"] as? [String: [[String: Any]]] {
            for (runtime, list) in devices {
                devicesByRuntime[runtime] = list.compactMap { d in
                    guard let name = d["name"] as? String else { return nil }
                    return (name, d["state"] as? String == "Booted")
                }
            }
        }

        return runtimes.values.compactMap { r -> SimRuntime? in
            guard let id = r["identifier"] as? String,
                  let runtimeId = r["runtimeIdentifier"] as? String else { return nil }
            let platform = runtimeId.components(separatedBy: "SimRuntime.").last?
                .components(separatedBy: "-").first ?? "Sim"
            var item = SimRuntime(
                identifier: id,
                runtimeIdentifier: runtimeId,
                name: "\(platform) \(r["version"] as? String ?? "?")",
                build: r["build"] as? String ?? "",
                size: (r["sizeBytes"] as? NSNumber)?.int64Value ?? 0,
                lastUsed: (r["lastUsedAt"] as? String).flatMap { iso.date(from: $0) },
                deletable: r["deletable"] as? Bool ?? false
            )
            let devices = devicesByRuntime[runtimeId] ?? []
            item.devices = devices.map(\.name)
            item.bootedDevices = devices.filter(\.booted).map(\.name)
            return item
        }
        .sorted { $0.size > $1.size }
    }

    /// Gỡ runtime, rồi xóa các simulator không còn runtime để chạy.
    static func delete(_ runtime: SimRuntime) async -> String? {
        let r = await Shell.run(["xcrun", "simctl", "runtime", "delete", runtime.identifier])
        guard r.ok else { return (r.err.isEmpty ? r.out : r.err).trimmingCharacters(in: .whitespacesAndNewlines) }
        _ = await Shell.run(["xcrun", "simctl", "delete", "unavailable"])
        return nil
    }

    /// Xóa sạch dữ liệu của một simulator (giữ lại simulator).
    static func erase(udid: String, booted: Bool) async -> String? {
        if booted { _ = await Shell.run(["xcrun", "simctl", "shutdown", udid]) }
        let r = await Shell.run(["xcrun", "simctl", "erase", udid])
        return r.ok ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}

// MARK: - Git repos

struct GitRepoInfo: Identifiable {
    var id: String { path }
    let path: String
    var gitSize: Int64 = 0
    var packSize: Int64 = 0
    var looseSize: Int64 = 0
    var looseCount = 0
    var garbageSize: Int64 = 0
    var packs = 0
    var worktrees = 0

    var name: String { (path as NSString).lastPathComponent }
    /// Ước lượng phần `git gc` lấy lại được: object rời + rác. Pack nhiều file cũng gộp lại được.
    var reclaimable: Int64 { looseSize + garbageSize }
    var needsGC: Bool { looseSize > 50_000_000 || garbageSize > 0 || packs > 20 }
}

enum GitRepoScanner {
    static func scan(roots: [String]) async -> [GitRepoInfo] {
        let repos = await WorktreeScanner.findRepos(roots: roots)
        return await Parallel.map(repos, limit: 6) { await inspect($0) }
            .sorted { $0.gitSize > $1.gitSize }
    }

    static func inspect(_ path: String) async -> GitRepoInfo {
        var info = GitRepoInfo(path: path)
        info.gitSize = await DiskUsage.size(of: path + "/.git") ?? 0
        let r = await Shell.run(["git", "-C", path, "count-objects", "-v"])
        for line in r.out.split(separator: "\n") {
            let parts = line.split(separator: ":", maxSplits: 1).map { $0.trimmingCharacters(in: .whitespaces) }
            guard parts.count == 2, let v = Int64(parts[1]) else { continue }
            switch parts[0] {
            case "count": info.looseCount = Int(v)
            case "size": info.looseSize = v * 1024
            case "size-pack": info.packSize = v * 1024
            case "size-garbage": info.garbageSize = v * 1024
            case "packs": info.packs = Int(v)
            default: break
            }
        }
        let wt = await Shell.run(["git", "-C", path, "worktree", "list", "--porcelain"])
        info.worktrees = wt.out.components(separatedBy: "\nworktree ").count
        return info
    }

    /// `git gc` mặc định (chỉ prune object cũ hơn 2 tuần) — an toàn khi worktree khác đang làm việc.
    static func gc(_ path: String) async -> String? {
        _ = await Shell.run(["git", "-C", path, "worktree", "prune"])
        let r = await Shell.run(["git", "-C", path, "gc", "--quiet"])
        return r.ok ? nil : r.err.trimmingCharacters(in: .whitespacesAndNewlines)
    }
}
